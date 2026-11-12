# lib/policy.sh: the safety layer between the model and the OS.
# Every command is classified as one of:
#   block  never runs, not even with --yes
#   allow  runs automatically (known read-only)
#   ask    needs a human "y"
# It fails closed: anything not clearly safe is "ask".

# Commands that only read. A command line is allowed only if every part
# (split at |, ||, && and ;) starts with one of these.
POLICY_READ_ONLY="ls cat head tail wc grep df du ps uname whoami id date pwd uptime
free stat file which sort uniq cut echo find git
lsblk lscpu lsusb lspci lsmod blkid findmnt nproc getconf hostname w who groups
vmstat iostat mpstat ss netstat ip systemctl journalctl smartctl sysctl top
sw_vers vm_stat diskutil basename dirname realpath readlink tree printf tr column
dmesg lsof getent swapon"

# Programs that never get "always allow": each use must be approved on its own.
POLICY_NEVER_ALWAYS="sudo su doas rm dd mkfs chmod chown kill pkill killall
shutdown reboot halt poweroff mv cp bash sh zsh eval exec"

# Paths whose contents must never leave the machine without asking.
# (Tool results are sent to Google.)
POLICY_SENSITIVE_RE='(\.ssh|\.aws|\.gnupg|\.env([^[:alnum:]]|$)|/etc/shadow|id_rsa|id_ed25519|\.pem([^[:alnum:]]|$)|\.key([^[:alnum:]]|$)|os-buddy/config)'

# Harmless redirects: throwing output away, or joining stderr into stdout.
POLICY_NULL_RE='^(.*)([[:space:]]|^)([12]?>|&>)[[:space:]]*/dev/null([[:space:]].*|$)'
POLICY_JOIN_RE='^(.*)([[:space:]]|^)2>&1([[:space:]].*|$)'

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

# Replace every quoted string with the letter Q, so a "|" or ";" inside
# quotes is not mistaken for a real one: grep -E 'a|b' f  ->  grep -E Q f
# The text is read left to right, like the shell does. A double-quoted
# string that contains $ or ` can run code, so it is kept as it is
# (the $( and ` checks later will then ask).
policy_mask_quotes() {
  local s="$1" out="" c q="" buf="" i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ -z "$q" ]]; then                       # outside quotes
      if [[ "$c" == "'" || "$c" == '"' ]]; then q="$c" buf="$c"; else out+="$c"; fi
    else                                         # inside quotes
      buf+="$c"
      if [[ "$c" == "$q" ]]; then
        if [[ "$q" == '"' && ( "$buf" == *'$'* || "$buf" == *'`'* ) ]]; then
          out+="$buf"                            # may run code: keep it visible
        else
          out+="Q"
        fi
        q="" buf=""
      fi
    fi
  done
  [[ -n "$q" ]] && out+="$buf"                   # unclosed quote: keep as is
  printf '%s' "$out"
}

# Remove redirects that cannot change anything: 2>/dev/null, >/dev/null, 2>&1.
policy_strip_harmless() {
  local s="$1"
  while [[ "$s" =~ $POLICY_NULL_RE ]]; do s="${BASH_REMATCH[1]} ${BASH_REMATCH[4]}"; done
  while [[ "$s" =~ $POLICY_JOIN_RE ]]; do s="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"; done
  printf '%s' "$s"
}

# Is one simple command (no pipes or chains) read-only? Returns 0 if yes.
policy_segment_read_only() {
  local first rest
  read -r first rest <<< "$1"                  # first word, then the rest
  [[ -n "$first" ]] || return 1
  [[ " ${POLICY_READ_ONLY//$'\n'/ } " == *" $first "* ]] || return 1

  # Read-only programs that also have a writing or acting mode.
  case "$first" in
    find)      [[ " $rest " =~ [[:space:]]-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)[[:space:]] ]] && return 1 ;;
    sort)      [[ " $rest " =~ [[:space:]](-o|--output) ]] && return 1 ;;
    date)      [[ " $rest " =~ [[:space:]](-s|--set) ]] && return 1 ;;
    git)       [[ "$rest" =~ ^(status|log|diff|show)([[:space:]]|$) ]] || return 1 ;;
    tree)      [[ " $rest " =~ [[:space:]]-o[[:space:]] ]] && return 1 ;;        # -o writes a file
    swapon)    [[ "$rest" =~ ^(--show|-s|--summary)([[:space:]=]|$) ]] || return 1 ;;  # only listing
    ss)        [[ " $rest " =~ [[:space:]](-K|--kill)[[:space:]] ]] && return 1 ;;
    hostname)  [[ -z "$rest" || ( "$rest" == -* && ! " $rest " =~ [[:space:]](-F|-b|--file|--boot)[[:space:]] ) ]] || return 1 ;;
    ip)        [[ " $rest " =~ [[:space:]](add|del|delete|set|flush|change|replace|append)[[:space:]] ]] && return 1 ;;
    systemctl) [[ "$rest" =~ ^(status|list-units|list-unit-files|list-timers|is-active|is-enabled|is-failed|show|--failed)([[:space:]]|$) ]] || return 1 ;;
    journalctl) [[ " $rest " =~ [[:space:]](--vacuum|--rotate|--flush) ]] && return 1 ;;
    smartctl)  [[ " $rest " =~ [[:space:]](-t|--test|-s|--smart|-o|--offlineauto|-S|--saveauto|-X|--abort) ]] && return 1 ;;
    sysctl)    [[ " $rest " =~ [[:space:]](-w|--write|-p|--load) || "$rest" == *=* ]] && return 1 ;;
    top)       [[ " $rest " =~ [[:space:]](-b|-l)[[:space:]0-9] ]] || return 1 ;;   # top must be in batch mode
    diskutil)  [[ "$rest" =~ ^(list|info|apfs[[:space:]]+list)([[:space:]]|$) ]] || return 1 ;;
    dmesg)     [[ " $rest " =~ [[:space:]](-c|-C|--clear|--read-clear|-n|--console-level) ]] && return 1 ;;
  esac
  return 0
}

# Classify a shell command. Prints block, allow or ask.
policy_check_command() {
  local cmd="$1" re seg s
  local -a segs

  for re in "${POLICY_BLOCK_RES[@]}"; do
    if [[ "$cmd" =~ $re ]]; then echo block; return; fi
  done
  if policy_is_sensitive "$cmd"; then echo ask; return; fi

  s="$(policy_mask_quotes "$cmd")"
  s="$(policy_strip_harmless "$s")"

  # Left after cleaning: real redirects, substitutions, background jobs or
  # newlines. Any of them can write files or hide a second command.
  if [[ "$s" == *[\>\<\`]* || "$s" == *'$('* || "$s" == *$'\n'* ]]; then
    echo ask; return
  fi
  s="${s//&&/;}"              # a && b,  a || b,  a ; b,  a | b:
  s="${s//||/;}"              # all four just join simple commands,
  s="${s//|/;}"               # so split them all the same way
  if [[ "$s" == *'&'* ]]; then echo ask; return; fi   # "a & b" runs a in the background

  IFS=';' read -r -a segs <<< "$s"
  (( ${#segs[@]} > 0 )) || { echo ask; return; }
  for seg in "${segs[@]}"; do
    policy_segment_read_only "$seg" || { echo ask; return; }
  done
  echo allow
}

# A plain-English reason for a decision, shown when the user presses "?".
policy_explain() {
  local cmd="$1" s
  case "$(policy_check_command "$cmd")" in
    block) echo "it matches a pattern that can destroy the system, so it never runs" ;;
    allow) echo "every part only reads information" ;;
    *)
      s="$(policy_strip_harmless "$(policy_mask_quotes "$cmd")")"
      if policy_is_sensitive "$cmd"; then
        echo "it touches a private file (keys, passwords or .env); its content would be sent to Gemini"
      elif [[ "$cmd" =~ (^|[;&|[:space:]])sudo[[:space:]] ]]; then
        echo "it runs as administrator (sudo)"
      elif [[ "$s" == *[\>\<]* ]]; then
        echo "it redirects output into a file, which can create or overwrite it"
      elif [[ "$s" == *'$('* || "$s" == *'`'* ]]; then
        echo "it runs a hidden command inside \$( ) or backticks"
      else
        echo "'$(policy_program "$cmd")' is not on the read-only list, so it may change something"
      fi ;;
  esac
}

# The first program in a command, skipping sudo: "sudo apt install x" -> apt.
policy_program() {
  local first rest
  read -r first rest <<< "$1"
  if [[ "$first" == sudo || "$first" == doas ]]; then
    while [[ "$rest" == -* ]]; do read -r _ rest <<< "$rest"; done   # skip sudo flags
    read -r first rest <<< "$rest"
  fi
  printf '%s' "${first##*/}"
}

# Can "always allow for this session" be offered for this command?
# Not for sudo, deleting, killing and similar, and not for chained commands.
policy_can_always() {
  local cmd="$1" s first
  s="$(policy_mask_quotes "$cmd")"
  [[ "$s" == *[\;\&\|\>\<\`]* || "$s" == *'$('* || "$s" == *$'\n'* ]] && return 1
  read -r first _ <<< "$cmd"
  [[ " ${POLICY_NEVER_ALWAYS//$'\n'/ } " == *" ${first##*/} "* ]] && return 1
  return 0
}

# Classify reading a file: ask for sensitive paths, otherwise allow.
policy_check_read() {
  if policy_is_sensitive "$1"; then echo ask; else echo allow; fi
}
