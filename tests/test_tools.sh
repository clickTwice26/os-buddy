#!/usr/bin/env bash
# tests/test_tools.sh: tool behaviour (output cap, timeouts, exact edits, approvals).
source "$(dirname "$0")/helpers.sh"
load_libs
cd "$TEST_TMP" || exit 1
res="$TEST_TMP/result.json"

# Helper: call a tool with JSON arguments.
call() { printf '%s' "$2" > args.json; tools_dispatch "$1" args.json "$res" 2> /dev/null; }

# ---- output cap ----
head -c 50000 /dev/zero | tr '\0' 'a' > big.txt
tools_truncate_file big.txt
size=$(wc -c < big.txt)
(( size < 16200 )) && pass "big output is capped (~16 KB)" || fail "big output is capped" "size $size"
assert_contains "$(cat big.txt)" "[truncated" "capped output has a marker"

# ---- run_command ----
call run_command '{"command":"echo hello; exit 3"}'          # has ";" -> ask -> denied (no human)
assert_eq "denied by the user" "$(jq -r .error "$res")" "change without a human is denied"

OSBUDDY_YES=1
call run_command '{"command":"echo hello; echo oops >&2; exit 3"}'
assert_eq "3"        "$(jq -r .exit_code "$res")"   "exit code is captured"
assert_eq "hello"    "$(jq -r .stdout "$res" | tr -d '\n')" "stdout is captured"
assert_eq "oops"     "$(jq -r .stderr "$res" | tr -d '\n')" "stderr is captured"

start=$SECONDS
call run_command '{"command":"sleep 10","timeout_seconds":1}'
assert_eq "true" "$(jq -r .timed_out "$res")" "slow command times out"
(( SECONDS - start < 5 )) && pass "timeout stops it quickly" || fail "timeout stops it quickly"

call run_command '{"command":"rm -rf /"}'
assert_contains "$(jq -r .error "$res")" "blocked" "blocked even with --yes"

export GEMINI_API_KEY=secret-test-key
call run_command '{"command":"env"}'
assert_not_contains "$(jq -r .stdout "$res")" "secret-test-key" "API key is hidden from commands"
OSBUDDY_YES=0

# ---- read_file ----
printf 'one\ntwo\nthree\n' > f.txt
call read_file '{"path":"f.txt","offset":2,"limit":1}'
assert_contains "$(jq -r .content "$res")" "2  two" "read_file returns numbered lines"
assert_eq 3 "$(jq -r .total_lines "$res")" "read_file reports total lines"
call read_file '{"path":"missing.txt"}'
assert_contains "$(jq -r .error "$res")" "not a file" "read_file reports a missing file"

# ---- write_file / edit_file ----
call write_file '{"path":"new.txt","content":"x"}'
[[ ! -e new.txt ]] && pass "write is denied without approval" || fail "write is denied without approval"

OSBUDDY_YES=1
call write_file '{"path":"new.txt","content":"line1\nline2"}'
assert_eq $'line1\nline2' "$(cat new.txt)" "write_file writes exact content"

printf 'a = 1\nb = 1\n' > e.txt
call edit_file '{"path":"e.txt","old_text":"= 1","new_text":"= 2"}'
assert_contains "$(jq -r .error "$res")" "matches 2 times" "edit_file refuses an ambiguous match"
call edit_file '{"path":"e.txt","old_text":"zzz","new_text":"y"}'
assert_contains "$(jq -r .error "$res")" "not found" "edit_file reports no match"
call edit_file '{"path":"e.txt","old_text":"b = 1","new_text":"b = [.*]"}'
assert_eq $'a = 1\nb = [.*]' "$(cat e.txt)" "edit_file replaces exact text once"

# ---- ask_user ----
call ask_user '{"question":"which?"}'
assert_contains "$(jq -r .error "$res")" "no human" "ask_user fails without a human"

finish
