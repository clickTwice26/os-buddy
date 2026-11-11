# lib/policy.sh: the safety layer between the model and the OS.
# Every command is classified as one of:
#   block  never runs, not even with --yes
#   allow  runs automatically (known read-only)
#   ask    needs a human "y"
# It fails closed: anything not clearly safe is "ask".

# Commands that only read. A pipeline is allowed only if every part starts with one.
POLICY_READ_ONLY="ls cat head tail wc grep df du ps uname whoami id date pwd uptime
free stat file which sort uniq cut echo find git"

# Paths whose contents must never leave the machine without asking.
# (Tool results are sent to Google.)
POLICY_SENSITIVE_RE='(\.ssh|\.aws|\.gnupg|\.env([^[:alnum:]]|$)|/etc/shadow|id_rsa|id_ed25519|\.pem([^[:alnum:]]|$)|\.key([^[:alnum:]]|$)|os-buddy/config)'

# Patterns that are always blocked. One regex per line; matched anywhere in the command.
POLICY_BLOCK_RES=(
  # rm -r / -f on root, home or a system folder
  '(^|[;&|[:space:]])rm[[:space:]]+(-[[:alpha:]-]*[[:space:]]+)*(/|/\*|~|~/|\$HOME|/(etc|usr|bin|sbin|boot|lib|lib64|var|dev|proc|sys|root|home))/?([[:space:]]|$)'
  '(^|[^[:alnum:]_])mkfs'                                  # format a disk
  '(^|[^[:alnum:]_])dd[[:space:]].*of=/dev/'               # write raw to a device
  '>[[:space:]]*/dev/(sd|nvme|hd|vd|mmcblk)'                # redirect onto a disk
  ':\(\)[[:space:]]*\{'                                     # fork bomb :(){ :|:& };:
  '(chmod|chown)[[:space:]]+-[[:alpha:]]*R.*[[:space:]]/([[:space:]]|$)'  # recursive on /
)

# True if the text mentions a sensitive path.
policy_is_sensitive() {
  [[ "$1" =~ $POLICY_SENSITIVE_RE ]]
}

# Classify a shell command. Prints block, allow or ask.
policy_check_command() {
  local cmd="$1" re seg first rest
  local -a segs

  for re in "${POLICY_BLOCK_RES[@]}"; do
    if [[ "$cmd" =~ $re ]]; then echo block; return; fi
  done

  # Chaining, redirects, substitutions or newlines can hide a second command.
  if [[ "$cmd" == *[\;\&\>\<\`]* || "$cmd" == *'$('* || "$cmd" == *$'\n'* ]]; then
    echo ask; return
  fi
  if policy_is_sensitive "$cmd"; then echo ask; return; fi

  # Check each part of a pipeline: "a | b | c".
  IFS='|' read -r -a segs <<< "$cmd"
  for seg in "${segs[@]}"; do
    read -r first rest <<< "$seg"              # first word, then the rest
    [[ -n "$first" ]] || { echo ask; return; }  # empty part, e.g. "a || b"
    [[ " ${POLICY_READ_ONLY//$'\n'/ } " == *" $first "* ]] || { echo ask; return; }

    # Read-only commands that have a writing mode.
    case "$first" in
      find) [[ " $rest " =~ [[:space:]]-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)[[:space:]] ]] && { echo ask; return; } ;;
      sort) [[ " $rest " =~ [[:space:]](-o|--output) ]] && { echo ask; return; } ;;
      date) [[ " $rest " =~ [[:space:]](-s|--set) ]] && { echo ask; return; } ;;
      git)  [[ "$rest" =~ ^(status|log|diff)([[:space:]]|$) ]] || { echo ask; return; } ;;
    esac
  done
  echo allow
}

# Classify reading a file: ask for sensitive paths, otherwise allow.
policy_check_read() {
  if policy_is_sensitive "$1"; then echo ask; else echo allow; fi
}
