#!/usr/bin/env bash
# tests/test_policy.sh: the safety table. Each line: expected|command.
# Includes bypass attempts that hide a dangerous command behind a safe one.
source "$(dirname "$0")/helpers.sh"
load_libs

while IFS='|' read -r expected cmd; do
  [[ -z "$expected" || "$expected" == \#* ]] && continue
  assert_eq "$expected" "$(policy_check_command "$cmd")" "$expected: $cmd"
done <<'EOF'
# read-only commands run automatically
allow|ls -la
allow|df -h
allow|du -sh .
allow|ps aux | grep bash | head -n 5
allow|find . -name '*.log'
allow|git status
allow|git log --oneline
allow|cat README.md
# changes need a yes
ask|rm file.txt
ask|rm -rf ./build
ask|mkdir new
ask|cat x > y
ask|echo hi >> notes.txt
ask|find . -delete
ask|find . -name x -exec rm {} \;
ask|sort -o out.txt in.txt
ask|git push
ask|git commit -m x
ask|sudo apt update
ask|ls $(rm x)
ask|ls `rm x`
ask|ls && touch y
ask|ls || touch y
ask|cat ~/.ssh/id_rsa
ask|cat .env
ask|date -s 2020-01-01
# always blocked, even with --yes
block|rm -rf /
block|rm -rf /*
block|rm -rf ~
block|rm -rf $HOME
block|rm -fr /etc
block|sudo rm -rf --no-preserve-root /
block|ls; rm -rf /
block|ls && rm -rf ~/
block|mkfs.ext4 /dev/sda1
block|dd if=/dev/zero of=/dev/sda
block|echo x > /dev/sda
block|:(){ :|:& };:
block|chmod -R 777 /
block|sudo chown -R me /
EOF

assert_eq ask   "$(policy_check_read "$HOME/.ssh/id_rsa")" "reading ~/.ssh asks"
assert_eq allow "$(policy_check_read "README.md")"         "reading a normal file is allowed"

finish
