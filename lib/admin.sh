# lib/admin.sh: runs the admin commands (os-buddy disk, health, ...).
# Loaded with "source". Never run directly.
#
# Admin commands do not use Gemini. They run fixed, safe checks and draw
# the result with lib/viz.sh, so they work without an API key.
#
# To add a command "foo", define a function admin_cmd_foo in its own file.
# The dispatcher below finds it by name, so nothing else needs to change.
#
# Exit codes of a report: 0 all fine, 4 warning, 5 critical, 1 error.

ADMIN_OK=0 ADMIN_WARN=4 ADMIN_CRIT=5

# True when the word is the name of an admin command.
admin_is_command() {
  [[ "$1" =~ ^[a-z]+$ ]] && declare -F "admin_cmd_$1" > /dev/null
}

# Run one admin command: admin_run disk [args...]
admin_run() {
  local cmd="$1"
  shift
  "admin_cmd_$cmd" "$@"
}

# Turn kilobytes into a short human size: 47980468 -> 45.8G
admin_human_kb() {
  awk -v kb="$1" 'BEGIN {
    split("K M G T P", unit, " ")
    i = 1
    while (kb >= 1024 && i < 5) { kb /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), kb, unit[i]
  }'
}

# Keep the worst exit code seen so far: admin_worse CURRENT NEW
admin_worse() {
  if (( $2 > $1 )); then printf '%s' "$2"; else printf '%s' "$1"; fi
}
