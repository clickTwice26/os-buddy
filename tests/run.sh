#!/usr/bin/env bash
# tests/run.sh: run every tests/test_*.sh file and report the result.
# Offline: the Gemini API is replaced by tests/fixtures/fake-curl.sh.
# Usage: bash tests/run.sh   (or: make test)

cd "$(dirname "$0")" || exit 1
failed=0

for file in test_*.sh; do
  echo "== $file"
  # stdin from /dev/null: no human present, so nothing waits for a y/n answer.
  bash "$file" < /dev/null || failed=$(( failed + 1 ))
done

echo
if (( failed == 0 )); then
  echo "ALL TESTS PASSED"
else
  echo "$failed test file(s) had failures"
  exit 1
fi
