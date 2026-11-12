# lib/admin_health.sh: "os-buddy health", the system health report.
# Loaded with "source". Never run directly.
#
# Linux and macOS keep these numbers in different places:
#   Linux: files under /proc (uptime, loadavg, meminfo, stat)
#   macOS: the sysctl and vm_stat commands
# Each health_* function hides that difference and prints plain numbers.
# The parse_* functions read text on stdin, so tests can feed them
# sample macOS output even on a Linux machine.

admin_health_usage() {
  cat <<'EOF'
Usage: os-buddy health

Shows uptime, CPU usage, load, memory, swap and the fullest disk,
each with a coloured bar, then one overall verdict.

Exit code: 0 healthy, 4 warning, 5 critical, 1 error.
Levels: OSBUDDY_WARN_PCT (default 70) and OSBUDDY_CRIT_PCT (default 90).
EOF
}

# ---- collecting numbers (one function per fact) ----

# Operating system name, e.g. "Ubuntu 26.04.1 LTS" or "macOS 15.1".
health_os() {
  if [[ -r /etc/os-release ]]; then
    awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' /etc/os-release
  elif command -v sw_vers > /dev/null 2>&1; then
    printf '%s %s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)"
  else
    uname -s
  fi
}

# Number of CPU cores. getconf works on both Linux and macOS.
health_cores() {
  local n
  n="$(getconf _NPROCESSORS_ONLN 2> /dev/null || sysctl -n hw.ncpu 2> /dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  printf '%s\n' "$n"
}

# Seconds since the machine started.
health_uptime_seconds() {
  local boot
  if [[ -r /proc/uptime ]]; then
    awk '{ printf "%d\n", $1 }' /proc/uptime
  else
    boot="$(sysctl -n kern.boottime 2> /dev/null | parse_boottime)"
    [[ "$boot" =~ ^[0-9]+$ ]] && printf '%s\n' $(( $(date +%s) - boot ))
  fi
}

# Load average for 1, 5 and 15 minutes: "0.64 0.65 0.69".
health_load() {
  if [[ -r /proc/loadavg ]]; then
    awk '{ print $1, $2, $3 }' /proc/loadavg
  else
    sysctl -n vm.loadavg 2> /dev/null | tr -d '{}' | awk '{ print $1, $2, $3 }'
  fi
}

# CPU busy percent (0-100), measured over half a second.
health_cpu_pct() {
  local a b
  if [[ -r /proc/stat ]]; then
    # The "cpu" line counts time spent in each state since boot.
    # Two readings 0.5 s apart show how busy the CPU was in between.
    a="$(head -n 1 /proc/stat)"
    sleep 0.5
    b="$(head -n 1 /proc/stat)"
    printf '%s\n%s\n' "$a" "$b" | parse_proc_stat
  else
    # macOS has no /proc: add up the CPU % of every process instead.
    ps -A -o %cpu= | awk -v cores="$(health_cores)" '
      { sum += $1 }
      END { p = sum / cores; if (p > 100) p = 100; printf "%d\n", p }'
  fi
}

# Memory in KB: "total used swap_total swap_used".
health_memory() {
  local total
  if [[ -r /proc/meminfo ]]; then
    parse_meminfo < /proc/meminfo
  else
    total=$(( $(sysctl -n hw.memsize) / 1024 ))
    printf '%s %s %s\n' "$total" \
      "$(vm_stat | parse_vm_stat)" \
      "$(sysctl -n vm.swapusage | parse_swapusage)"
  fi
}

# ---- parsing (text on stdin, numbers on stdout) ----

# Linux /proc/meminfo -> "total used swap_total swap_used" (KB).
# "Available" counts memory the system can free at once (caches),
# so used = total - available is what a human means by "used".
parse_meminfo() {
  awk '
    $1 == "MemTotal:"     { total = $2 }
    $1 == "MemAvailable:" { avail = $2 }
    $1 == "MemFree:"      { free = $2 }
    $1 == "Buffers:"      { buf = $2 }
    $1 == "Cached:"       { cached = $2 }
    $1 == "SwapTotal:"    { st = $2 }
    $1 == "SwapFree:"     { sf = $2 }
    END {
      if (avail == "") avail = free + buf + cached   # very old kernels
      printf "%d %d %d %d\n", total, total - avail, st, st - sf
    }'
}

# Two "cpu ..." lines from /proc/stat -> busy percent.
# Columns: user nice system idle iowait irq softirq steal.
parse_proc_stat() {
  awk '
    {
      idle = $5 + $6; total = 0
      for (i = 2; i <= 9; i++) total += $i
      if (NR == 1) { idle1 = idle; total1 = total }
      else         { idle2 = idle; total2 = total }
    }
    END {
      dt = total2 - total1
      if (dt <= 0) { print 0; exit }
      printf "%d\n", (dt - (idle2 - idle1)) * 100 / dt + 0.5
    }'
}

# macOS "sysctl -n kern.boottime" -> boot time in seconds.
# Input looks like: { sec = 1731400000, usec = 0 } Tue Nov 12 ...
parse_boottime() {
  sed -E 's/^[^0-9]*([0-9]+).*/\1/'
}

# macOS vm_stat -> used memory in KB (active + wired + compressed pages).
parse_vm_stat() {
  awk '
    /page size of/                  { size = $8 }
    /^Pages active:/                { act = $3 }
    /^Pages wired down:/            { wired = $4 }
    /^Pages occupied by compressor:/ { comp = $5 }
    END {
      if (size == "") size = 4096
      gsub(/\./, "", act); gsub(/\./, "", wired); gsub(/\./, "", comp)
      printf "%d\n", (act + wired + comp) * size / 1024
    }'
}

# macOS "sysctl -n vm.swapusage" -> "swap_total swap_used" in KB.
# Input looks like: total = 2048.00M  used = 512.25M  free = 1535.75M
parse_swapusage() {
  awk '
    function kb(v) {
      if (v ~ /G$/) return v * 1024 * 1024
      if (v ~ /M$/) return v * 1024
      if (v ~ /K$/) return v + 0
      return v / 1024
    }
    { printf "%d %d\n", kb($3), kb($6) }'
}

# ---- helpers for the report ----

# 93784 seconds -> "1 day, 2 h 3 min"
health_format_uptime() {
  local s="${1:-0}" d h m out=""
  d=$(( s / 86400 )) h=$(( s % 86400 / 3600 )) m=$(( s % 3600 / 60 ))
  (( d == 1 )) && out="1 day, "
  (( d > 1 )) && out="$d days, "
  printf '%s%d h %d min\n' "$out" "$h" "$m"
}

# Percent of A in B, as a whole number: health_pct 5 20 -> 25
health_pct() {
  if (( $2 > 0 )); then printf '%d\n' $(( $1 * 100 / $2 )); else printf '0\n'; fi
}

# ---- the report ----

admin_cmd_health() {
  case "${1:-}" in
    -h|--help) admin_health_usage; return 0 ;;
    "")        ;;
    *)         ui_error "unknown argument: $1"; admin_health_usage >&2; return 2 ;;
  esac

  local cores load l1 l5 l15 load_pct cpu mem total used st su
  local mem_pct swap_pct disk mount dsize dused dpct name level row pct detail i
  local status=$ADMIN_OK
  local -a rows=() issues=()

  # 1. Collect every number first, then draw. This keeps the drawing simple.
  cores="$(health_cores)"
  load="$(health_load)"
  read -r l1 l5 l15 <<< "${load:-0 0 0}"
  load_pct="$(awk -v l="$l1" -v c="$cores" 'BEGIN { printf "%d", l * 100 / c + 0.5 }')"
  cpu="$(health_cpu_pct)"
  mem="$(health_memory)"
  read -r total used st su <<< "${mem:-0 0 0 0}"
  mem_pct="$(health_pct "$used" "$total")"
  swap_pct="$(health_pct "$su" "$st")"

  # The fullest real disk (from the disk report's list).
  disk="$(admin_disk_list | sort -t $'\t' -k6,6n | tail -n 1)"
  IFS=$'\t' read -r mount _ dsize dused _ dpct <<< "${disk:-/	-	0	0	0	0}"

  viz_title "System health"

  viz_section "System"
  viz_kv "Host" "$(uname -n)"
  viz_kv "OS" "$(health_os)"
  viz_kv "Kernel" "$(uname -sr) ($(uname -m))"
  viz_kv "Uptime" "$(health_format_uptime "$(health_uptime_seconds)")"
  viz_kv "CPU cores" "$cores"

  # 2. One table row per resource: name, bar, detail, percent.
  #    Fields are split by "|" here, and turned into table cells below.
  rows+=("CPU usage|$cpu|measured over 0.5 s")
  rows+=("Load (1 min)|$load_pct|$l1 / $l5 / $l15 on $cores cores")
  rows+=("Memory|$mem_pct|$(admin_human_kb "$used") of $(admin_human_kb "$total")")
  if (( st > 0 )); then
    rows+=("Swap|$swap_pct|$(admin_human_kb "$su") of $(admin_human_kb "$st")")
  fi
  rows+=("Disk $mount|${dpct:-0}|$(admin_human_kb "$dused") of $(admin_human_kb "$dsize")")

  viz_section "Resources"
  {
    printf 'Resource\tUsage\tDetail\tStatus\n'
    for row in "${rows[@]}"; do
      IFS='|' read -r name pct detail <<< "$row"
      level="$(viz_level "$pct")"
      printf '%s\t%s\t%s\t%s\n' "$name" "$(viz_bar "$pct" 20)" "$detail" \
        "$(viz_level_color "$pct")${level^^}$VIZ_RESET"
    done
  } | viz_table

  # 3. The verdict: every warning or critical item, then one overall line.
  for row in "${rows[@]}"; do
    IFS='|' read -r name pct detail <<< "$row"
    level="$(viz_level "$pct")"
    case "$level" in
      crit) issues+=("crit|$name is at $pct% ($detail)")
            status="$(admin_worse "$status" "$ADMIN_CRIT")" ;;
      warn) issues+=("warn|$name is at $pct% ($detail)")
            status="$(admin_worse "$status" "$ADMIN_WARN")" ;;
    esac
  done

  viz_section "Verdict"
  for i in "${issues[@]}"; do
    viz_badge "${i%%|*}" "${i#*|}"
  done
  case "$status" in
    "$ADMIN_OK")   viz_badge ok   "System is healthy" ;;
    "$ADMIN_WARN") viz_badge warn "System needs attention soon" ;;
    *)             viz_badge crit "System needs attention now" ;;
  esac
  return "$status"
}
