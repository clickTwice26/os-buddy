#!/usr/bin/env bash
# tests/test_backup.sh: "os-buddy backup" (backup automation).
# Uses a temp backup folder and a fake crontab, so nothing real changes.
source "$(dirname "$0")/helpers.sh"
export NO_COLOR=1 LC_ALL=C
export OSBUDDY_BACKUP_DIR="$TEST_TMP/backups" OSBUDDY_BACKUP_KEEP=2
export OSBUDDY_CRONTAB="$TEST_TMP/fakecron"
cat > "$OSBUDDY_CRONTAB" <<EOF
#!/usr/bin/env bash
f="$TEST_TMP/crontab.txt"
if [[ "\$1" == -l ]]; then [[ -f "\$f" ]] && cat "\$f" || exit 1; else cat > "\$f"; fi
EOF
chmod +x "$OSBUDDY_CRONTAB"

src="$TEST_TMP/my docs"
mkdir -p "$src/sub"
echo hello > "$src/a.txt"
echo world > "$src/sub/b.txt"

# No backups yet: warning exit code.
"$OSBUDDY" backup list > /dev/null; assert_eq 4 "$?" "empty list warns"

# Create.
out="$("$OSBUDDY" backup create "$src")"; rc=$?
assert_eq 0 "$rc" "create succeeds"
file="$(ls "$OSBUDDY_BACKUP_DIR"/my_docs-*.tar.gz)"
[[ -f "$file" && -f "$file.sha256" ]] && pass "archive and checksum written" || fail "archive and checksum written"
assert_contains "$(tar -tzf "$file")" "my docs/sub/b.txt" "archive holds the files"

# A second backup in the same second must not replace the first.
out="$("$OSBUDDY" backup create "$src" 2>&1)"
[[ "$out" == *"already made this second"* || "$(ls "$OSBUDDY_BACKUP_DIR"/*.tar.gz | wc -l)" -eq 2 ]] &&
  pass "never overwrites a backup" || fail "never overwrites a backup" "$out"

# Rotation: with exactly two older copies present, only the newest 2 are kept.
# (The folder is reset first, so the result does not depend on timing.)
cp "$file" "$TEST_TMP/saved.tar.gz"
rm -f "$OSBUDDY_BACKUP_DIR"/*
cp "$TEST_TMP/saved.tar.gz" "$OSBUDDY_BACKUP_DIR/my_docs-20200101-000000.tar.gz"
cp "$TEST_TMP/saved.tar.gz" "$OSBUDDY_BACKUP_DIR/my_docs-20210101-000000.tar.gz"
"$OSBUDDY" backup create "$src" > /dev/null
left="$(ls "$OSBUDDY_BACKUP_DIR"/my_docs-*.tar.gz | wc -l | tr -d ' ')"
assert_eq 2 "$left" "rotation keeps the newest 2"
[[ ! -e "$OSBUDDY_BACKUP_DIR/my_docs-20200101-000000.tar.gz" ]] && pass "oldest backup removed" || fail "oldest backup removed"

# List and verify.
out="$("$OSBUDDY" backup list)"
assert_contains "$out" "my_docs-" "list shows the archive"
file="$(ls "$OSBUDDY_BACKUP_DIR"/my_docs-2026*.tar.gz "$OSBUDDY_BACKUP_DIR"/my_docs-20[3-9]*.tar.gz 2> /dev/null | head -n 1)"
[[ -n "$file" ]] || file="$(ls "$OSBUDDY_BACKUP_DIR"/my_docs-*.tar.gz | tail -n 1)"
"$OSBUDDY" backup verify "$(basename "$file")" > /dev/null; assert_eq 0 "$?" "a good backup verifies"
printf 'junk' >> "$OSBUDDY_BACKUP_DIR/my_docs-20210101-000000.tar.gz"
out="$("$OSBUDDY" backup verify)"; rc=$?
assert_eq 5 "$rc" "a damaged backup is critical"
assert_contains "$out" "DAMAGED" "damage is shown"

# Restore: needs approval, only into a new or empty folder.
"$OSBUDDY" backup restore "$(basename "$file")" "$TEST_TMP/out" > /dev/null 2>&1
[[ ! -e "$TEST_TMP/out/my docs/a.txt" ]] && pass "restore without approval does nothing" || fail "restore without approval does nothing"
"$OSBUDDY" backup restore "$(basename "$file")" "$TEST_TMP/out" --yes > /dev/null
assert_eq "hello" "$(cat "$TEST_TMP/out/my docs/a.txt" 2> /dev/null)" "restore brings the files back"
out="$("$OSBUDDY" backup restore "$(basename "$file")" "$TEST_TMP/out" --yes 2>&1)"
assert_contains "$out" "not empty" "restore never overwrites"
out="$("$OSBUDDY" backup restore my_docs-20210101-000000.tar.gz "$TEST_TMP/out2" --yes 2>&1)"
assert_contains "$out" "damaged" "a damaged backup is not restored"

# Schedule with the fake crontab; other lines must stay.
echo "0 5 * * * echo keep-me" > "$TEST_TMP/crontab.txt"
"$OSBUDDY" backup schedule "$src" daily 03:15 --yes > /dev/null
cron="$(cat "$TEST_TMP/crontab.txt")"
assert_contains "$cron" "keep-me" "existing cron lines are kept"
assert_contains "$cron" "15 3 * * *" "daily at 03:15"
assert_contains "$cron" "backup create" "the line runs a backup"
assert_contains "$("$OSBUDDY" backup list)" "daily at 03:15" "list shows the schedule in words"
out="$("$OSBUDDY" backup schedule "$src" weekly --yes 2>&1)"
assert_contains "$out" "already scheduled" "no duplicate schedules"
out="$("$OSBUDDY" backup schedule "$src" daily 25:00 --yes 2>&1)"
assert_contains "$out" "HH:MM" "bad time is refused"
"$OSBUDDY" backup unschedule "$src" --yes > /dev/null
assert_eq "0 5 * * * echo keep-me" "$(cat "$TEST_TMP/crontab.txt")" "unschedule removes only our line"

finish
