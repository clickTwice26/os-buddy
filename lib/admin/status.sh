# lib/admin/status.sh: "os-buddy status", one dashboard for everything.
# It reuses parts of the other reports: the health table, the process
# table, the user and backup lists. So it is loaded after them.

status_usage() {
  cat <<'EOF'
Usage: os-buddy status

One screen with system health, top processes, users and backups,
then one overall verdict. For details use: health, disk, proc, users, backup.

Exit code: 0 all fine, 4 warning, 5 critical.
EOF
}

admin_cmd_status() {
  case "${1:-}" in
    -h|--help) status_usage; return 0 ;;
    "")        ;;
    *)         admin_usage_error "unknown argument: $1" status_usage; return ;;
  esac

  local list zombies f m now newest=0 backups=0
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
  read -r _ _ _ _ zombies < <(printf '%s\n' "$list" | proc_count_states)
  viz_section "Top 5 processes by CPU"
  printf '%s\n' "$list" | sort -t $'\t' -k3,3 -rn | head -n 5 | proc_table

  # 3. Users: counts only (details: os-buddy users).
  local admins
  admins="$(users_admins | tr '\n' ' ')"
  viz_section "Users"
  viz_kv "People accounts" "$(users_people | grep -c .) (including root)"
  viz_kv "Logged in now" "$(who 2> /dev/null | awk '{ print $1 }' | sort -u | grep -c .)"
  viz_kv "Administrators" "${admins:-none}"

  # 4. Backups: how many, how old the newest is, any schedule.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    backups=$(( backups + 1 ))
    m="$(backup_mtime "$f")"
    (( m > newest )) && newest=$m
  done < <(backup_files)
  viz_section "Backups"
  viz_kv "Backups" "$backups in $OSBUDDY_BACKUP_DIR"
  (( backups > 0 )) && viz_kv "Newest" "$(human_age $(( now - newest ))) ago"
  viz_kv "Schedules" "$(backup_crontab_read | grep -cF "$BACKUP_CRON_MARK")"

  # 5. One verdict for everything.
  viz_section "Verdict"
  health_issues
  (( zombies > 0 )) && report_alert warn "$zombies zombie process(es)"
  if (( backups == 0 )); then
    report_alert warn "no backups yet: os-buddy backup create ~/Documents"
  elif (( now - newest > 7 * 86400 )); then
    report_alert warn "newest backup is $(human_age $(( now - newest ))) old"
  fi
  report_verdict "Everything looks good" "Some things need attention soon" "Something needs attention now"
  return "$REPORT_STATUS"
}
