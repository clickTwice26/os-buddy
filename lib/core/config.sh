# lib/core/config.sh: settings and command-line flags.
# Priority (lowest to highest): defaults < config file < environment < flags.

# Which config file to read (first match wins):
#   1. OSBUDDY_CONFIG_FILE, if you set it yourself
#   2. .env in the os-buddy project folder (next to bin/ and lib/)
#   3. ~/.config/os-buddy/config
# It is the PROJECT's .env, not the current folder's, so os-buddy never
# reads some other project's .env by accident.
if [[ -z "${OSBUDDY_CONFIG_FILE:-}" ]]; then
  if [[ -n "${OSBUDDY_ROOT:-}" && -f "$OSBUDDY_ROOT/.env" ]]; then
    OSBUDDY_CONFIG_FILE="$OSBUDDY_ROOT/.env"
  else
    OSBUDDY_CONFIG_FILE="$HOME/.config/os-buddy/config"
  fi
fi

# The config file may hold the API key, so only its owner may read it.
config_make_private() {
  local file="$1" perms
  perms="$(stat -c '%a' "$file" 2> /dev/null || stat -f '%Lp' "$file" 2> /dev/null)"
  [[ "$perms" == 600 ]] && return 0
  chmod 600 "$file" 2> /dev/null || ui_warn "$file should be private: run chmod 600 $file"
}

# Read KEY=VALUE lines from the config file.
# The file is parsed, never "source"d, so it cannot run code.
# Accepted forms:  KEY=value   KEY="value"   KEY='value'   export KEY=value
# A value already set in the environment wins over the file.
config_read_file() {
  local file="$1" key value
  [[ -f "$file" ]] || return 0
  config_make_private "$file"

  # "|| [[ -n $key ]]" also reads a last line that has no newline.
  while IFS='=' read -r key value || [[ -n "${key:-}" ]]; do
    key="$(trim "$key")"
    key="$(trim "${key#export }")"
    value="$(trim "$value")"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"                  # drop the outer quotes
    fi

    [[ "$key" == GOOGLE_API_KEY ]] && key=GEMINI_API_KEY   # Google's other name for it
    case "$key" in
      GEMINI_API_KEY|OSBUDDY_MODEL|OSBUDDY_MAX_STEPS)
        [[ -z "${!key:-}" ]] && printf -v "$key" '%s' "$value" ;;
    esac                      # anything else (comments, blank lines) is ignored
  done < "$file"
}

config_load() {
  config_read_file "$OSBUDDY_CONFIG_FILE"

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
  os-buddy status          one dashboard for everything (no API key needed)
  os-buddy disk [PATH]     disk usage report (no API key needed)
  os-buddy health          system health report (no API key needed)
  os-buddy proc [find W | kill PID]   processes: top lists, search, stop
  os-buddy backup ACTION   create, list, verify, restore, schedule backups
  os-buddy users [add|lock|unlock|delete NAME]   accounts, admins, logins

Options:
  -y, --yes            approve all "ask" actions (blocked ones stay blocked)
  -m, --model M        Gemini model to use
  -n, --max-steps N    stop after N steps (default 30)
  -v, --verbose        show debug output
  -h, --help           show this help
      --version        show the version

Config file: .env in the project folder, else ~/.config/os-buddy/config
(KEY=VALUE lines, chmod 600)
EOF
}

# Print an error and the usage, then quit with code 2.
config_usage_error() {
  ui_error "$1"
  config_usage >&2
  exit 2
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
