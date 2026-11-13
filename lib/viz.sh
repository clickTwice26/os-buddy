# lib/viz.sh: drawing kit for the admin reports (titles, bars, tables).
# Loaded with "source". Never run directly.
#
# Rule: reports are the answer, so they go to stdout (not stderr like ui.sh).
# Colours only when stdout is a terminal and NO_COLOR is not set.

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  VIZ_RED=$'\e[31m' VIZ_GREEN=$'\e[32m' VIZ_YELLOW=$'\e[33m'
  VIZ_CYAN=$'\e[36m' VIZ_DIM=$'\e[2m' VIZ_BOLD=$'\e[1m' VIZ_RESET=$'\e[0m'
else
  VIZ_RED="" VIZ_GREEN="" VIZ_YELLOW="" VIZ_CYAN="" VIZ_DIM="" VIZ_BOLD="" VIZ_RESET=""
fi

# Box-drawing characters need a UTF-8 terminal. Otherwise use plain ASCII.
if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then
  VIZ_H="─" VIZ_V="│" VIZ_FULL="█" VIZ_EMPTY="░"
  VIZ_TL="┌" VIZ_TR="┐" VIZ_BL="└" VIZ_BR="┘"
  VIZ_TM="┬" VIZ_BM="┴" VIZ_ML="├" VIZ_MR="┤" VIZ_MM="┼"
else
  VIZ_H="-" VIZ_V="|" VIZ_FULL="#" VIZ_EMPTY="."
  VIZ_TL="+" VIZ_TR="+" VIZ_BL="+" VIZ_BR="+"
  VIZ_TM="+" VIZ_BM="+" VIZ_ML="+" VIZ_MR="+" VIZ_MM="+"
fi

# Thresholds (percent) for yellow and red. Can be changed in the config.
: "${OSBUDDY_WARN_PCT:=70}"
: "${OSBUDDY_CRIT_PCT:=90}"

# Terminal width, at most 100 so reports stay readable on wide screens.
viz_width() {
  local w="${COLUMNS:-}"
  [[ "$w" =~ ^[0-9]+$ ]] || w="$(tput cols 2>/dev/null)"
  [[ "$w" =~ ^[0-9]+$ ]] || w=80
  (( w > 100 )) && w=100
  printf '%s' "$w"
}

# Repeat a string N times: viz_repeat "─" 5  ->  ─────
viz_repeat() {
  local out="" i
  for (( i = 0; i < $2; i++ )); do out+="$1"; done
  printf '%s' "$out"
}

# Visible length of a string: colour codes take no space on screen.
viz_len() {
  local s="$1" code
  for code in "$VIZ_RED" "$VIZ_GREEN" "$VIZ_YELLOW" "$VIZ_CYAN" \
              "$VIZ_DIM" "$VIZ_BOLD" "$VIZ_RESET"; do
    [[ -n "$code" ]] && s="${s//"$code"/}"
  done
  printf '%s' "${#s}"
}

# Pick a colour for a percentage: green, yellow or red.
viz_level_color() {
  if   (( $1 >= OSBUDDY_CRIT_PCT )); then printf '%s' "$VIZ_RED"
  elif (( $1 >= OSBUDDY_WARN_PCT )); then printf '%s' "$VIZ_YELLOW"
  else                                    printf '%s' "$VIZ_GREEN"
  fi
}

# Big title with the host name and time:  viz_title "Disk usage"
viz_title() {
  local w line
  w="$(viz_width)"
  line="$(viz_repeat "$VIZ_H" "$w")"
  printf '%s%s%s\n' "$VIZ_CYAN" "$line" "$VIZ_RESET"
  printf '%s %s%s  %s%s  %s%s\n' "$VIZ_BOLD" "$1" "$VIZ_RESET" \
    "$VIZ_DIM" "$(uname -n)" "$(date '+%Y-%m-%d %H:%M:%S')" "$VIZ_RESET"
  printf '%s%s%s\n' "$VIZ_CYAN" "$line" "$VIZ_RESET"
}

# Section heading:  ── Memory ────────────
viz_section() {
  local w rest
  w="$(viz_width)"
  rest=$(( w - ${#1} - 4 ))
  (( rest < 3 )) && rest=3
  printf '\n%s%s %s %s%s\n' "$VIZ_BOLD" "$VIZ_H$VIZ_H" "$1" \
    "$(viz_repeat "$VIZ_H" "$rest")" "$VIZ_RESET"
}

# Coloured bar for a percentage:  viz_bar 63 [width]  ->  ██████░░░░  63%
viz_bar() {
  local pct="$1" width="${2:-30}" full color
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  full=$(( (pct * width + 50) / 100 ))          # round to the nearest block
  color="$(viz_level_color "$pct")"
  printf '%s%s%s%s%s %3d%%' "$color" "$(viz_repeat "$VIZ_FULL" "$full")" \
    "$VIZ_DIM" "$(viz_repeat "$VIZ_EMPTY" $(( width - full )))" "$VIZ_RESET" "$pct"
}

# Status word with colour:  viz_badge ok|warn|crit|info "text"
viz_badge() {
  local color label
  case "$1" in
    ok)   color="$VIZ_GREEN"  label=" OK " ;;
    warn) color="$VIZ_YELLOW" label="WARN" ;;
    crit) color="$VIZ_RED"    label="CRIT" ;;
    *)    color="$VIZ_CYAN"   label="INFO" ;;
  esac
  printf '%s%s[%s]%s %s\n' "$color" "$VIZ_BOLD" "$label" "$VIZ_RESET" "$2"
}

# Badge level for a percentage: ok, warn or crit.
viz_level() {
  if   (( $1 >= OSBUDDY_CRIT_PCT )); then printf 'crit'
  elif (( $1 >= OSBUDDY_WARN_PCT )); then printf 'warn'
  else                                    printf 'ok'
  fi
}

# Key/value line:  viz_kv "Uptime" "3 days"  ->  Uptime        3 days
viz_kv() {
  printf '  %s%-16s%s %s\n' "$VIZ_DIM" "$1" "$VIZ_RESET" "$2"
}

# Table from tab-separated lines on stdin. The first line is the header.
#   printf 'Name\tSize\nroot\t40G\n' | viz_table
viz_table() {
  local -a rows=() widths=() cells=()
  local line i n len cols=0 sep top mid bot

  # 1. Read all rows and find the widest cell in each column.
  while IFS= read -r line || [[ -n "$line" ]]; do
    rows+=("$line")
    IFS=$'\t' read -r -a cells <<< "$line"
    (( ${#cells[@]} > cols )) && cols=${#cells[@]}
    for (( i = 0; i < ${#cells[@]}; i++ )); do
      len="$(viz_len "${cells[i]}")"
      (( len > ${widths[i]:-0} )) && widths[i]=$len
    done
  done
  (( ${#rows[@]} == 0 )) && return 0

  # 2. Build the three border lines: top, under the header, bottom.
  top="$VIZ_TL" mid="$VIZ_ML" bot="$VIZ_BL"
  for (( i = 0; i < cols; i++ )); do
    sep="$(viz_repeat "$VIZ_H" $(( ${widths[i]:-0} + 2 )))"
    top+="$sep" mid+="$sep" bot+="$sep"
    if (( i < cols - 1 )); then
      top+="$VIZ_TM" mid+="$VIZ_MM" bot+="$VIZ_BM"
    fi
  done
  top+="$VIZ_TR" mid+="$VIZ_MR" bot+="$VIZ_BR"

  # 3. Print every row, padding each cell to its column width.
  printf '%s%s%s\n' "$VIZ_DIM" "$top" "$VIZ_RESET"
  for (( n = 0; n < ${#rows[@]}; n++ )); do
    IFS=$'\t' read -r -a cells <<< "${rows[n]}"
    printf '%s%s%s' "$VIZ_DIM" "$VIZ_V" "$VIZ_RESET"
    for (( i = 0; i < cols; i++ )); do
      len="$(viz_len "${cells[i]:-}")"
      if (( n == 0 )); then
        printf ' %s%s%s' "$VIZ_BOLD" "${cells[i]:-}" "$VIZ_RESET"
      else
        printf ' %s' "${cells[i]:-}"
      fi
      printf '%*s %s%s%s' $(( ${widths[i]:-0} - len )) "" "$VIZ_DIM" "$VIZ_V" "$VIZ_RESET"
    done
    printf '\n'
    (( n == 0 )) && printf '%s%s%s\n' "$VIZ_DIM" "$mid" "$VIZ_RESET"
  done
  printf '%s%s%s\n' "$VIZ_DIM" "$bot" "$VIZ_RESET"
}
