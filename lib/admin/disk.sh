# lib/admin/disk.sh: "os-buddy disk", the disk monitoring report.
#
#   os-buddy disk          usage of every real disk, with alerts
#   os-buddy disk PATH     the same, plus the biggest items inside PATH

disk_usage() {
  cat <<'EOF'
Usage: os-buddy disk [PATH]

Shows how full each disk is, with a coloured bar and an alert level.
With PATH, also lists the 10 biggest files and folders inside PATH.

Exit code: 0 all fine, 4 a disk is above the warning level,
5 a disk is above the critical level, 1 error.
Levels: OSBUDDY_WARN_PCT (default 70) and OSBUDDY_CRIT_PCT (default 90).
EOF
}

# One line per real disk, tab-separated: mount, device, size, used, free (KB), use %.
# "df -P" prints the same POSIX columns on Linux and macOS.
disk_list() {
  df -P -k 2> /dev/null | awk -v OFS='\t' '
    NR == 1 { next }                       # skip the header line
    $1 !~ /^\/dev\// { next }              # skip tmpfs, proc and other fake disks
    $1 ~ /^\/dev\/loop/ { next }           # skip snap images (always 100% full)
    {
      mount = $6                           # a mount point may contain spaces
      for (i = 7; i <= NF; i++) mount = mount " " $i
      pct = $5; sub(/%/, "", pct)
      print mount, $1, $2, $3, $4, pct
    }'
}

admin_cmd_disk() {
  local path="" mount dev size used free pct table
  case "${1:-}" in
    -h|--help) disk_usage; return 0 ;;
    -*)        admin_usage_error "unknown option: $1" disk_usage; return ;;
    "")        ;;
    *)         path="$1"
               [[ -d "$path" ]] || { ui_error "not a folder: $path"; return 1; } ;;
  esac

  # One pass over the disks: build the table rows, collect the alerts.
  local -a alerts=()
  table=$'Mount\tDevice\tSize\tUsed\tFree\tUse\tStatus\n'
  while IFS=$'\t' read -r mount dev size used free pct; do
    table+="$mount"$'\t'"$dev"$'\t'"$(human_kb "$size")"$'\t'"$(human_kb "$used")"
    table+=$'\t'"$(human_kb "$free")"$'\t'"$(viz_bar "$pct" 20)"$'\t'"$(viz_level_word "$pct")"$'\n'
    case "$(viz_level "$pct")" in
      crit) alerts+=("crit|$mount is $pct% full, only $(human_kb "$free") left") ;;
      warn) alerts+=("warn|$mount is $pct% full") ;;
    esac
  done < <(disk_list)

  viz_title "Disk usage"
  viz_section "Filesystems"
  printf '%s' "$table" | viz_table

  viz_section "Alerts"
  local alert
  for alert in "${alerts[@]}"; do
    report_alert "${alert%%|*}" "${alert#*|}"     # level before the "|", text after
  done
  (( ${#alerts[@]} == 0 )) && viz_badge ok "All disks are below ${OSBUDDY_WARN_PCT}%"

  [[ -n "$path" ]] && disk_top "$path"
  return "$REPORT_STATUS"
}

# The 10 biggest files and folders directly inside a folder.
disk_top() {
  local dir="$1" total kb item rows
  viz_section "Biggest items in $dir"

  # du -sk: size in KB of each item. Errors (no permission) are hidden.
  rows="$(du -sk "$dir"/* "$dir"/.[!.]* 2> /dev/null | sort -rn | head -n 10)"
  if [[ -z "$rows" ]]; then
    viz_badge info "nothing to show (empty folder, or no permission)"
    return 0
  fi
  total="$(du -sk "$dir" 2> /dev/null | awk '{ print $1 }')"
  (( ${total:-0} > 0 )) || total=1

  {
    printf 'Size\tShare\tItem\n'
    while IFS=$'\t' read -r kb item; do
      printf '%s\t%s\t%s\n' "$(human_kb "$kb")" "$(viz_bar $(( kb * 100 / total )) 20)" "${item#"$dir"/}"
    done <<< "$rows"
  } | viz_table
}
