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
allow|lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
allow|df -hT -x squashfs 2>/dev/null
allow|ls -la > /dev/null 2>&1
allow|ls && df -h
allow|uptime; free -h
allow|smartctl -H /dev/nvme0n1 2>/dev/null || cat /sys/class/nvme/nvme0/model
allow|grep -E '/dev/nvme|/dev/sd' /proc/mounts
allow|grep "a;b" notes.txt
allow|systemctl status ssh
allow|ip addr
allow|top -b -n 1 | head -n 15
allow|sysctl -n vm.loadavg
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
ask|sudo -n smartctl -H /dev/nvme0n1
ask|ip addr add 10.0.0.1/24 dev eth0
ask|systemctl restart ssh
ask|smartctl -t short /dev/sda
ask|sysctl -w vm.swappiness=10
ask|sysctl vm.swappiness=10
ask|top
ask|echo "$(rm x)"
ask|echo 'a' > f
ask|ls & rm x
ask|ls > /dev/null; rm y
ask|ls 2>/dev/nullx
ask|echo "a'" ; rm x ; echo "'b"
ask|grep 'x' file > out.txt
ask|journalctl --vacuum-size=10M
ask|git branch -D main
ask|git remote add x https://example.com
ask|tree -o out.txt
ask|ss -K dst 1.2.3.4
ask|hostname newname
allow|hostname -I
allow|swapon --show
ask|swapon -a
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

# Quotes are hidden before splitting, so a | inside them is not a pipe.
assert_eq "grep -E Q f" "$(policy_mask_quotes "grep -E 'a|b' f")" "single quotes masked"
assert_eq 'echo "$(id)"' "$(policy_mask_quotes 'echo "$(id)"')" "quotes with \$( ) stay visible"

# "always allow" is offered only for plain commands that are safe to repeat.
policy_can_always "apt install htop"  && pass "always: apt"        || fail "always: apt"
policy_can_always "sudo apt install x" && fail "always: not sudo"  || pass "always: not sudo"
policy_can_always "rm old.log"        && fail "always: not rm"     || pass "always: not rm"
policy_can_always "mkdir a && cd a"   && fail "always: not chains" || pass "always: not chains"
assert_eq apt "$(policy_program "sudo -n apt install x")" "program behind sudo"

assert_contains "$(policy_explain "sudo apt update")" "administrator" "explain sudo"
assert_contains "$(policy_explain "echo hi > f")" "redirects" "explain redirect"
assert_contains "$(policy_explain "cat .env")" "private" "explain sensitive"

finish
