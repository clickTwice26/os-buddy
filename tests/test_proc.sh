#!/usr/bin/env bash
# tests/test_proc.sh: "os-buddy proc" (process management).
source "$(dirname "$0")/helpers.sh"
export NO_COLOR=1 LC_ALL=C

# Overview: summary and both top-10 tables.
out="$("$OSBUDDY" proc)"
assert_contains "$out" "Total" "overview shows a summary"
assert_contains "$out" "Top 10 by CPU" "overview has the CPU table"
assert_contains "$out" "Top 10 by memory" "overview has the memory table"

# A harmless process to find and stop.
tail -f /dev/null &
pid=$!

out="$("$OSBUDDY" proc find "tail -f /dev/null")"
assert_contains "$out" "$pid" "find shows the process"
out="$("$OSBUDDY" proc find "no-such-program-xyz")"
assert_contains "$out" "no process matches" "find reports no match"

# --dry-run shows the command and changes nothing.
out="$("$OSBUDDY" proc kill "$pid" --dry-run)"
assert_contains "$out" "kill -s TERM $pid" "dry run shows the kill command"
kill -0 "$pid" 2> /dev/null && pass "dry run leaves the process running" || fail "dry run leaves the process running"

# No terminal and no --yes: nothing happens.
"$OSBUDDY" proc kill "$pid" > /dev/null 2>&1
kill -0 "$pid" 2> /dev/null && pass "no approval, no kill" || fail "no approval, no kill"

# --yes approves it.
"$OSBUDDY" proc kill "$pid" --yes > /dev/null 2>&1
kill -0 "$pid" 2> /dev/null && fail "--yes stops the process" || pass "--yes stops the process"

# Safety checks.
out="$("$OSBUDDY" proc kill 1 --yes 2>&1)"
assert_contains "$out" "refusing" "PID 1 is never stopped"
out="$("$OSBUDDY" proc kill abc 2>&1)"; rc=$?
assert_contains "$out" "must be a number" "PID must be a number"
assert_eq 2 "$rc" "bad PID is a usage error"
out="$("$OSBUDDY" proc kill 999999 2>&1)"
assert_contains "$out" "no process" "missing PID is reported"

finish
