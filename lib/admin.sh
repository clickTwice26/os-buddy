# lib/admin.sh: runs the admin commands (os-buddy disk, health, ...).
# Loaded with "source". Never run directly.
#
# Admin commands do not use Gemini. They run fixed, safe checks and draw
# the result with lib/viz.sh, so they work without an API key.
#
# To add a command "foo", define a function admin_cmd_foo in its own file.
# The dispatcher below finds it by name, so nothing else needs to change.
#
# Exit codes of a report: 0 all fine, 4 warning, 5 critical, 1 error,
# 2 usage error.
#
# Flags that work for every admin command (anywhere on the line):
#   -y, --yes       approve every change without asking
#   -n, --dry-run   show the commands that would change something, run none

ADMIN_OK=0 ADMIN_WARN=4 ADMIN_CRIT=5
ADMIN_YES=0
ADMIN_DRY_RUN=0

# True when the word is the name of an admin command.
admin_is_command() {
  [[ "$1" =~ ^[a-z]+$ ]] && declare -F "admin_cmd_$1" > /dev/null
}

# Run one admin command: admin_run disk [args...]
# The shared flags are taken out here, so each command never sees them.
admin_run() {
  local cmd="$1" arg
  local -a args=()
  shift
  for arg in "$@"; do
    case "$arg" in
      -y|--yes)     ADMIN_YES=1 ;;
      -n|--dry-run) ADMIN_DRY_RUN=1 ;;
      *)            args+=("$arg") ;;
    esac
  done
  "admin_cmd_$cmd" "${args[@]}"
}

# Ask before a change. Yes with --yes; no when nobody is at the keyboard.
admin_confirm() {
  [[ "$ADMIN_YES" == 1 ]] && return 0
  ui_is_interactive || { ui_error "no terminal to ask in; add --yes to approve"; return 1; }
  ui_confirm "$1"
}

# Run a command that changes the system, after showing it and asking.
#   admin_exec "what it does" command [args...]
# Returns the command's exit code, 1 when not approved, 0 for --dry-run.
admin_exec() {
  local what="$1" shown
  shift
  shown="$(printf '%q ' "$@")"
  printf '  %s%s%s\n    %s$ %s%s\n' "$VIZ_BOLD" "$what" "$VIZ_RESET" \
    "$VIZ_DIM" "${shown% }" "$VIZ_RESET"
  if [[ "$ADMIN_DRY_RUN" == 1 ]]; then
    viz_badge info "dry run: nothing was changed"
    return 0
  fi
  admin_confirm "Run it?" || { viz_badge info "cancelled, nothing was changed"; return 1; }
  "$@"
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

# Turn seconds into a short age: 93784 -> 1d 2h, 3700 -> 1h 1m, 59 -> 59s
admin_human_age() {
  local s="${1:-0}"
  if   (( s >= 86400 )); then printf '%dd %dh' $(( s / 86400 )) $(( s % 86400 / 3600 ))
  elif (( s >= 3600 ));  then printf '%dh %dm' $(( s / 3600 )) $(( s % 3600 / 60 ))
  elif (( s >= 60 ));    then printf '%dm' $(( s / 60 ))
  else                        printf '%ds' "$s"
  fi
}

# Cut a long text to N characters with "..." at the end.
admin_cut() {
  local text="$1" n="$2"
  if (( ${#text} > n )); then printf '%s...' "${text:0:n-3}"; else printf '%s' "$text"; fi
}

# Keep the worst exit code seen so far: admin_worse CURRENT NEW
admin_worse() {
  if (( $2 > $1 )); then printf '%s' "$2"; else printf '%s' "$1"; fi
}
