# lib/admin_backup.sh: "os-buddy backup", backup automation.
# Loaded with "source". Never run directly.
#
# A backup is one compressed archive (NAME-YYYYmmdd-HHMMSS.tar.gz) plus a
# checksum file (.sha256) in the backup folder. The checksum shows later
# whether the archive was damaged. Old backups are removed automatically,
# keeping the newest OSBUDDY_BACKUP_KEEP of each name.

: "${OSBUDDY_BACKUP_DIR:=$HOME/os-buddy-backups}"
: "${OSBUDDY_BACKUP_KEEP:=7}"
: "${OSBUDDY_CRONTAB:=crontab}"          # the tests swap in a fake crontab
BACKUP_CRON_MARK="# os-buddy-backup"

admin_backup_usage() {
  cat <<EOF
Usage: os-buddy backup ACTION ... [--yes] [--dry-run]

  create PATH               archive PATH into the backup folder
  list                      backups, sizes, ages and schedules
  verify [FILE]             check checksums and archives (all by default)
  restore FILE [DEST]       unpack into DEST (a new or empty folder)
  schedule PATH hourly|daily|weekly [HH:MM]   back up PATH with cron
  unschedule PATH           remove that schedule

Backup folder: $OSBUDDY_BACKUP_DIR   (OSBUDDY_BACKUP_DIR)
Keep per name: $OSBUDDY_BACKUP_KEEP newest   (OSBUDDY_BACKUP_KEEP)
Exit code: 0 fine, 4 no backups yet, 5 a damaged backup, 1 error, 2 usage error.
EOF
}

# ---- small helpers ----

# SHA-256 of a file: Linux has sha256sum, macOS has shasum.
backup_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# Absolute path of an existing file or folder (realpath is missing on old macOS).
backup_abs() {
  if [[ -d "$1" ]]; then
    (cd "$1" && pwd)
  else
    printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"
  fi
}

# A safe name for the archive: "/home/me/My Docs" -> My_Docs, "/" -> root
backup_name() {
  local base
  base="$(basename "$1")"
  [[ "$base" == / || -z "$base" ]] && base=root
  base="${base//[^A-Za-z0-9._-]/_}"
  printf '%s' "$base"
}

# Size of a file in KB (du works the same on Linux and macOS).
backup_kb() {
  du -k "$1" | awk '{ print $1 }'
}

# Last change time of a file, in seconds since 1970 (GNU stat or BSD stat).
backup_mtime() {
  stat -c %Y "$1" 2> /dev/null || stat -f %m "$1"
}

# Seconds since 1970 -> "2026-11-13 11:30" (BSD date -r, or GNU date -d @).
backup_date() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2> /dev/null || date -d "@$1" '+%Y-%m-%d %H:%M'
}

# All archives in the backup folder, oldest first (the date is in the name).
backup_files() {
  [[ -d "$OSBUDDY_BACKUP_DIR" ]] || return 0
  find "$OSBUDDY_BACKUP_DIR" -maxdepth 1 -type f -name '*-[0-9]*-[0-9]*.tar.gz' | sort
}

# ---- create ----

backup_create() {
  local src="$1" abs parent base name stamp file tmp rel start took kb count removed=0 old
  local -a exclude=()
  [[ -n "$src" ]] || { ui_error "backup create needs a PATH"; return 2; }
  [[ -e "$src" ]] || { ui_error "not found: $src"; return 1; }
  [[ -r "$src" ]] || { ui_error "cannot read: $src"; return 1; }

  abs="$(backup_abs "$src")"
  parent="$(dirname "$abs")" base="$(basename "$abs")"
  name="$(backup_name "$abs")"
  stamp="$(date '+%Y%m%d-%H%M%S')"
  file="$OSBUDDY_BACKUP_DIR/$name-$stamp.tar.gz"

  viz_title "Backup: $abs"
  if [[ "$ADMIN_DRY_RUN" == 1 ]]; then
    viz_kv "Would write" "$file"
    viz_badge info "dry run: nothing was changed"
    return 0
  fi
  mkdir -p "$OSBUDDY_BACKUP_DIR" || { ui_error "cannot create $OSBUDDY_BACKUP_DIR"; return 1; }
  # The name has the time to the second. Never replace an existing backup.
  if [[ -e "$file" ]]; then
    ui_error "a backup of $name was already made this second; try again in a moment"
    return 1
  fi

  # Never put the backup folder inside its own backup.
  case "$(backup_abs "$OSBUDDY_BACKUP_DIR")/" in
    "$abs"/*) rel="$(backup_abs "$OSBUDDY_BACKUP_DIR")"
              exclude=(--exclude="$base/${rel#"$abs"/}") ;;
  esac

  # Write to a temporary name, then rename: a crash never leaves a
  # half-written file that looks like a good backup.
  tmp="$file.partial"
  start=$SECONDS
  if [[ "$parent" == / && "$base" == / ]]; then
    ui_error "backing up / as a whole is not supported; choose a folder"
    return 1
  fi
  if ! tar -czf "$tmp" "${exclude[@]}" -C "$parent" "$base" 2> "$tmp.err"; then
    ui_error "tar failed: $(head -n 3 "$tmp.err")"
    rm -f "$tmp" "$tmp.err"
    return 1
  fi
  rm -f "$tmp.err"
  mv "$tmp" "$file"
  printf '%s  %s\n' "$(backup_sha256 "$file")" "$(basename "$file")" > "$file.sha256"
  took=$(( SECONDS - start ))
  kb="$(backup_kb "$file")"
  count="$(tar -tzf "$file" | grep -c .)"

  # Rotation: keep only the newest N archives with this name.
  # Names hold the date, so sorted order is oldest first; drop all but the last N.
  while IFS= read -r old; do
    [[ -n "$old" ]] || continue
    rm -f "$old" "$old.sha256" && removed=$(( removed + 1 ))
  done < <(backup_files | grep "/$name-[0-9]\{8\}-[0-9]\{6\}\.tar\.gz$" |
           awk -v k="$OSBUDDY_BACKUP_KEEP" '{ a[NR] = $0 } END { for (i = 1; i <= NR - k; i++) print a[i] }')

  viz_section "Result"
  {
    printf 'Archive\tSize\tEntries\tTook\n'
    printf '%s\t%s\t%s\t%ss\n' "$(basename "$file")" "$(admin_human_kb "$kb")" "$count" "$took"
  } | viz_table
  viz_badge ok "backup written and checksum saved"
  (( removed > 0 )) && viz_badge info "removed $removed old backup(s) of $name (keeping $OSBUDDY_BACKUP_KEEP)"
  return 0
}

# ---- list ----

backup_list() {
  local f now newest=0 m total=0 kb n=0 check
  viz_title "Backups"
  viz_kv "Folder" "$OSBUDDY_BACKUP_DIR"
  viz_kv "Keep" "$OSBUDDY_BACKUP_KEEP newest per name"

  viz_section "Archives"
  now="$(date +%s)"
  local rows=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    m="$(backup_mtime "$f")" kb="$(backup_kb "$f")"
    if [[ -f "$f.sha256" ]]; then check="saved"; else check="missing"; fi
    rows+="$(basename "$f")"$'\t'"$(backup_date "$m")"$'\t'"$(admin_human_age $(( now - m )))"
    rows+=$'\t'"$(admin_human_kb "$kb")"$'\t'"$check"$'\n'
    n=$(( n + 1 ))
  done < <(backup_files)
  if (( n > 0 )); then
    printf 'Archive\tCreated\tAge\tSize\tChecksum\n%s' "$rows" | viz_table
  else
    viz_badge info "the folder has no backups"
  fi

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    m="$(backup_mtime "$f")"; (( m > newest )) && newest=$m
    total=$(( total + $(backup_kb "$f") ))
  done < <(backup_files)

  viz_section "Schedules"
  backup_schedules_table

  viz_section "Status"
  if (( n == 0 )); then
    viz_badge warn "no backups yet. Try: os-buddy backup create ~/Documents"
    return "$ADMIN_WARN"
  fi
  viz_badge ok "$n backup(s), $(admin_human_kb "$total") in total, newest $(admin_human_age $(( now - newest ))) ago"
  return 0
}

# ---- verify ----

backup_verify() {
  local target="${1:-}" f saved real sum arch status=$ADMIN_OK
  local -a files=()
  if [[ -n "$target" ]]; then
    [[ -f "$target" ]] || target="$OSBUDDY_BACKUP_DIR/$target"
    [[ -f "$target" ]] || { ui_error "no such backup: $1"; return 1; }
    files=("$target")
  else
    while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(backup_files)
  fi

  viz_title "Verify backups"
  if (( ${#files[@]} == 0 )); then
    viz_badge warn "no backups to verify"
    return "$ADMIN_WARN"
  fi
  {
    printf 'Archive\tChecksum\tArchive readable\tStatus\n'
    for f in "${files[@]}"; do
      saved="$(awk '{ print $1 }' "$f.sha256" 2> /dev/null)"
      real="$(backup_sha256 "$f")"
      if [[ -z "$saved" ]]; then sum="missing"
      elif [[ "$saved" == "$real" ]]; then sum="match"
      else sum="DIFFERENT"; fi
      if tar -tzf "$f" > /dev/null 2>&1; then arch="yes"; else arch="NO"; fi
      if [[ "$sum" == DIFFERENT || "$arch" == NO ]]; then
        printf '%s\t%s\t%s\t%s\n' "$(basename "$f")" "$sum" "$arch" "${VIZ_RED}DAMAGED$VIZ_RESET"
      else
        printf '%s\t%s\t%s\t%s\n' "$(basename "$f")" "$sum" "$arch" "${VIZ_GREEN}OK$VIZ_RESET"
      fi
    done
  } | viz_table

  # Count damaged ones outside the pipe (variables set in a pipe are lost).
  for f in "${files[@]}"; do
    saved="$(awk '{ print $1 }' "$f.sha256" 2> /dev/null)"
    if { [[ -n "$saved" && "$saved" != "$(backup_sha256 "$f")" ]]; } || ! tar -tzf "$f" > /dev/null 2>&1; then
      viz_badge crit "$(basename "$f") is damaged: do not rely on it"
      status=$ADMIN_CRIT
    fi
  done
  (( status == ADMIN_OK )) && viz_badge ok "all ${#files[@]} backup(s) are intact"
  return "$status"
}

# ---- restore ----

backup_restore() {
  local file="${1:-}" dest="${2:-}"
  [[ -n "$file" ]] || { ui_error "backup restore needs a FILE (see: os-buddy backup list)"; return 2; }
  [[ -f "$file" ]] || file="$OSBUDDY_BACKUP_DIR/$file"
  [[ -f "$file" ]] || { ui_error "no such backup: $1"; return 1; }
  [[ -n "$dest" ]] || dest="./restore-$(date '+%Y%m%d-%H%M%S')"

  # Never unpack over existing files: the folder must be new or empty.
  if [[ -e "$dest" && ! -d "$dest" ]]; then ui_error "$dest exists and is not a folder"; return 1; fi
  if [[ -d "$dest" && -n "$(ls -A "$dest")" ]]; then
    ui_error "$dest is not empty; choose a new folder so nothing is overwritten"
    return 1
  fi

  viz_title "Restore $(basename "$file")"
  backup_verify "$file" > /dev/null || { ui_error "the backup is damaged; restore stopped"; return "$ADMIN_CRIT"; }
  viz_kv "Into" "$dest"
  if [[ "$ADMIN_DRY_RUN" != 1 ]]; then
    mkdir -p "$dest" || { ui_error "cannot create $dest"; return 1; }
  fi
  if ! admin_exec "Unpack $(basename "$file")" tar -xzf "$file" -C "$dest"; then
    rmdir "$dest" 2> /dev/null      # remove the folder again if it is still empty
    return 1
  fi
  [[ "$ADMIN_DRY_RUN" == 1 ]] && return 0
  viz_badge ok "restored into $dest"
}

# ---- schedule (cron) ----

# The cron line for a folder. The full path of this Bash is used, because
# cron has a short PATH (on macOS it would find the old Bash 3.2).
backup_cron_line() {
  local src="$1" when="$2" at="${3:-02:00}" hh mm expr bin
  [[ "$at" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { ui_error "time must be HH:MM, e.g. 02:30"; return 2; }
  hh="$((10#${BASH_REMATCH[1]}))" mm="$((10#${BASH_REMATCH[2]}))"
  case "$when" in
    hourly) expr="$mm * * * *" ;;
    daily)  expr="$mm $hh * * *" ;;
    weekly) expr="$mm $hh * * 0" ;;
    *)      ui_error "when must be hourly, daily or weekly"; return 2 ;;
  esac
  bin="${OSBUDDY_BIN:-$OSBUDDY_ROOT/bin/os-buddy}"
  # In crontab a % starts a new line, so it must be escaped.
  printf '%s %q %q backup create %q >> %q 2>&1 %s %q\n' "$expr" "$BASH" "$bin" "$src" \
    "$OSBUDDY_BACKUP_DIR/backup.log" "$BACKUP_CRON_MARK" "$src" | sed 's/%/\\%/g'
}

# Current crontab, or nothing when the user has none yet.
backup_crontab_read() {
  "$OSBUDDY_CRONTAB" -l 2> /dev/null || true
}

backup_schedule() {
  local src="$1" when="$2" at="${3:-}" abs line current
  [[ -n "$src" && -n "$when" ]] || { ui_error "usage: backup schedule PATH hourly|daily|weekly [HH:MM]"; return 2; }
  [[ -e "$src" ]] || { ui_error "not found: $src"; return 1; }
  command -v "$OSBUDDY_CRONTAB" > /dev/null 2>&1 || { ui_error "cron is not installed (no crontab command)"; return 1; }
  abs="$(backup_abs "$src")"
  line="$(backup_cron_line "$abs" "$when" "${at:-02:00}")" || return $?
  current="$(backup_crontab_read)"
  if grep -qF "$BACKUP_CRON_MARK $(printf '%q' "$abs")" <<< "$current"; then
    ui_error "$abs is already scheduled; run: os-buddy backup unschedule $(printf '%q' "$abs")"
    return 1
  fi

  viz_title "Schedule backup"
  viz_kv "Folder" "$abs"
  viz_kv "When" "$when${at:+ at $at}"
  viz_kv "Log" "$OSBUDDY_BACKUP_DIR/backup.log"
  printf '  %sThis line will be added to your crontab:%s\n    %s\n' "$VIZ_DIM" "$VIZ_RESET" "$line"
  [[ "$ADMIN_DRY_RUN" == 1 ]] && { viz_badge info "dry run: nothing was changed"; return 0; }
  admin_confirm "Add it?" || { viz_badge info "cancelled, nothing was changed"; return 1; }
  mkdir -p "$OSBUDDY_BACKUP_DIR"
  { [[ -n "$current" ]] && printf '%s\n' "$current"; printf '%s\n' "$line"; } | "$OSBUDDY_CRONTAB" - ||
    { ui_error "crontab refused the change"; return 1; }
  viz_badge ok "scheduled. Check later with: os-buddy backup list"
}

backup_unschedule() {
  local src="$1" abs current keep
  [[ -n "$src" ]] || { ui_error "usage: backup unschedule PATH"; return 2; }
  abs="$( [[ -e "$src" ]] && backup_abs "$src" || printf '%s' "$src" )"
  current="$(backup_crontab_read)"
  if ! grep -qF "$BACKUP_CRON_MARK $(printf '%q' "$abs")" <<< "$current"; then
    ui_error "no schedule found for $abs"
    return 1
  fi
  keep="$(grep -vF "$BACKUP_CRON_MARK $(printf '%q' "$abs")" <<< "$current")"
  viz_title "Remove backup schedule"
  viz_kv "Folder" "$abs"
  [[ "$ADMIN_DRY_RUN" == 1 ]] && { viz_badge info "dry run: nothing was changed"; return 0; }
  admin_confirm "Remove it?" || { viz_badge info "cancelled, nothing was changed"; return 1; }
  printf '%s\n' "$keep" | grep -v '^$' | "$OSBUDDY_CRONTAB" - || { ui_error "crontab refused the change"; return 1; }
  viz_badge ok "schedule removed (existing backups are kept)"
}

# Table of os-buddy lines in the crontab.
backup_schedules_table() {
  local lines
  lines="$(backup_crontab_read | grep -F "$BACKUP_CRON_MARK")"
  if [[ -z "$lines" ]]; then
    viz_badge info "no schedules. Try: os-buddy backup schedule ~/Documents daily"
    return 0
  fi
  {
    printf 'When\tFolder\n'
    printf '%s\n' "$lines" | awk -v mark="$BACKUP_CRON_MARK" '{
      # Cron time back to words: "15 3 * * *" -> daily at 03:15
      if ($2 == "*")      when = sprintf("hourly at :%02d", $1)
      else if ($5 == "0") when = sprintf("weekly (Sun) at %02d:%02d", $2, $1)
      else                when = sprintf("daily at %02d:%02d", $2, $1)
      i = index($0, mark); folder = substr($0, i + length(mark) + 1)
      gsub(/\\/, "", folder)
      print when "\t" folder
    }'
  } | viz_table
}

admin_cmd_backup() {
  case "${1:-}" in
    create)       backup_create "${2:-}" ;;
    list|"")      backup_list ;;
    verify)       backup_verify "${2:-}" ;;
    restore)      backup_restore "${2:-}" "${3:-}" ;;
    schedule)     backup_schedule "${2:-}" "${3:-}" "${4:-}" ;;
    unschedule)   backup_unschedule "${2:-}" ;;
    -h|--help)    admin_backup_usage ;;
    *)            ui_error "unknown backup action: $1"; admin_backup_usage >&2; return 2 ;;
  esac
}
