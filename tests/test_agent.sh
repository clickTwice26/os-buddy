#!/usr/bin/env bash
# tests/test_agent.sh: the full program against scripted fake Gemini replies.
source "$(dirname "$0")/helpers.sh"

run_scenario simple-answer "say hello"
assert_eq 0 "$CODE" "plain answer exits 0"
assert_eq "Hello from fake Gemini" "$OUT" "answer goes to stdout"

run_scenario one-tool "run a tool"
assert_eq 0 "$CODE" "tool loop finishes with exit 0"
assert_eq "Done: hi-from-tool" "$OUT" "final answer after the tool call"
req2="$(cat "$STATE/request.2.json")"
assert_contains "$req2" "hi-from-tool" "tool output is sent back to the model"
assert_eq "call-1" "$(jq -r '.contents[2].parts[0].functionResponse.id' <<< "$req2")" "functionResponse echoes the call id"
assert_eq "sig-call-1" "$(jq -r '.contents[1].parts[0].thoughtSignature' <<< "$req2")" "thought signature is replayed verbatim"

run_scenario retry "retry please"
assert_eq 0 "$CODE" "survives 429 and 503"

run_scenario api-error "fail"
assert_eq 1 "$CODE" "API error exits 1"

run_scenario blocked "something"
assert_eq 1 "$CODE" "blocked response exits 1"
assert_contains "$ERR" "SAFETY" "block reason is reported"

run_scenario loop --max-steps 3 "loop forever"
assert_eq 3 "$CODE" "step limit exits 3"
assert_contains "$ERR" "repeated" "stuck detection warns"

run_scenario denied-write "write a file"
assert_eq 0 "$CODE" "denied write still finishes"
[[ ! -e "$TEST_TMP/should-not-exist.txt" ]] && pass "denied write did not create the file" || fail "denied write did not create the file"
assert_contains "$(cat "$STATE/request.2.json")" "denied by the user" "the model is told about the denial"

run_scenario env-leak --yes "show env"
assert_not_contains "$(cat "$STATE/request.2.json")" "test-key-123" "API key never reaches command output"

finish
