#!/usr/bin/env bash
# tests/test_status.sh: the "os-buddy status" dashboard and the
# system_report tool that gives the AI the same reports.
source "$(dirname "$0")/helpers.sh"
export NO_COLOR=1 LC_ALL=C OSBUDDY_BACKUP_DIR="$TEST_TMP/backups"

out="$("$OSBUDDY" status)"; rc=$?
for part in "System status" "Health" "Top 5 processes" "Users" "Backups" "Verdict"; do
  assert_contains "$out" "$part" "status shows $part"
done
assert_contains "$out" "no backups yet" "status warns when there are no backups"
[[ "$rc" == 4 || "$rc" == 5 ]] && pass "no backups means at least a warning" || fail "no backups means at least a warning" "rc $rc"

# The AI tool: fixed report names only, plain text, no approval.
load_libs
cd "$TEST_TMP" || exit 1
printf '%s' '{"report":"health"}' > a.json
tools_dispatch system_report a.json r.json 2> /dev/null
assert_contains "$(jq -r .report r.json)" "System health" "system_report returns the report"
assert_not_contains "$(jq -r .report r.json)" $'\e[' "system_report has no colour codes"
[[ "$(jq -r .exit_code r.json)" =~ ^(0|4|5)$ ]] && pass "system_report gives the exit code" || fail "system_report gives the exit code"
printf '%s' '{"report":"users add x"}' > a.json
tools_dispatch system_report a.json r.json 2> /dev/null
assert_contains "$(jq -r .error r.json)" "unknown report" "system_report refuses anything else"
printf '%s' '{"report":"status"}' > a.json
assert_eq "" "$(tools_needs_approval system_report a.json)" "system_report needs no approval"

finish
