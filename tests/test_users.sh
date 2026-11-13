#!/usr/bin/env bash
# tests/test_users.sh: "os-buddy users" (user management).
# Safe by default: only reads, dry runs and refusals. With
# OSBUDDY_TEST_REAL_USERS=1 and root (the CI containers), it also really
# adds, locks, unlocks and deletes a throwaway user.
source "$(dirname "$0")/helpers.sh"
export NO_COLOR=1 LC_ALL=C

out="$("$OSBUDDY" users)"; rc=$?
assert_eq 0 "$rc" "overview runs"
assert_contains "$out" "root" "overview lists root"
assert_contains "$out" "Logged in now" "overview has the who section"

# Names are checked before anything runs.
out="$("$OSBUDDY" users add 'Bad Name' 2>&1)"; rc=$?
assert_eq 2 "$rc" "invalid name is a usage error"
out="$("$OSBUDDY" users add 'x;rm' 2>&1)"
assert_contains "$out" "invalid name" "shell characters are refused"
out="$("$OSBUDDY" users add root 2>&1)"
assert_contains "$out" "already exists" "existing user is not added again"

# Protected accounts.
assert_contains "$("$OSBUDDY" users delete root --yes 2>&1)" "refusing" "root is protected"
assert_contains "$("$OSBUDDY" users lock "$(id -un)" --yes 2>&1)" "refusing" "your own account is protected"
if id nobody > /dev/null 2>&1; then
  assert_contains "$("$OSBUDDY" users lock nobody --yes 2>&1)" "system account" "nobody is protected"
fi
assert_contains "$("$OSBUDDY" users lock ghost-user-xyz 2>&1)" "no user" "missing user is reported"

# Dry run shows the command and changes nothing.
out="$("$OSBUDDY" users add osb-test-user --admin --dry-run)"
assert_contains "$out" "dry run" "dry run says so"
assert_contains "$out" "osb-test-user" "dry run shows the command"
id osb-test-user > /dev/null 2>&1 && fail "dry run creates nothing" || pass "dry run creates nothing"

# Without a terminal and without --yes, nothing changes.
"$OSBUDDY" users add osb-test-user > /dev/null 2>&1
id osb-test-user > /dev/null 2>&1 && fail "no approval, no user" || pass "no approval, no user"

# Real changes, only inside throwaway CI containers.
if [[ "${OSBUDDY_TEST_REAL_USERS:-0}" == 1 && "$EUID" == 0 ]]; then
  "$OSBUDDY" users add osb-test-user --admin --yes > /dev/null 2>&1
  id osb-test-user > /dev/null 2>&1 && pass "real: user added" || fail "real: user added"
  assert_contains "$(id -Gn osb-test-user)" "$(getent group sudo > /dev/null && echo sudo || echo wheel)" "real: user is admin"
  "$OSBUDDY" users lock osb-test-user --yes > /dev/null 2>&1; assert_eq 0 "$?" "real: lock works"
  "$OSBUDDY" users unlock osb-test-user --yes > /dev/null 2>&1
  rc=$?
  # A user with no password cannot be unlocked by some tools (it would
  # leave an empty password); "refused" is the safe answer there.
  [[ "$rc" == 0 || "$rc" == 1 ]] && pass "real: unlock runs" || fail "real: unlock runs" "rc $rc"
  "$OSBUDDY" users delete osb-test-user --yes > /dev/null 2>&1
  id osb-test-user > /dev/null 2>&1 && fail "real: user deleted" || pass "real: user deleted"
fi

finish
