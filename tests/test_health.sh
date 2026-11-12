#!/usr/bin/env bash
# tests/test_health.sh: "os-buddy health" numbers and report.
# The parse_* tests use sample macOS output, so they run on Linux too.
source "$(dirname "$0")/helpers.sh"
export LC_ALL=C NO_COLOR=1
load_libs

# Linux memory: used = total - available.
out="$(printf 'MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 600 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\n' | parse_meminfo)"
assert_eq "1000 400 200 50" "$out" "meminfo: total used swap_total swap_used"

# Linux CPU: 100 ticks passed, 25 of them idle -> 75% busy.
out="$(printf 'cpu 100 0 0 100 0 0 0 0\ncpu 175 0 0 125 0 0 0 0\n' | parse_proc_stat)"
assert_eq "75" "$out" "proc/stat: busy percent"

# macOS boot time.
out="$(echo '{ sec = 1731400000, usec = 123 } Tue Nov 12 10:00:00 2026' | parse_boottime)"
assert_eq "1731400000" "$out" "macOS kern.boottime"

# macOS memory: (100 + 50 + 10 pages) * 16384 bytes = 2560 KB.
vm=$'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:      5.\nPages active:    100.\nPages wired down:   50.\nPages occupied by compressor:   10.'
assert_eq "2560" "$(printf '%s\n' "$vm" | parse_vm_stat)" "macOS vm_stat used KB"

# macOS swap.
out="$(echo 'total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)' | parse_swapusage)"
assert_eq "2097152 524288" "$out" "macOS vm.swapusage"

assert_eq "1 day, 2 h 3 min" "$(health_format_uptime 93780)" "uptime text"
assert_eq "4 h 0 min" "$(health_format_uptime 14400)" "uptime under a day"

# The whole report on this machine: it runs and shows every part.
out="$("$OSBUDDY" health)"; rc=$?
assert_contains "$out" "System health" "report has a title"
assert_contains "$out" "Memory" "report shows memory"
assert_contains "$out" "Verdict" "report has a verdict"
[[ "$rc" =~ ^(0|4|5)$ ]] && pass "exit code is 0, 4 or 5" || fail "exit code is 0, 4 or 5" "got $rc"

# Critical level forced low: must report critical with exit code 5.
out="$(OSBUDDY_WARN_PCT=0 OSBUDDY_CRIT_PCT=0 "$OSBUDDY" health)"; rc=$?
assert_eq "5" "$rc" "critical exit code"
assert_contains "$out" "needs attention now" "critical verdict"

finish
