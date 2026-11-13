#!/usr/bin/env bash
# tests/test_disk.sh: "os-buddy disk" (disk monitoring).
source "$(dirname "$0")/helpers.sh"
export NO_COLOR=1 LC_ALL=C

out="$("$OSBUDDY" disk)"; rc=$?
assert_contains "$out" "Filesystems" "report has the disk table"
assert_contains "$out" "Alerts" "report has alerts"
[[ "$rc" =~ ^(0|4|5)$ ]] && pass "exit code is 0, 4 or 5" || fail "exit code is 0, 4 or 5" "got $rc"

# Every level at 0%: each disk is critical.
OSBUDDY_WARN_PCT=0 OSBUDDY_CRIT_PCT=0 "$OSBUDDY" disk > /dev/null
assert_eq 5 "$?" "critical level gives exit code 5"

# Biggest items inside a folder.
mkdir -p "$TEST_TMP/d/big" "$TEST_TMP/d/.hidden"
head -c 200000 /dev/zero > "$TEST_TMP/d/big/file"
head -c 1000 /dev/zero > "$TEST_TMP/d/.hidden/x"
out="$("$OSBUDDY" disk "$TEST_TMP/d")"
assert_contains "$out" "Biggest items" "folder section shown"
assert_contains "$out" "big" "biggest item listed"
assert_contains "$out" ".hidden" "hidden items are counted too"

out="$("$OSBUDDY" disk /no/such/folder 2>&1)"
assert_contains "$out" "not a folder" "missing folder is reported"

# The df parser: header, fake disks and snap loops are skipped,
# and a mount point with a space stays whole.
load_libs
df() {
  printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' \
    'tmpfs 100 1 99 1% /run' \
    '/dev/loop3 100 100 0 100% /snap/core/1' \
    '/dev/sda1 1000 900 100 90% /' \
    '/dev/sdb1 2000 200 1800 10% /media/My Disk'
}
out="$(admin_disk_list)"
assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "only real disks are listed"
assert_contains "$out" $'/media/My Disk\t/dev/sdb1' "mount point with a space"
assert_contains "$out" $'/\t/dev/sda1\t1000\t900\t100\t90' "columns are parsed"
unset -f df

finish
