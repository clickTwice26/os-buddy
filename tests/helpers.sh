# tests/helpers.sh: small shared helpers for the plain-Bash tests.
# Each test file does: source "$(dirname "$0")/helpers.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OSBUDDY="$ROOT/bin/os-buddy"
FIXTURES="$ROOT/tests/fixtures"
PASS=0
FAIL=0

# A fresh temp folder per test file, removed at the end.
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/os-buddy-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

pass() { PASS=$(( PASS + 1 )); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }

# assert_eq EXPECTED ACTUAL NAME
assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}

# assert_contains TEXT PART NAME
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3" "[$2] not found in: ${1:0:300}"; fi
}

# assert_not_contains TEXT PART NAME
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3" "[$2] should not appear"; fi
}

# Load the libraries into this shell, to test functions directly.
load_libs() {
  OSBUDDY_SHARE="$ROOT/share"
  OSBUDDY_CONFIG_FILE=/nonexistent
  local lib
  for lib in ui config policy gemini tools agent viz render; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$lib.sh"
  done
  config_load
}

# Run the real program against a fake API scenario.
# Sets OUT (stdout), ERR (stderr), CODE (exit code). STATE holds the fake-curl logs.
run_scenario() {
  local scenario="$1"; shift
  STATE="$TEST_TMP/state-$scenario-$RANDOM"
  mkdir -p "$STATE"
  OUT="$(cd "$TEST_TMP" && env \
        GEMINI_API_KEY=test-key-123 \
        OSBUDDY_CONFIG_FILE=/nonexistent \
        OSBUDDY_CURL="$FIXTURES/fake-curl.sh" \
        OSBUDDY_RETRY_DELAY=0 \
        FAKE_CURL_SCENARIO="$FIXTURES/gemini/$scenario" \
        FAKE_CURL_STATE="$STATE" \
        "$OSBUDDY" "$@" < /dev/null 2> "$STATE/stderr")"
  CODE=$?
  ERR="$(cat "$STATE/stderr")"
}

# Print the summary and return non-zero if anything failed.
finish() {
  printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 ))
}
