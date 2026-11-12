# lib/admin_disk.sh: "os-buddy disk", the disk monitoring report.
# Loaded with "source". Never run directly.
#
#   os-buddy disk          usage of every real disk, with alerts
#   os-buddy disk PATH     the same, plus the biggest items inside PATH

admin_disk_usage() {
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
admin_disk_list() {
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
  local path="" mount dev size used free pct level status=$ADMIN_OK
  local -a alerts=()

  case "${1:-}" in
    -h|--help) admin_disk_usage; return 0 ;;
    -*)        ui_error "unknown option: $1"; admin_disk_usage >&2; return 2 ;;
    "")        ;;
    *)         path="$1"
               [[ -d "$path" ]] || { ui_error "not a folder: $path"; return 1; } ;;
  esac

  viz_title "Disk usage"
  viz_section "Filesystems"

  # Build the table: a header line, then one line per disk.
  {
    printf 'Mount\tDevice\tSize\tUsed\tFree\tUse\tStatus\n'
    while IFS=$'\t' read -r mount dev size used free pct; do
      level="$(viz_level "$pct")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mount" "$dev" \
        "$(admin_human_kb "$size")" "$(admin_human_kb "$used")" \
        "$(admin_human_kb "$free")" "$(viz_bar "$pct" 20)" \
        "$(viz_level_color "$pct")${level^^}$VIZ_RESET"
    done < <(admin_disk_list)
  } | viz_table

  # Second pass for the alerts. The table above ran in a pipe (a subshell),
  # so variables set there are lost. That is why we read the list again.
  while IFS=$'\t' read -r mount dev size used free pct; do
    level="$(viz_level "$pct")"
    case "$level" in
      crit) alerts+=("crit|$mount is $pct% full, only $(admin_human_kb "$free") left")
            status="$(admin_worse "$status" $ADMIN_CRIT)" ;;
      warn) alerts+=("warn|$mount is $pct% full")
            status="$(admin_worse "$status" $ADMIN_WARN)" ;;
    esac
  done < <(admin_disk_list)

  viz_section "Alerts"
  if (( ${#alerts[@]} == 0 )); then
    viz_badge ok "All disks are below ${OSBUDDY_WARN_PCT}%"
  else
    local a
    for a in "${alerts[@]}"; do
      viz_badge "${a%%|*}" "${a#*|}"     # text before / after the "|"
    done
  fi

  [[ -n "$path" ]] && admin_disk_top "$path"
  return "$status"
}

# The 10 biggest files and folders directly inside a folder.
admin_disk_top() {
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
      printf '%s\t%s\t%s\n' "$(admin_human_kb "$kb")" \
        "$(viz_bar $(( kb * 100 / total )) 20)" "${item#"$dir"/}"
    done <<< "$rows"
  } | viz_table
}
