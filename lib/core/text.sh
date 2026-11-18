# lib/core/text.sh: small text and number helpers used everywhere.
# Each one prints its result, so you use it like:  name="$(trim "$name")"

# Remove spaces at the start:  "  hi " -> "hi "
trim_left() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "$s"
}

# Remove spaces at both ends:  "  hi " -> "hi"
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Cut a long text to N characters, ending with "...".
shorten() {
  local text="$1" n="$2"
  if (( ${#text} > n )); then
    printf '%s...' "${text:0:n-3}"
  else
    printf '%s' "$text"
  fi
}

# Kilobytes as a short size:  47980468 -> 45.8G
human_kb() {
  awk -v kb="$1" 'BEGIN {
    split("K M G T P", unit, " ")
    i = 1
    while (kb >= 1024 && i < 5) { kb /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), kb, unit[i]
  }'
}

# Seconds as a short age:  93784 -> 1d 2h,  3700 -> 1h 1m,  59 -> 59s
human_age() {
  local s="${1:-0}"
  if   (( s >= 86400 )); then printf '%dd %dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif (( s >= 3600 ));  then printf '%dh %dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  elif (( s >= 60 ));    then printf '%dm' $(( s / 60 ))
  else                        printf '%ds' "$s"
  fi
}

# True on macOS. Linux and macOS keep many facts in different places.
is_mac() {
  [[ "$(uname -s)" == Darwin ]]
}
