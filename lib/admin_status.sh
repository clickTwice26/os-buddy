# lib/admin_status.sh: "os-buddy status", one dashboard for everything.
# Loaded with "source" after the other admin_*.sh files, because it
# reuses their parts: the health table, the process table, the user and
# backup lists. Never run directly.

admin_status_usage() {
  cat <<'EOF'
Usage: os-buddy status

One screen with system health, top processes, users and backups,
then one overall verdict. For details use: health, disk, proc, users, backup.

Exit code: 0 all fine, 4 warning, 5 critical.
EOF
}

admin_cmd_status() {
  case "${1:-}" in
    -h|--help) admin_status_usage; return 0 ;;
    "")        ;;
    *)         ui_error "unknown argument: $1"; admin_status_usage >&2; return 2 ;;
  esac

  local status=$ADMIN_OK rc list zombies people logged admins f m newest=0 count=0 now schedules
  now="$(date +%s)"

  viz_title "System status"
  viz_kv "OS" "$(health_os), $(uname -m)"
  viz_kv "Uptime" "$(health_format_uptime "$(health_uptime_seconds)")"

  # 1. Health: CPU, load, memory, swap, fullest disk.
  health_collect
  viz_section "Health"
  health_table

  # 2. The 5 busiest processes.
  list="$(proc_list)"
  zombies="$(printf '%s\n' "$list" | awk -F'\t' '$7 ~ /^Z/' | grep -c .)"
  viz_section "Top 5 processes by CPU"
  printf '%s\n' "$list" | sort -t $'\t' -k3,3 -rn | head -n 5 | proc_table

  # 3. Users: counts only (details: os-buddy users).
  people="$(users_people | grep -c .)"
  logged="$(who 2> /dev/null | awk '{ print $1 }' | sort -u | grep -c .)"
  admins="$(users_admins | tr '\n' ' ')"
  viz_section "Users"
  viz_kv "People accounts" "$people (including root)"
  viz_kv "Logged in now" "$logged"
  viz_kv "Administrators" "${admins:-none}"

  # 4. Backups: how many, how old is the newest, any schedule.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    count=$(( count + 1 ))
    m="$(backup_mtime "$f")"
    (( m > newest )) && newest=$m
  done < <(backup_files)
  schedules="$(backup_crontab_read | grep -cF "$BACKUP_CRON_MARK")"
  viz_section "Backups"
  viz_kv "Backups" "$count in $OSBUDDY_BACKUP_DIR"
  if (( count > 0 )); then
    viz_kv "Newest" "$(admin_human_age $(( now - newest ))) ago"
  fi
  viz_kv "Schedules" "$schedules"

  # 5. One verdict for everything.
  viz_section "Verdict"
  health_issues; rc=$?
  status="$(admin_worse "$status" "$rc")"
  if (( zombies > 0 )); then
    viz_badge warn "$zombies zombie process(es)"
    status="$(admin_worse "$status" "$ADMIN_WARN")"
  fi
  if (( count == 0 )); then
    viz_badge warn "no backups yet: os-buddy backup create ~/Documents"
    status="$(admin_worse "$status" "$ADMIN_WARN")"
  elif (( now - newest > 7 * 86400 )); then
    viz_badge warn "newest backup is $(admin_human_age $(( now - newest ))) old"
    status="$(admin_worse "$status" "$ADMIN_WARN")"
  fi
  case "$status" in
    "$ADMIN_OK")   viz_badge ok   "Everything looks good" ;;
    "$ADMIN_WARN") viz_badge warn "Some things need attention soon" ;;
    *)             viz_badge crit "Something needs attention now" ;;
  esac
  return "$status"
}
