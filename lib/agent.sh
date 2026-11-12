# lib/agent.sh: the agent loop.
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

# Work on one goal until done. Returns 0 done, 1 error, 3 step limit.
agent_run_goal() {
  local d="$AGENT_DIR" resp="$AGENT_DIR/response.json"
  local step n i name sig last_sig="" same=0 reason

  agent_add_user_text "$1"

  for (( step = 1; step <= OSBUDDY_MAX_STEPS; step++ )); do
    ui_debug "step $step of $OSBUDDY_MAX_STEPS"
    agent_trim

    # 1. Ask Gemini.
    gemini_build_request "$AGENT_HISTORY" "$d/system.txt" "$OSBUDDY_SHARE/tools.json" "$d/request.json" ||
      { ui_error "could not build the request"; return 1; }
    gemini_call "$d/request.json" "$resp" || return 1

    # An empty reply means it was blocked by safety filters or failed.
    if ! jq -e '.candidates[0].content.parts | length > 0' "$resp" > /dev/null 2>&1; then
      reason="$(jq -r '.promptFeedback.blockReason // .candidates[0].finishReason // "empty response"' "$resp" 2>/dev/null)"
      ui_error "Gemini returned no answer (reason: ${reason:-unreadable response})"
      return 1
    fi

    # 2. Save the reply verbatim. Gemini 3+ needs its "thoughtSignature"
    #    fields sent back unchanged, so we never rebuild this object.
    jq '.candidates[0].content | .role //= "model"' "$resp" > "$d/item.json"
    agent_push "$d/item.json"

    # 3. No tool calls means the model is finished: print its text to stdout.
    n="$(jq '[.candidates[0].content.parts[] | select(.functionCall)] | length' "$resp")"
    if (( n == 0 )); then
      jq -r '[.candidates[0].content.parts[] | select(.text and (.thought | not)) | .text] | join("")' "$resp" | render_answer
      [[ "$(jq -r '.candidates[0].finishReason // ""' "$resp")" == MAX_TOKENS ]] &&
        ui_warn "the answer was cut off (MAX_TOKENS)"
      return 0
    fi

    # 4. Run every tool call in order. Collect all results into one user turn.
    echo '[]' > "$d/parts.json"
    for (( i = 0; i < n; i++ )); do
      jq --argjson i "$i" '[.candidates[0].content.parts[] | select(.functionCall)][$i].functionCall' "$resp" > "$d/call.json"
      jq '.args // {}' "$d/call.json" > "$d/args.json"
      name="$(jq -r '.name' "$d/call.json")"
      ui_debug "tool call: $(jq -c . "$d/call.json")"

      tools_dispatch "$name" "$d/args.json" "$d/result.json"

      # Stuck detection: the same call 3 times in a row gets a nudge.
      sig="$(jq -c '[.name, .args]' "$d/call.json")"
      if [[ "$sig" == "$last_sig" ]]; then same=$(( same + 1 )); else same=1; last_sig="$sig"; fi
      if (( same >= 3 )); then
        ui_warn "same call repeated $same times, telling the model to change approach"
        jq '. + {note: "You made this exact call 3 times in a row. Try a different approach or stop."}' \
          "$d/result.json" > "$d/result.tmp" && mv "$d/result.tmp" "$d/result.json"
      fi

      # Wrap the result as a functionResponse part. Echo name, and id if given.
      jq --slurpfile c "$d/call.json" --slurpfile r "$d/result.json" \
        '. + [ { functionResponse: ( {name: $c[0].name, response: $r[0]}
                                     + (if $c[0].id then {id: $c[0].id} else {} end) ) } ]' \
        "$d/parts.json" > "$d/parts.tmp" && mv "$d/parts.tmp" "$d/parts.json"
    done

    jq -n --slurpfile p "$d/parts.json" '{role: "user", parts: $p[0]}' > "$d/item.json"
    agent_push "$d/item.json"
  done

  ui_warn "step limit reached ($OSBUDDY_MAX_STEPS steps) before the goal was finished"
  return 3
}
