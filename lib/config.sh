# lib/config.sh: settings and command-line flags.
# Priority (lowest to highest): defaults < config file < environment < flags.

OSBUDDY_CONFIG_FILE="${OSBUDDY_CONFIG_FILE:-$HOME/.config/os-buddy/config}"

# Read KEY=VALUE lines from the config file.
# We parse instead of "source" so the file cannot run code.
# A value from the environment wins, so we only fill keys that are still empty.
config_load() {
  local file="$OSBUDDY_CONFIG_FILE" key value perms
  if [[ -f "$file" ]]; then
    # The file may hold the API key, so only the owner should read it.
    perms="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null)"
    [[ "$perms" == 600 ]] || ui_warn "$file should be private: run chmod 600 $file"

    while IFS='=' read -r key value; do
      case "$key" in
        GEMINI_API_KEY|OSBUDDY_MODEL|OSBUDDY_MAX_STEPS)
          value="${value%\"}"; value="${value#\"}"          # strip optional quotes
          [[ -z "${!key:-}" ]] && printf -v "$key" '%s' "$value"
          ;;
      esac                    # anything else (comments, blank lines) is ignored
    done < "$file"
  fi

  # Defaults for anything still empty.
  : "${OSBUDDY_MODEL:=gemini-3.6-flash}"
  : "${OSBUDDY_MAX_STEPS:=30}"
  : "${OSBUDDY_YES:=0}"
  : "${OSBUDDY_VERBOSE:=0}"
  : "${OSBUDDY_API_BASE:=https://generativelanguage.googleapis.com/v1beta}"
  OSBUDDY_GOAL=""
}

config_usage() {
  cat <<'EOF'
Usage:
  os-buddy                 open a chat (/reset, /help, /exit)
  os-buddy "goal"          complete one task, then exit

Options:
  -y, --yes            approve all "ask" actions (blocked ones stay blocked)
  -m, --model M        Gemini model to use
  -n, --max-steps N    stop after N steps (default 30)
  -v, --verbose        show debug output
  -h, --help           show this help
      --version        show the version

Config file: ~/.config/os-buddy/config (KEY=VALUE, chmod 600)
EOF
}

# Turn flags into settings. Words that are not flags become the goal.
config_parse_args() {
  local words=()
  while (( $# > 0 )); do
    case "$1" in
      -y|--yes)       OSBUDDY_YES=1 ;;
      -v|--verbose)   OSBUDDY_VERBOSE=1 ;;
      -m|--model)     [[ $# -ge 2 ]] || config_usage_error "$1 needs a value"
                      OSBUDDY_MODEL="$2"; shift ;;
      -n|--max-steps) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || config_usage_error "$1 needs a positive number"
                      OSBUDDY_MAX_STEPS="$2"; shift ;;
      -h|--help)      config_usage; exit 0 ;;
      --version)      echo "os-buddy $OSBUDDY_VERSION"; exit 0 ;;
      --)             shift; words+=("$@"); break ;;
      -*)             config_usage_error "unknown option: $1" ;;
      *)              words+=("$1") ;;
    esac
    shift
  done
  OSBUDDY_GOAL="${words[*]}"     # join all words with spaces
}

config_usage_error() {
  ui_error "$1"
  config_usage >&2
  exit 2
}
