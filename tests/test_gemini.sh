#!/usr/bin/env bash
# tests/test_gemini.sh: API errors, retries and secret handling, with a fake curl.
source "$(dirname "$0")/helpers.sh"
load_libs

GEMINI_API_KEY=test-key-123
OSBUDDY_CURL="$FIXTURES/fake-curl.sh"
OSBUDDY_RETRY_DELAY=0
echo '{}' > "$TEST_TMP/req.json"

# Point the fake curl at a scenario with a fresh log folder.
use_scenario() {
  export FAKE_CURL_SCENARIO="$FIXTURES/gemini/$1"
  export FAKE_CURL_STATE="$TEST_TMP/state-$1"
  mkdir -p "$FAKE_CURL_STATE"
}

use_scenario retry
gemini_call "$TEST_TMP/req.json" "$TEST_TMP/resp.json" 2> /dev/null
assert_eq 0 "$?" "429 and 503 are retried, then succeed"
assert_eq 3 "$(cat "$FAKE_CURL_STATE/count")" "it took 3 attempts"

use_scenario api-error
err="$(gemini_call "$TEST_TMP/req.json" "$TEST_TMP/resp.json" 2>&1)"; code=$?
assert_eq 1 "$code" "400 fails without retrying"
assert_contains "$err" "API key not valid" "the server's error message is shown"
assert_eq 1 "$(cat "$FAKE_CURL_STATE/count")" "400 is not retried"

# Secret: the key goes on stdin, never in the arguments (visible in "ps").
assert_not_contains "$(cat "$FAKE_CURL_STATE/args.log")" "test-key-123" "API key is not in curl arguments"
assert_contains "$(cat "$FAKE_CURL_STATE/stdin.1.log")" "test-key-123" "API key is sent via stdin config"

# Request shape.
echo '[{"role":"user","parts":[{"text":"hi"}]}]' > "$TEST_TMP/h.json"
gemini_build_request "$TEST_TMP/h.json" "$ROOT/share/system-prompt.txt" "$ROOT/share/tools.json" "$TEST_TMP/r.json"
assert_eq "hi" "$(jq -r '.contents[0].parts[0].text' "$TEST_TMP/r.json")" "request contains the history"
assert_eq 6 "$(jq '.tools[0].functionDeclarations | length' "$TEST_TMP/r.json")" "request declares 6 tools"

finish
