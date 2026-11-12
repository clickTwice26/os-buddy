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

# ---- approvals: always, groups, the prompt ----
OSBUDDY_YES=0
tools_approve ask "mkdir x" mkdir 2> /dev/null; assert_eq 1 "$?" "no human: denied"
TOOLS_ALWAYS[mkdir]=1
tools_approve ask "mkdir x" mkdir 2> /dev/null; assert_eq 0 "$?" "always-allowed key runs"
tools_approve block "rm -rf /" rm 2> /dev/null; assert_eq 2 "$?" "blocked even when always-allowed exists"
TOOLS_ALWAYS=()
TOOLS_BATCH=all
tools_approve ask "touch y" "" 2> /dev/null; assert_eq 0 "$?" "group answer: all"
TOOLS_BATCH=none
tools_approve ask "touch y" "" 2> /dev/null; assert_eq 1 "$?" "group answer: none"
TOOLS_BATCH=all
tools_approve block "mkfs /dev/sda" "" 2> /dev/null; assert_eq 2 "$?" "group answer never unblocks"
TOOLS_BATCH=""

printf '%s' '{"command":"df -h"}' > a.json
assert_eq "" "$(tools_needs_approval run_command a.json)" "read-only call needs no approval"
printf '%s' '{"command":"apt install htop","reason":"install a viewer"}' > a.json
assert_eq $'apt install htop\tinstall a viewer\t\'apt\' is not on the read-only list, so it may change something' \
  "$(tools_needs_approval run_command a.json)" "change needs approval, with reason and risk"

# The prompt itself, with a pretend human typing answers.
ui_is_interactive() { return 0; }
printf 'y\n' | ui_approve "touch x" "" "" "why" 2> /dev/null; assert_eq 0 "$?" "prompt: y = yes"
printf '\n'  | ui_approve "touch x" "" "" "why" 2> /dev/null; assert_eq 1 "$?" "prompt: Enter = no"
printf 'a\n' | ui_approve "touch x" "" "touch" "why" 2> /dev/null; assert_eq 3 "$?" "prompt: a = always"
printf 'a\nn\n' | ui_approve "sudo x" "" "" "why" 2> /dev/null; assert_eq 1 "$?" "prompt: no 'a' when not offered"
out="$(printf 'y\n' | ui_approve "touch x" "make a file" "" "it may change files" 2>&1)"
assert_contains "$out" "reason: make a file" "prompt shows the reason"
assert_contains "$out" "risk:   it may change files" "prompt shows the risk"
printf 'o\n' | ui_approve_batch $'a\tr\tx' $'b\t\t' 2> /dev/null; assert_eq 2 "$?" "group prompt: one by one"
out="$(printf 'n\n' | ui_approve_batch $'mkdir d\tfor backups\tmay change' 2>&1)"
assert_contains "$out" "risk:   may change" "group prompt shows the risk"

finish
