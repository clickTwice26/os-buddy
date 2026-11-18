# lib/admin/common.sh: runs the admin commands (os-buddy disk, health, ...).
#
# Admin commands do not use Gemini. They run fixed, safe checks and draw
# the result with lib/core/viz.sh, so they work without an API key.
#
# To add a command "foo": write a function admin_cmd_foo in its own file
# (lib/admin/foo.sh) and add that file to lib/load.sh. The dispatcher
# below finds the command by its function name.
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
REPORT_STATUS=0      # worst level seen by report_alert: 0, 4 or 5

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
  REPORT_STATUS=$ADMIN_OK
  "admin_cmd_$cmd" "${args[@]}"
}

# Show a problem as a badge and remember how bad it is.
#   report_alert warn|crit "text"
# A report ends with:  return "$REPORT_STATUS"
report_alert() {
  local level="$1" text="$2"
  viz_badge "$level" "$text"
  if [[ "$level" == crit ]]; then
    REPORT_STATUS=$ADMIN_CRIT
  elif [[ "$level" == warn ]] && (( REPORT_STATUS < ADMIN_WARN )); then
    REPORT_STATUS=$ADMIN_WARN
  fi
}

# The last line of a report: one badge that sums up REPORT_STATUS.
#   report_verdict "good text" "warning text" "critical text"
report_verdict() {
  case "$REPORT_STATUS" in
    "$ADMIN_OK")   viz_badge ok   "$1" ;;
    "$ADMIN_WARN") viz_badge warn "$2" ;;
    *)             viz_badge crit "$3" ;;
  esac
}

# Print a usage error for a command and return 2.
#   admin_usage_error "message" usage_function
admin_usage_error() {
  ui_error "$1"
  "$2" >&2
  return 2
}

# Ask before a change. Yes with --yes; no when nobody is at the keyboard.
admin_confirm() {
  [[ "$ADMIN_YES" == 1 ]] && return 0
  ui_is_interactive || { ui_error "no terminal to ask in; add --yes to approve"; return 1; }
  ui_confirm "$1"
}

# True for --dry-run. Prints the "nothing was changed" badge too.
admin_dry_run() {
  [[ "$ADMIN_DRY_RUN" == 1 ]] || return 1
  viz_badge info "dry run: nothing was changed"
}

# Run a command that changes the system, after showing it and asking.
#   admin_exec "what it does" command [args...]
# Returns the command's exit code, 1 when not approved, 0 for --dry-run.
# ADMIN_SHOW="text" admin_exec ...  shows "text" instead of the command
# (used when the command is a small helper function around the real one).
admin_exec() {
  local what="$1" shown
  shift
  shown="${ADMIN_SHOW:-$(printf '%q ' "$@")}"
  printf '  %s%s%s\n    %s$ %s%s\n' "$VIZ_BOLD" "$what" "$VIZ_RESET" \
    "$VIZ_DIM" "${shown% }" "$VIZ_RESET"
  admin_dry_run && return 0
  admin_confirm "Run it?" || { viz_badge info "cancelled, nothing was changed"; return 1; }
  "$@"
}
