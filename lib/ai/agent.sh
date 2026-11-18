# lib/ai/agent.sh: the agent loop.
#   1. send history to Gemini
#   2. save its reply in history exactly as received
#   3. no tool calls? print the answer, done
#   4. otherwise run each tool call, send all results back, repeat
# The history file is the agent's memory (its "internal state").

AGENT_DIR=""        # temp folder for this run, deleted on exit
AGENT_HISTORY=""    # JSON array of {role, parts} turns

agent_init() {
  AGENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/os-buddy.XXXXXX")"
  AGENT_HISTORY="$AGENT_DIR/history.json"
  trap 'rm -rf "$AGENT_DIR"' EXIT                       # always clean up
  trap 'echo >&2; ui_warn "interrupted"; exit 130' INT  # Ctrl-C stops os-buddy
  agent_reset
  agent_build_system_prompt
}

# Forget the conversation (chat command /reset).
agent_reset() {
  echo '[]' > "$AGENT_HISTORY"
}

# System prompt = share/system-prompt.txt + facts about this machine,
# because the model cannot see the machine until it runs commands.
agent_build_system_prompt() {
  {
    cat "$OSBUDDY_SHARE/system-prompt.txt"
    echo
    echo "Facts about this machine:"
    echo "- OS: $(uname -sr)"
    echo "- Shell for commands: bash $BASH_VERSION"
    echo "- Current directory: $PWD"
    echo "- User: $(id -un)"
    echo "- Date: $(date '+%Y-%m-%d %H:%M')"
    if ui_is_interactive; then
      echo "- A human is at the terminal (ask_user works)."
    else
      echo "- No human is present (ask_user fails; changes are denied unless --yes)."
    fi
  } > "$AGENT_DIR/system.txt"
}

# Append one turn (a JSON object in a file) to the history.
agent_push() {
  jq --slurpfile item "$1" '. + $item' "$AGENT_HISTORY" > "$AGENT_HISTORY.tmp" &&
    mv "$AGENT_HISTORY.tmp" "$AGENT_HISTORY"
}

# Add a plain text message from the user.
agent_add_user_text() {
  jq -n --arg t "$1" '{role: "user", parts: [ {text: $t} ]}' > "$AGENT_DIR/item.json"
  agent_push "$AGENT_DIR/item.json"
}

# Keep cost bounded: when history is big, replace old tool results
# with "[trimmed]". The call/response pairs stay, so the API accepts it.
agent_trim() {
  local size
  size=$(wc -c < "$AGENT_HISTORY")
  (( size > 300000 )) || return 0
  ui_debug "trimming history ($size bytes)"
  jq '(length - 6) as $keep
      | [ to_entries[]
          | if .key < $keep then
              .value | .parts |= map(
                if has("functionResponse")
                then .functionResponse.response = {result: "[trimmed]"}
                else . end)
            else .value end ]' "$AGENT_HISTORY" > "$AGENT_HISTORY.tmp" &&
    mv "$AGENT_HISTORY.tmp" "$AGENT_HISTORY"
}

# Write the n-th tool call of a reply to its own file, and its arguments
# to another. Calls are listed one per line in $AGENT_DIR/calls.jsonl.
#   agent_get_call N call.json args.json
agent_get_call() {
  sed -n "$(( $1 + 1 ))p" "$AGENT_DIR/calls.jsonl" > "$2"
  jq '.args // {}' "$2" > "$3"
}

# When one model reply asks for 2 or more actions that need a "yes",
# show them together and ask once (all, none, or one by one).
# Sets TOOLS_BATCH for tools_approve. Blocked actions stay blocked.
agent_group_approval() {
  local n="$1" i label d="$AGENT_DIR"
  local -a labels=()
  TOOLS_BATCH=""
  (( n >= 2 )) || return 0
  [[ "$OSBUDDY_YES" == 1 ]] && return 0
  ui_is_interactive || return 0

  for (( i = 0; i < n; i++ )); do
    agent_get_call "$i" "$d/call.json" "$d/args.json"
    label="$(tools_needs_approval "$(jq -r '.name' "$d/call.json")" "$d/args.json")"
    [[ -n "$label" ]] && labels+=("$label")
  done
  (( ${#labels[@]} >= 2 )) || return 0

  ui_approve_batch "${labels[@]}"
  case $? in
    0) TOOLS_BATCH=all ;;
    1) TOOLS_BATCH=none ;;
  esac
}

# Ask Gemini for the next step. The reply is saved in $AGENT_DIR/response.json.
# Returns 1 (message already shown) when there is no usable reply.
agent_ask_model() {
  local d="$AGENT_DIR" reason
  gemini_build_request "$AGENT_HISTORY" "$d/system.txt" "$OSBUDDY_SHARE/tools.json" "$d/request.json" ||
    { ui_error "could not build the request"; return 1; }
  gemini_call "$d/request.json" "$d/response.json" || return 1

  # An empty reply means it was blocked by safety filters or failed.
  if ! jq -e '.candidates[0].content.parts | length > 0' "$d/response.json" > /dev/null 2>&1; then
    reason="$(jq -r '.promptFeedback.blockReason // .candidates[0].finishReason // "empty response"' "$d/response.json" 2>/dev/null)"
    ui_error "Gemini returned no answer (reason: ${reason:-unreadable response})"
    return 1
  fi
}

# The model is finished: print its text (not its hidden thoughts) to stdout.
agent_print_answer() {
  local resp="$AGENT_DIR/response.json"
  jq -r '[.candidates[0].content.parts[] | select(.text and (.thought | not)) | .text] | join("")' "$resp" | render_answer
  if [[ "$(jq -r '.candidates[0].finishReason // ""' "$resp")" == MAX_TOKENS ]]; then
    ui_warn "the answer was cut off (MAX_TOKENS)"
  fi
}

# Run every tool call of the reply, in order, and send all the results
# back to the model as one user turn.
#   $1 number of calls
agent_run_tools() {
  local n="$1" d="$AGENT_DIR" i name

  agent_group_approval "$n"
  echo '[]' > "$d/parts.json"
  for (( i = 0; i < n; i++ )); do
    agent_get_call "$i" "$d/call.json" "$d/args.json"
    name="$(jq -r '.name' "$d/call.json")"
    ui_debug "tool call: $(jq -c . "$d/call.json")"

    tools_dispatch "$name" "$d/args.json" "$d/result.json"
    agent_check_stuck

    # Wrap the result as a functionResponse part. Echo the name, and the id if given.
    jq --slurpfile c "$d/call.json" --slurpfile r "$d/result.json" \
      '. + [ { functionResponse: ( {name: $c[0].name, response: $r[0]}
                                   + (if $c[0].id then {id: $c[0].id} else {} end) ) } ]' \
      "$d/parts.json" > "$d/parts.tmp" && mv "$d/parts.tmp" "$d/parts.json"
  done
  TOOLS_BATCH=""                      # a group answer covers this reply only

  jq -n --slurpfile p "$d/parts.json" '{role: "user", parts: $p[0]}' > "$d/item.json"
  agent_push "$d/item.json"
}

# Stuck detection: the same call 3 times in a row gets a note in its
# result telling the model to change approach.
AGENT_LAST_CALL="" AGENT_SAME_COUNT=0
agent_check_stuck() {
  local d="$AGENT_DIR" call
  call="$(jq -c '[.name, .args]' "$d/call.json")"
  if [[ "$call" == "$AGENT_LAST_CALL" ]]; then
    AGENT_SAME_COUNT=$(( AGENT_SAME_COUNT + 1 ))
  else
    AGENT_SAME_COUNT=1 AGENT_LAST_CALL="$call"
  fi
  (( AGENT_SAME_COUNT >= 3 )) || return 0
  ui_warn "same call repeated $AGENT_SAME_COUNT times, telling the model to change approach"
  jq '. + {note: "You made this exact call 3 times in a row. Try a different approach or stop."}' \
    "$d/result.json" > "$d/result.tmp" && mv "$d/result.tmp" "$d/result.json"
}

# Work on one goal until done. Returns 0 done, 1 error, 3 step limit.
agent_run_goal() {
  local d="$AGENT_DIR" step n
  AGENT_LAST_CALL="" AGENT_SAME_COUNT=0
  agent_add_user_text "$1"

  for (( step = 1; step <= OSBUDDY_MAX_STEPS; step++ )); do
    ui_debug "step $step of $OSBUDDY_MAX_STEPS"
    agent_trim

    # 1. Ask Gemini.
    agent_ask_model || return 1

    # 2. Save the reply verbatim. Gemini 3+ needs its "thoughtSignature"
    #    fields sent back unchanged, so we never rebuild this object.
    jq '.candidates[0].content | .role //= "model"' "$d/response.json" > "$d/item.json"
    agent_push "$d/item.json"

    # 3. List its tool calls, one per line. None means it is finished.
    jq -c '.candidates[0].content.parts[] | select(.functionCall) | .functionCall' \
      "$d/response.json" > "$d/calls.jsonl"
    n="$(grep -c . "$d/calls.jsonl")"
    if (( n == 0 )); then
      agent_print_answer
      return 0
    fi

    # 4. Run them and send the results back, then go round again.
    agent_run_tools "$n"
  done

  ui_warn "step limit reached ($OSBUDDY_MAX_STEPS steps) before the goal was finished"
  return 3
}
