# lib/ai/tools.sh: the actions the model can take (actuators) and what it
# sees back (sensors). Each tool writes a JSON result object to a file.
#
# How one tool call runs:
#   tools_dispatch  picks the tool_* function by name
#   tools_describe  says what the call is and whether it needs a "yes"
#                   (using lib/ai/policy.sh); the ONE place for these rules
#   tools_gate      asks the human when needed; on "no" it writes the error
#   tool_*          does the work and writes the result

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

# Session memory for approvals.
#   TOOLS_ALWAYS[key]=1  the user pressed "a" (always allow) for this key
#   TOOLS_BATCH          all|none: the user already answered for a group of
#                        calls (see agent_group_approval); empty otherwise
declare -gA TOOLS_ALWAYS=()
TOOLS_BATCH=""

# Read one field from a tool's JSON arguments file, "" when missing.
#   tools_arg args.json command
tools_arg() {
  jq -r --arg k "$2" '.[$k] // ""' "$1"
}

# Write a small error result: {"error": "..."}.
tools_error() {
  jq -n --arg e "$1" '{error: $e}' > "$2"
}

# Describe a tool call for the approval step. Sets five variables:
#   TOOL_DECISION  allow | ask | block
#   TOOL_LABEL     what the human sees, e.g. the command
#   TOOL_KEY       what "always allow" would cover (empty: not offered)
#   TOOL_REASON    the model's own reason for the call
#   TOOL_RISK      why the policy asks
tools_describe() {
  local name="$1" args="$2" cmd path
  TOOL_DECISION=allow TOOL_LABEL="$name" TOOL_KEY="" TOOL_RISK=""
  TOOL_REASON="$(tools_arg "$args" reason)"
  case "$name" in
    run_command)
      cmd="$(tools_arg "$args" command)"
      TOOL_DECISION="$(policy_check_command "$cmd")"
      TOOL_LABEL="$cmd"
      TOOL_RISK="$(policy_explain "$cmd")"
      policy_can_always "$cmd" && TOOL_KEY="$(policy_program "$cmd")"
      ;;
    read_file)
      path="$(tools_arg "$args" path)"
      TOOL_DECISION="$(policy_check_read "$path")"
      TOOL_LABEL="read $path"
      TOOL_RISK="it is a private file (keys, passwords or .env); its content would be sent to Gemini"
      ;;
    write_file|edit_file)                     # changing a file always asks
      path="$(tools_arg "$args" path)"
      TOOL_DECISION=ask
      TOOL_LABEL="${name%_file} $path"        # "write PATH" or "edit PATH"
      TOOL_KEY="changes to $path"
      if [[ "$name" == write_file ]]; then
        TOOL_RISK="writing replaces the whole file"
      else
        TOOL_RISK="editing changes the file"
      fi
      ;;
  esac
}

# Decide if an action may go ahead.
#   $1 policy decision (allow|ask|block)   $2 what to show the human
#   $3 key for "always allow" (empty: not offered)
#   $4 the model's reason   $5 why the policy asks
# Returns 0 = go, 1 = denied, 2 = blocked.
tools_approve() {
  local decision="$1" label="$2" key="${3:-}" reason="${4:-}" risk="${5:-it may change something}" answer
  case "$decision" in
    allow) return 0 ;;
    block) ui_error "BLOCKED by policy: $label"; return 2 ;;
  esac

  # From here on the decision is "ask". Was it already answered?
  if [[ -n "$key" && -n "${TOOLS_ALWAYS[$key]:-}" ]]; then
    ui_step auto "$label"
    return 0
  fi
  [[ "$TOOLS_BATCH" == all ]] && return 0
  [[ "$TOOLS_BATCH" == none ]] && return 1
  if [[ "$OSBUDDY_YES" == 1 ]]; then
    ui_info "auto-approved (--yes): $label"
    return 0
  fi

  ui_approve "$label" "$reason" "$key" "$risk"; answer=$?
  if (( answer == 3 )); then              # "a": remember the key for this chat
    TOOLS_ALWAYS[$key]=1
    return 0
  fi
  return "$answer"
}

# The approval step inside each tool. On "no" it writes the error result
# for the model and returns 1, so a tool does:  tools_gate ... || return
#   $1 tool name   $2 arguments file   $3 result file
tools_gate() {
  local result
  tools_describe "$1" "$2"
  tools_approve "$TOOL_DECISION" "$TOOL_LABEL" "$TOOL_KEY" "$TOOL_REASON" "$TOOL_RISK"; result=$?
  case $result in
    0) return 0 ;;
    2) tools_error "blocked by safety policy; do not try to work around it" "$3" ;;
    *) tools_error "denied by the user" "$3" ;;
  esac
  return 1
}

# Does this tool call still need a human "yes"? If so, print
# "label<TAB>reason<TAB>risk". Used to ask about all the calls of one
# model reply together (see agent_group_approval).
tools_needs_approval() {
  tools_describe "$1" "$2"
  [[ "$TOOL_DECISION" == ask ]] || return 0
  [[ -n "$TOOL_KEY" && -n "${TOOLS_ALWAYS[$TOOL_KEY]:-}" ]] && return 0
  printf '%s\t%s\t%s\n' "$TOOL_LABEL" "$TOOL_REASON" "$TOOL_RISK"
}

# Run one tool call.
#   $1 tool name   $2 file with the arguments (JSON)   $3 result file
tools_dispatch() {
  local name="$1" args="$2" out="$3"
  case "$name" in
    run_command|read_file|write_file|edit_file|ask_user|system_report)
      "tool_$name" "$args" "$out" ;;
    *)
      tools_error "unknown tool: $name" "$out" ;;
  esac
}

# ---- run_command(command, timeout_seconds) ----
tool_run_command() {
  local args="$1" out="$2" cmd timeout dir pid watcher code timed_out=false
  cmd="$(tools_arg "$args" command)"
  timeout="$(tools_arg "$args" timeout_seconds)"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=120
  [[ -n "$cmd" ]] || { tools_error "command is empty" "$out"; return; }

  tools_gate run_command "$args" "$out" || return
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
  path="$(tools_arg "$args" path)"
  offset="$(tools_arg "$args" offset)"
  limit="$(tools_arg "$args" limit)"
  offset="${offset:-1}" limit="${limit:-400}"
  [[ "$offset" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || { tools_error "offset and limit must be numbers" "$out"; return; }
  [[ -f "$path" ]] || { tools_error "not a file: $path" "$out"; return; }
  [[ -r "$path" ]] || { tools_error "permission denied: $path" "$out"; return; }

  tools_gate read_file "$args" "$out" || return
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
  path="$(tools_arg "$args" path)"
  [[ -n "$path" ]] || { tools_error "path is empty" "$out"; return; }

  ui_info "write $path ($(jq -r '.content // "" | length' "$args") chars). Preview:"
  tools_arg "$args" content | head -n 20 | ui_block
  tools_gate write_file "$args" "$out" || return

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
  path="$(tools_arg "$args" path)"
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
  if tools_gate edit_file "$args" "$out"; then
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
  answer="$(ui_ask "$(tools_arg "$args" question)")" || answer=""
  jq -n --arg a "$answer" '{answer: $a}' > "$out"
}

# ---- system_report(report) ----
# Runs one read-only admin report (os-buddy status, health, ...) and gives
# the model its text. Only the fixed names below are accepted, and none of
# them changes anything, so no approval is needed.
tool_system_report() {
  local args="$1" out="$2" name text code
  name="$(tools_arg "$args" report)"
  case "$name" in
    status|health|disk|proc|users|backup) ;;
    *) tools_error "unknown report '$name'; use status, health, disk, proc, users or backup" "$out"; return ;;
  esac
  ui_step report "$name"
  # In a subshell with colours off: the model needs plain text.
  text="$(
    VIZ_RED="" VIZ_GREEN="" VIZ_YELLOW="" VIZ_CYAN="" VIZ_DIM="" VIZ_BOLD="" VIZ_RESET=""
    ADMIN_YES=0 ADMIN_DRY_RUN=0
    admin_run "$name" < /dev/null 2>&1
  )"
  code=$?
  jq -n --arg t "$text" --argjson c "$code" \
    '{report: $t, exit_code: $c, meaning: "0 fine, 4 warning, 5 critical"}' > "$out"
}
