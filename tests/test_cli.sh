#!/usr/bin/env bash
# tests/test_cli.sh: flags, usage errors and exit codes (0 done, 1 error, 2 usage).
source "$(dirname "$0")/helpers.sh"

out="$("$OSBUDDY" --help 2>&1)"; code=$?
assert_eq 0 "$code" "--help exits 0"
assert_contains "$out" "Usage:" "--help prints usage"

out="$("$OSBUDDY" --version 2>&1)"
assert_contains "$out" "os-buddy 0." "--version prints the version"

GEMINI_API_KEY=x "$OSBUDDY" --bogus > /dev/null 2>&1
assert_eq 2 "$?" "unknown flag exits 2"

GEMINI_API_KEY=x "$OSBUDDY" --max-steps abc "goal" > /dev/null 2>&1
assert_eq 2 "$?" "bad --max-steps exits 2"

out="$(env -u GEMINI_API_KEY OSBUDDY_CONFIG_FILE=/nonexistent "$OSBUDDY" "goal" 2>&1)"; code=$?
assert_eq 1 "$code" "missing API key exits 1"
assert_contains "$out" "GEMINI_API_KEY" "missing API key is explained"

GEMINI_API_KEY=x OSBUDDY_CONFIG_FILE=/nonexistent "$OSBUDDY" < /dev/null > /dev/null 2>&1
assert_eq 2 "$?" "no goal and no terminal exits 2"

# Config file is read, and the environment wins over it.
cfg="$TEST_TMP/config"
printf 'GEMINI_API_KEY=from-file\nOSBUDDY_MODEL=model-from-file\n' > "$cfg"
chmod 600 "$cfg"
out="$(env -u GEMINI_API_KEY OSBUDDY_CONFIG_FILE="$cfg" OSBUDDY_MODEL=model-from-env bash -c '
  source "'"$ROOT"'/lib/ui.sh"; source "'"$ROOT"'/lib/config.sh"; config_load
  echo "$GEMINI_API_KEY $OSBUDDY_MODEL"')"
assert_eq "from-file model-from-env" "$out" "config file is read, env overrides it"

finish
