# lib/tools.sh: the actions the model can take (actuators) and what it
# sees back (sensors). Each tool writes a JSON result object to a file.
# Every action passes through lib/policy.sh first.

OSBUDDY_OUTPUT_CAP=16000         # max bytes of output sent back to the model

# Keep big output small: first half + marker + last half.
#   $1 file to cap (changed in place)
tools_truncate_file() {
  local file="$1" size half
  size=$(wc -c < "$file")
  (( size > OSBUDDY_OUTPUT_CAP )) || return 0
  half=$(( OSBUDDY_OUTPUT_CAP / 2 ))
  {
    head -c "$half" "$file"
    printf '\n...[truncated %d bytes]...\n' $(( size - OSBUDDY_OUTPUT_CAP ))
    tail -c "$half" "$file"
  } > "$file.cut" && mv "$file.cut" "$file"
}

# Decide if an action may go ahead.
#   $1 policy decision (allow|ask|block)   $2 what to show the human
# Returns 0 = go, 1 = denied, 2 = blocked.
tools_approve() {
  case "$1" in
    allow) return 0 ;;
    block) ui_error "BLOCKED by policy: $2"; return 2 ;;
  esac
  [[ "$OSBUDDY_YES" == 1 ]] && { ui_info "auto-approved (--yes): $2"; return 0; }
  ui_confirm "Allow: $2 ?"
}

# Write a small error result: {"error": "..."}.
tools_error() {
  jq -n --arg e "$1" '{error: $e}' > "$2"
}

# Run one tool call.
#   $1 tool name   $2 file with the arguments (JSON)   $3 result file
tools_dispatch() {
  local name="$1" args="$2" out="$3"
  case "$name" in
    run_command) tool_run_command "$args" "$out" ;;
    read_file)   tool_read_file   "$args" "$out" ;;
    write_file)  tool_write_file  "$args" "$out" ;;
    edit_file)   tool_edit_file   "$args" "$out" ;;
    ask_user)    tool_ask_user    "$args" "$out" ;;
    *)           tools_error "unknown tool: $name" "$out" ;;
  esac
}

# Turn an approval result into an error for the model, if needed.
# Returns 0 when the action may run.
tools_check() {
  local decision="$1" label="$2" out="$3" rc
  tools_approve "$decision" "$label"; rc=$?
  case $rc in
    0) return 0 ;;
    2) tools_error "blocked by safety policy; do not try to work around it" "$out" ;;
    *) tools_error "denied by the user" "$out" ;;
  esac
  return 1
}

# ---- run_command(command, timeout_seconds) ----
tool_run_command() {
  local args="$1" out="$2" cmd timeout dir pid watcher code timed_out=false
  cmd="$(jq -r '.command // ""' "$args")"
  timeout="$(jq -r '.timeout_seconds // 120' "$args")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=120
  [[ -n "$cmd" ]] || { tools_error "command is empty" "$out"; return; }

  tools_check "$(policy_check_command "$cmd")" "$cmd" "$out" || return
  ui_step run "$cmd"

  dir="$(mktemp -d)"
  # env -u: the API key never reaches commands the agent runs.
  env -u GEMINI_API_KEY bash -c "$cmd" < /dev/null > "$dir/stdout" 2> "$dir/stderr" &
  pid=$!

  # Timeout without GNU "timeout": a background sleeper kills the command.
  # Its output goes to /dev/null so it never holds our stdout open.
  ( sleep "$timeout"; touch "$dir/timed_out"; pkill -TERM -P "$pid"; kill -TERM "$pid" ) > /dev/null 2>&1 &
  watcher=$!

  wait "$pid"; code=$?
  # Command finished: stop the watcher and its sleep.
  pkill -P "$watcher" 2>/dev/null; kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  [[ -e "$dir/timed_out" ]] && timed_out=true

  tools_truncate_file "$dir/stdout"
  tools_truncate_file "$dir/stderr"
  jq -n --rawfile o "$dir/stdout" --rawfile e "$dir/stderr" \
        --argjson c "$code" --argjson t "$timed_out" \
        '{exit_code: $c, timed_out: $t, stdout: $o, stderr: $e}' > "$out"
  rm -rf "$dir"
}

# ---- read_file(path, offset, limit) ----
tool_read_file() {
  local args="$1" out="$2" path offset limit tmp
  path="$(jq -r '.path // ""' "$args")"
  offset="$(jq -r '.offset // 1' "$args")"
  limit="$(jq -r '.limit // 400' "$args")"
  [[ "$offset" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || { tools_error "offset and limit must be numbers" "$out"; return; }
  [[ -f "$path" ]] || { tools_error "not a file: $path" "$out"; return; }
  [[ -r "$path" ]] || { tools_error "permission denied: $path" "$out"; return; }

  tools_check "$(policy_check_read "$path")" "read $path" "$out" || return
  ui_step read "$path"

  tmp="$(mktemp)"
  # Number each line so the model can refer to lines.
  awk -v s="$offset" -v e="$(( offset + limit - 1 ))" \
      'NR >= s && NR <= e { printf "%6d  %s\n", NR, $0 }' "$path" > "$tmp"
  tools_truncate_file "$tmp"
  jq -n --rawfile c "$tmp" --argjson total "$(wc -l < "$path")" \
        '{content: $c, total_lines: $total}' > "$out"
  rm -f "$tmp"
}

# ---- write_file(path, content) ----
tool_write_file() {
  local args="$1" out="$2" path
  path="$(jq -r '.path // ""' "$args")"
  [[ -n "$path" ]] || { tools_error "path is empty" "$out"; return; }

  ui_info "write $path ($(jq -r '.content // "" | length' "$args") chars). Preview:"
  jq -r '.content // ""' "$args" | head -n 20 | ui_block
  tools_check ask "write $path" "$out" || return      # writing always asks

  if jq -j '.content // ""' "$args" > "$path" 2>/dev/null; then
    jq -n --arg p "$path" '{ok: true, path: $p}' > "$out"
  else
    tools_error "cannot write $path (permission or missing folder)" "$out"
  fi
}

# ---- edit_file(path, old_text, new_text) ----
# Replaces old_text exactly once. Fails if it is missing or appears more than once.
tool_edit_file() {
  local args="$1" out="$2" path count new
  path="$(jq -r '.path // ""' "$args")"
  [[ -f "$path" ]] || { tools_error "not a file: $path" "$out"; return; }

  # jq's split("text") is exact (not regex): N matches give N+1 pieces.
  count="$(jq -Rs --slurpfile a "$args" '($a[0].old_text // "") as $o
       | if $o == "" then 0 else (split($o) | length - 1) end' "$path" 2>/dev/null)"
  if [[ -z "$count" ]]; then tools_error "cannot read $path as text" "$out"; return; fi
  if [[ "$count" == 0 ]]; then tools_error "old_text not found in $path" "$out"; return; fi
  if [[ "$count" != 1 ]]; then tools_error "old_text matches $count times; add more context to make it unique" "$out"; return; fi

  # Exactly one match, so split + join with new_text replaces just that one.
  new="$(mktemp)"
  jq -Rsj --slurpfile a "$args" 'split($a[0].old_text) | join($a[0].new_text // "")' "$path" > "$new"

  ui_info "edit $path:"
  diff -u "$path" "$new" | tail -n +3 | ui_block
  if tools_check ask "edit $path" "$out"; then
    if cat "$new" > "$path"; then
      jq -n --arg p "$path" '{ok: true, path: $p}' > "$out"
    else
      tools_error "cannot write $path" "$out"
    fi
  fi
  rm -f "$new"
}

# ---- ask_user(question) ----
tool_ask_user() {
  local args="$1" out="$2" answer
  if ! ui_is_interactive; then
    tools_error "no human available (non-interactive run); decide on your own or stop" "$out"
    return
  fi
  answer="$(ui_ask "$(jq -r '.question // ""' "$args")")" || answer=""
  jq -n --arg a "$answer" '{answer: $a}' > "$out"
}
