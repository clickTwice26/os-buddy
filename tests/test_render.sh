#!/usr/bin/env bash
# tests/test_render.sh: the Markdown answer is shown well in a terminal.
source "$(dirname "$0")/helpers.sh"
export LC_ALL=C      # plain ASCII boxes, so the expected text is simple
load_libs

md=$'## Memory\n- **Used:** 5 GiB\n| Item | Value |\n|---|---:|\n| RAM | 14 GiB |\nRun `df -h` now.'

# Piped to a script: the text must come out unchanged.
out="$(printf '%s' "$md" | render_answer)"
assert_eq "$md" "$out" "pipe keeps Markdown unchanged"

# Forced render (as in a terminal), with plain ASCII and no colours.
out="$(printf '%s' "$md" | OSBUDDY_RENDER=1 render_answer)"
assert_not_contains "$out" "**" "bold markers removed"
assert_not_contains "$out" "##" "heading markers removed"
assert_not_contains "$out" "|---" "table separator removed"
assert_contains "$out" "Used: 5 GiB" "bullet text kept"
assert_contains "$out" "| RAM  | 14 GiB |" "table drawn as a box"
assert_contains "$out" "Run df -h now." "code ticks removed"

# Emoji are removed (needs a UTF-8 locale, like a real terminal).
if locale -a 2> /dev/null | grep -qi '^c\.utf-\?8$'; then
  out="$(LC_ALL=C.UTF-8 bash -c 'source "$1/lib/viz.sh"; source "$1/lib/render.sh"
    printf "### \360\237\222\276 Disk\n- \342\232\241 fast\n" | OSBUDDY_RENDER=1 render_answer' _ "$ROOT")"
  assert_contains "$out" $'Disk' "heading kept"
  assert_not_contains "$out" $'\360\237\222\276' "emoji removed from heading"
  assert_not_contains "$out" $'\342\232\241' "symbol removed from list"
fi

finish
