# lib/ui.sh: messages and prompts for the human.
# Loaded with "source". Never run directly.
#
# Rule: all messages go to stderr. stdout is kept for the final answer only,
# so scripts can do: result=$(os-buddy "goal").

# Colours only when stderr is a terminal and NO_COLOR is not set.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  UI_RED=$'\e[31m' UI_GREEN=$'\e[32m' UI_YELLOW=$'\e[33m'
  UI_BLUE=$'\e[34m' UI_DIM=$'\e[2m' UI_BOLD=$'\e[1m' UI_RESET=$'\e[0m'
else
  UI_RED="" UI_GREEN="" UI_YELLOW="" UI_BLUE="" UI_DIM="" UI_BOLD="" UI_RESET=""
fi

ui_info()    { printf '%s==>%s %s\n'      "$UI_BLUE"   "$UI_RESET" "$*" >&2; }
ui_success() { printf '%sok:%s %s\n'      "$UI_GREEN"  "$UI_RESET" "$*" >&2; }
ui_warn()    { printf '%swarning:%s %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2; }
ui_error()   { printf '%serror:%s %s\n'   "$UI_RED"    "$UI_RESET" "$*" >&2; }

# One short, dim line for each action the agent takes:
#   ui_step run "free -h"   ->   > run   free -h
# A long or multi-line command is cut to its first line, so the screen
# shows what happens without a wall of shell code.
ui_step() {
  local kind="$1" text="$2" first more="" max
  first="${text%%$'\n'*}"
  if [[ "$first" != "$text" ]]; then
    more=" (+$(( $(printf '%s\n' "$text" | wc -l) - 1 )) lines)"
  fi
  max=$(( ${COLUMNS:-80} - 20 ))
  (( max < 20 )) && max=20
  (( ${#first} > max )) && first="${first:0:max}..."
  printf '%s  > %-5s %s%s%s\n' "$UI_DIM" "$kind" "$first" "$more" "$UI_RESET" >&2
}

# Extra detail, shown only with --verbose.
ui_debug() {
  [[ "${OSBUDDY_VERBOSE:-0}" == 1 ]] || return 0
  printf '%sdebug: %s%s\n' "$UI_DIM" "$*" "$UI_RESET" >&2
}

# Print a block of text (a preview or a diff), dimmed and indented.
ui_block() {
  printf '%s' "$UI_DIM" >&2
  sed 's/^/    /' >&2          # reads the block from stdin
  printf '%s' "$UI_RESET" >&2
}

# True when a human is at the keyboard (stdin and stderr are terminals).
ui_is_interactive() {
  [[ -t 0 && -t 2 ]]
}

# Ask yes/no. Returns 0 for yes, 1 for no.
# Default is NO (just Enter = no). With no human present, the answer is no.
ui_confirm() {
  local question="$1" answer
  ui_is_interactive || return 1
  printf '%s%s%s [y/N] ' "$UI_BOLD" "$question" "$UI_RESET" >&2
  read -r answer || { echo >&2; return 1; }     # Ctrl-D counts as no
  case "$answer" in
    y|Y|yes|Yes|YES) return 0 ;;
    *)               return 1 ;;
  esac
}

# Ask before one action. Enter alone means NO.
#   $1 the action   $2 the model's reason (may be empty)
#   $3 what "always" covers (empty: the option is not offered)   $4 why it asks
# Returns 0 yes, 1 no, 3 always. With no human present, the answer is no.
ui_approve() {
  local action="$1" reason="$2" always="$3" why="$4" answer opts
  ui_is_interactive || return 1
  printf '\n%s%s? approval needed%s\n' "$UI_YELLOW" "$UI_BOLD" "$UI_RESET" >&2
  printf '    %s%s%s\n' "$UI_BOLD" "$action" "$UI_RESET" >&2
  [[ -n "$reason" ]] && printf '    %sreason:%s %s\n' "$UI_DIM" "$UI_RESET" "$reason" >&2
  [[ -n "$why" ]]    && printf '    %srisk:%s   %s%s%s\n' "$UI_DIM" "$UI_RESET" "$UI_YELLOW" "$why" "$UI_RESET" >&2
  opts="[y] yes  [n] no"
  [[ -n "$always" ]] && opts+="  [a] always allow '$always' in this chat"
  while true; do
    printf '  %s%s%s > ' "$UI_DIM" "$opts" "$UI_RESET" >&2
    read -r answer || { echo >&2; return 1; }   # Ctrl-D counts as no
    case "$answer" in
      y|Y|yes|Yes|YES) return 0 ;;
      ""|n|N|no|No|NO) return 1 ;;
      a|A) [[ -n "$always" ]] && return 3 ;;
    esac
  done
}

# Ask once for several actions from the same model reply.
#   arguments: one "action<TAB>reason<TAB>risk" line per action
# Returns 0 all, 1 none, 2 decide one by one.
ui_approve_batch() {
  local line action reason risk answer i=0
  ui_is_interactive || return 1
  printf '\n%s%s? %d actions need approval%s\n' "$UI_YELLOW" "$UI_BOLD" "$#" "$UI_RESET" >&2
  for line in "$@"; do
    i=$(( i + 1 ))
    IFS=$'\t' read -r action reason risk <<< "$line"
    printf '  %2d. %s%s%s\n' "$i" "$UI_BOLD" "$action" "$UI_RESET" >&2
    [[ -n "$reason" ]] && printf '      %sreason:%s %s\n' "$UI_DIM" "$UI_RESET" "$reason" >&2
    [[ -n "$risk" ]]   && printf '      %srisk:%s   %s%s%s\n' "$UI_DIM" "$UI_RESET" "$UI_YELLOW" "$risk" "$UI_RESET" >&2
  done
  while true; do
    printf '  %s[y] all  [n] none  [o] one by one%s > ' "$UI_DIM" "$UI_RESET" >&2
    read -r answer || { echo >&2; return 1; }
    case "$answer" in
      y|Y|yes) return 0 ;;
      ""|n|N|no) return 1 ;;
      o|O) return 2 ;;
    esac
  done
}

# Ask a free-text question. The answer is printed to stdout.
ui_ask() {
  local question="$1" answer
  printf '%s?%s %s\n> ' "$UI_YELLOW" "$UI_RESET" "$question" >&2
  read -r answer || return 1
  printf '%s' "$answer"
}
