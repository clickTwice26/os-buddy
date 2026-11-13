# lib/admin_proc.sh: "os-buddy proc", process management.
# Loaded with "source". Never run directly.
#
#   os-buddy proc              summary + top processes by CPU and memory
#   os-buddy proc find WORD    processes whose command line contains WORD
#   os-buddy proc kill PID     stop a process (asks first; --force for KILL)
#
# "ps -A -o ..." with these column names works the same on Linux and macOS.

admin_proc_usage() {
  cat <<'EOF'
Usage: os-buddy proc [find WORD | kill PID [--force]] [--yes] [--dry-run]

  (nothing)        summary, then the top 10 processes by CPU and by memory
  find WORD        processes whose command line contains WORD (any case)
  kill PID         ask, then stop the process politely (SIGTERM);
                   with --force, ask, then stop it at once (SIGKILL)

Exit code: 0 fine, 4 zombie processes found, 1 error, 2 usage error.
EOF
}

# One line per process, tab-separated:
#   pid, uid, cpu %, mem %, memory KB, running time, state, program name
proc_list() {
  ps -A -o pid=,uid=,pcpu=,pmem=,rss=,etime=,stat=,comm= 2> /dev/null | awk -v OFS='\t' '
    {
      name = $8                                  # a name may contain spaces
      for (i = 9; i <= NF; i++) name = name " " $i
      sub(/.*\//, "", name)                      # macOS gives a full path
      print $1, $2, $3, $4, $5, $6, $7, name
    }'
}

# User name for a user id (ps prints names cut to 8 letters, so we use ids).
proc_user() {
  id -nu "$1" 2> /dev/null || printf '%s' "$1"
}

# Print a table of processes from proc_list lines on stdin.
proc_table() {
  local pid uid cpu mem rss etime stat name cpu_int mem_int
  {
    printf 'PID\tUser\tCPU\tMemory\tRSS\tRunning\tProgram\n'
    while IFS=$'\t' read -r pid uid cpu mem rss etime stat name; do
      cpu_int="${cpu%.*}" mem_int="${mem%.*}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$(admin_cut "$(proc_user "$uid")" 12)" \
        "$(viz_bar "${cpu_int:-0}" 10)" "$(viz_bar "${mem_int:-0}" 10)" \
        "$(admin_human_kb "${rss:-0}")" "$etime" "$(admin_cut "$name" 28)"
    done
  } | viz_table
}

# The summary and the two top-10 tables.
proc_overview() {
  local list total running sleeping zombies stopped status=$ADMIN_OK
  list="$(proc_list)"
  total="$(printf '%s\n' "$list" | grep -c .)"
  running="$(printf '%s\n' "$list" | awk -F'\t' '$7 ~ /^R/' | grep -c .)"
  sleeping="$(printf '%s\n' "$list" | awk -F'\t' '$7 ~ /^[SI]/' | grep -c .)"
  stopped="$(printf '%s\n' "$list" | awk -F'\t' '$7 ~ /^T/' | grep -c .)"
  zombies="$(printf '%s\n' "$list" | awk -F'\t' '$7 ~ /^Z/' | grep -c .)"

  viz_title "Processes"
  viz_section "Summary"
  viz_kv "Total" "$total"
  viz_kv "Running" "$running"
  viz_kv "Sleeping" "$sleeping"
  viz_kv "Stopped" "$stopped"
  viz_kv "Zombies" "$zombies"

  viz_section "Top 10 by CPU"
  printf '%s\n' "$list" | sort -t $'\t' -k3,3 -rn | head -n 10 | proc_table
  printf '  %sCPU can pass 100%% for a program that uses several cores.%s\n' "$VIZ_DIM" "$VIZ_RESET"

  viz_section "Top 10 by memory"
  printf '%s\n' "$list" | sort -t $'\t' -k5,5 -rn | head -n 10 | proc_table

  viz_section "Alerts"
  if (( zombies > 0 )); then
    viz_badge warn "$zombies zombie process(es): finished, but the parent has not collected them"
    status=$ADMIN_WARN
  else
    viz_badge ok "No zombie processes"
  fi
  return "$status"
}

# Processes whose full command line contains a word (any case).
proc_find() {
  local word="$1" rows
  [[ -n "$word" ]] || { ui_error "proc find needs a word"; return 2; }
  viz_title "Processes matching \"$word\""
  # Take a snapshot first, then search it. The snapshot also holds
  # os-buddy itself and its helper copies (their command line contains
  # the word too), so skip our own PID, its children, and ps.
  rows="$(ps -A -o pid=,ppid=,args= 2> /dev/null)"
  rows="$(printf '%s\n' "$rows" | awk -v w="$word" -v me="$$" '
    BEGIN { w = tolower(w) }
    $1 != me && $2 != me && $3 !~ /(^|\/)ps$/ {
      line = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", line)
      if (index(tolower(line), w)) print $1
    }')"
  if [[ -z "$rows" ]]; then
    viz_badge info "no process matches \"$word\""
    return 0
  fi
  proc_list | awk -F'\t' 'NR == FNR { want[$1] = 1; next } want[$1]' \
    <(printf '%s\n' "$rows") - | proc_table
}

# Stop one process, after checks and a question.
proc_kill() {
  local pid="$1" force="$2" line uid name args signal=TERM i
  [[ "$pid" =~ ^[0-9]+$ ]] || { ui_error "PID must be a number: ${pid:-<missing>}"; return 2; }

  # Never stop the machine's first process, or os-buddy itself.
  if (( pid <= 1 )); then ui_error "refusing to stop PID $pid (the system needs it)"; return 1; fi
  if (( pid == $$ || pid == PPID )); then ui_error "refusing to stop os-buddy or its own shell"; return 1; fi

  line="$(proc_list | awk -F'\t' -v p="$pid" '$1 == p')"
  [[ -n "$line" ]] || { ui_error "no process with PID $pid"; return 1; }
  IFS=$'\t' read -r _ uid _ _ _ _ _ name <<< "$line"
  args="$(ps -o args= -p "$pid" 2> /dev/null)"

  viz_title "Stop process $pid"
  printf '%s\n' "$line" | proc_table
  viz_kv "Command" "$(admin_cut "$args" 70)"
  (( uid == 0 && EUID != 0 )) && viz_badge warn "it belongs to root: you will get 'permission denied' without sudo"

  [[ "$force" == 1 ]] && signal=KILL
  admin_exec "Send SIG$signal to $name ($pid)" kill -s "$signal" "$pid" || return 1
  [[ "$ADMIN_DRY_RUN" == 1 ]] && return 0

  # Give it up to 5 seconds to finish cleanly.
  for (( i = 0; i < 10; i++ )); do
    kill -0 "$pid" 2> /dev/null || { viz_badge ok "process $pid has stopped"; return 0; }
    sleep 0.5
  done
  viz_badge warn "process $pid is still running; try: os-buddy proc kill $pid --force"
  return "$ADMIN_WARN"
}

admin_cmd_proc() {
  case "${1:-}" in
    "")        proc_overview ;;
    find)      proc_find "${2:-}" ;;
    kill)      case "${3:-}" in
                 "")      proc_kill "${2:-}" 0 ;;
                 --force) proc_kill "${2:-}" 1 ;;
                 *)       ui_error "unknown option: $3"; return 2 ;;
               esac ;;
    -h|--help) admin_proc_usage ;;
    *)         ui_error "unknown proc action: $1"; admin_proc_usage >&2; return 2 ;;
  esac
}
