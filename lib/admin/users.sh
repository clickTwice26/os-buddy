# lib/admin/users.sh: "os-buddy users", user management.
#
# Linux keeps users in /etc/passwd (read with getent) and changes them
# with useradd/usermod/userdel. Alpine has the smaller busybox tools
# (adduser, deluser, passwd -l). macOS keeps users in a directory
# service, read with dscl and changed with sysadminctl and pwpolicy.
# Every change needs administrator rights, shows the exact command and
# asks first.

users_usage() {
  cat <<'EOF'
Usage: os-buddy users [ACTION NAME] [--admin] [--yes] [--dry-run]

  (nothing)       people accounts, administrators, who is logged in
  add NAME        create an account with a home folder (--admin: make it an admin)
  lock NAME       block logins for the account (files are kept)
  unlock NAME     allow logins again
  delete NAME     remove the account; the home folder is KEPT

Changes need sudo. root, your own account and system accounts are protected.
Exit code: 0 done, 1 error or refused, 2 usage error.
EOF
}

# ---- reading ----

# Smallest user id for real people (system accounts are below it).
users_uid_min() {
  if is_mac; then
    echo 500
  else
    awk '$1 == "UID_MIN" { print $2; found = 1 } END { if (!found) print 1000 }' /etc/login.defs 2> /dev/null ||
      echo 1000
  fi
}

# One line per account, tab-separated: name, uid, home, shell.
users_all() {
  local u uid
  if is_mac; then
    dscl . -list /Users UniqueID | while read -r u uid; do
      [[ "$u" == _* ]] && continue                  # "_name" = service account
      printf '%s\t%s\t%s\t%s\n' "$u" "$uid" \
        "$(dscl . -read "/Users/$u" NFSHomeDirectory 2> /dev/null | awk '{ print $2 }')" \
        "$(dscl . -read "/Users/$u" UserShell 2> /dev/null | awk '{ print $2 }')"
    done
  else
    { getent passwd 2> /dev/null || cat /etc/passwd; } |
      awk -F: -v OFS='\t' '{ print $1, $3, $6, $7 }'
  fi
}

# People accounts: root plus every uid from UID_MIN up (65534 is "nobody").
users_people() {
  users_all | awk -F'\t' -v min="$(users_uid_min)" '$2 == 0 || ($2 >= min && $2 < 65534)'
}

# Members of the administrator groups, one name per line.
users_admins() {
  local g
  if is_mac; then
    dscl . -read /Groups/admin GroupMembership 2> /dev/null | tr ' ' '\n' | sed 1d
  else
    for g in sudo wheel admin; do
      { getent group "$g" 2> /dev/null || grep "^$g:" /etc/group; } | cut -d: -f4 | tr ',' '\n'
    done
  fi | grep -v '^$' | sort -u
}

# Does an account exist?
users_exists() {
  id "$1" > /dev/null 2>&1
}

# Commands that change users need root: start them with "sudo",
# unless we are root already. Kept in an array so an empty value adds nothing.
users_set_sudo() {
  USERS_SUDO=()
  (( EUID == 0 )) || USERS_SUDO=(sudo)
}

# The admin group of this system: sudo (Debian, Ubuntu) or wheel (Fedora, Alpine).
users_admin_group() {
  if getent group sudo > /dev/null 2>&1 || grep -q '^sudo:' /etc/group 2> /dev/null; then
    echo sudo
  else
    echo wheel
  fi
}

users_overview() {
  local name uid home shell admins status rows=""
  admins="$(users_admins)"
  viz_title "Users"

  viz_section "Accounts for people"
  while IFS=$'\t' read -r name uid home shell; do
    status="active"
    [[ "$shell" == */nologin || "$shell" == */false ]] && status="no login"
    grep -qx "$name" <<< "$admins" && status="$status, ${VIZ_YELLOW}admin$VIZ_RESET"
    (( uid == 0 )) && status="${VIZ_YELLOW}superuser$VIZ_RESET"
    [[ "$name" == "$(id -un)" ]] && name="$name (you)"
    rows+="$name"$'\t'"$uid"$'\t'"$home"$'\t'"${shell:--}"$'\t'"$status"$'\n'
  done < <(users_people)
  printf 'User\tUID\tHome\tShell\tStatus\n%s' "$rows" | viz_table
  viz_kv "All accounts" "$(users_all | grep -c .) (including system accounts)"
  viz_kv "Administrators" "$(printf '%s' "$admins" | tr '\n' ' ')"

  viz_section "Logged in now"
  users_who_table

  if command -v last > /dev/null 2>&1; then
    viz_section "Recent logins"
    { last -n 5 2> /dev/null || last -5 2> /dev/null; } |
      grep -v -e '^$' -e 'begins' | head -n 5 | sed "s/^/  $VIZ_DIM/; s/\$/$VIZ_RESET/"
  fi
  return 0
}

# Table from "who": user, terminal, since, from.
users_who_table() {
  local rows
  rows="$(who 2> /dev/null | awk -v OFS='\t' '{
    from = "local"
    if (match($0, /\(.*\)/)) from = substr($0, RSTART + 1, RLENGTH - 2)
    since = $3 " " $4; if ($5 !~ /^\(/ && $5 != "") since = since " " $5
    print $1, $2, since, from
  }')"
  if [[ -z "$rows" ]]; then
    viz_badge info "nobody is logged in on a terminal"
    return 0
  fi
  # Some systems print a number instead of the name: turn it back into a name.
  rows="$(while IFS=$'\t' read -r u t s f; do
    [[ "$u" =~ ^[0-9]+$ ]] && u="$(id -nu "$u" 2> /dev/null || echo "$u")"
    printf '%s\t%s\t%s\t%s\n' "$u" "$t" "$s" "$f"
  done <<< "$rows")"
  printf 'User\tTerminal\tSince\tFrom\n%s\n' "$rows" | viz_table
}

# ---- changing ----

# Refuse names that are unsafe, and accounts that must not be touched.
#   $1 name   $2 "new" (must not exist) or "existing" (must exist, not protected)
users_check() {
  local name="$1" mode="$2" uid
  [[ -n "$name" ]] || { ui_error "a user NAME is needed"; return 2; }
  if [[ ! "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    ui_error "invalid name '$name': use lowercase letters, digits, - or _ (max 32), starting with a letter"
    return 2
  fi
  if [[ "$mode" == new ]]; then
    users_exists "$name" && { ui_error "user '$name' already exists"; return 1; }
    return 0
  fi
  users_exists "$name" || { ui_error "no user named '$name'"; return 1; }
  uid="$(id -u "$name")"
  (( uid == 0 )) && { ui_error "refusing to change root"; return 1; }
  [[ "$name" == "$(id -un)" ]] && { ui_error "refusing to change your own account while you use it"; return 1; }
  # Below UID_MIN are system accounts; 65534 and up are "nobody" and similar.
  if (( uid < $(users_uid_min) || uid >= 65534 )); then
    ui_error "refusing to change system account '$name' (uid $uid)"
    return 1
  fi
  return 0
}

users_add() {
  local name="$1" admin="$2"
  local -a cmd
  users_check "$name" new || return $?
  users_set_sudo
  viz_title "Add user $name"

  if is_mac; then
    cmd=("${USERS_SUDO[@]}" sysadminctl -addUser "$name" -fullName "$name" -password -)
    [[ "$admin" == 1 ]] && cmd+=(-admin)
    admin_exec "Create the account (you will type its password)" "${cmd[@]}" || return 1
  elif command -v useradd > /dev/null 2>&1; then
    admin_exec "Create the account with a home folder" "${USERS_SUDO[@]}" useradd -m -s /bin/bash "$name" || return 1
    if [[ "$admin" == 1 ]]; then
      admin_exec "Make it an administrator" "${USERS_SUDO[@]}" usermod -aG "$(users_admin_group)" "$name" || return 1
    fi
  else
    admin_exec "Create the account with a home folder" "${USERS_SUDO[@]}" adduser -D -s /bin/sh "$name" || return 1
    if [[ "$admin" == 1 ]]; then
      admin_exec "Make it an administrator" "${USERS_SUDO[@]}" addgroup "$name" "$(users_admin_group)" || return 1
    fi
  fi
  [[ "$ADMIN_DRY_RUN" == 1 ]] && return 0

  viz_badge ok "user $name created"
  if ! is_mac; then
    viz_badge info "the account has no password yet, so nobody can log in with one"
    if [[ "$ADMIN_YES" != 1 ]] && ui_is_interactive && ui_confirm "Set a password now?"; then
      "${USERS_SUDO[@]}" passwd "$name"
    else
      printf '  %sSet one later with: %s passwd %s%s\n' "$VIZ_DIM" "${USERS_SUDO[*]}" "$name" "$VIZ_RESET"
    fi
  fi
}

# Busybox "passwd -l" fails ("already locked") when the account is already
# locked (a new account has no password, so it starts locked). That is
# the state we want, so it counts as success.
users_busybox_passwd() {
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  [[ -n "$out" ]] && printf '    %s\n' "$out"
  # Busybox versions word it as "already locked", "unchanged" or "not locked".
  if (( rc != 0 )) && [[ "$out" == *already* || "$out" == *unchanged* || "$out" == *"not locked"* ]]; then
    viz_badge info "no change needed: the account was already in that state"
    return 0
  fi
  return "$rc"
}

users_lock() {
  local name="$1" action="$2" what title busybox=false
  local -a cmd
  users_check "$name" existing || return $?
  users_set_sudo
  if [[ "$action" == lock ]]; then what="Block logins" title="Lock"; else what="Allow logins" title="Unlock"; fi
  viz_title "$title user $name"

  # The same job has a different command on each system.
  if is_mac; then
    if [[ "$action" == lock ]]; then cmd=(pwpolicy -u "$name" disableuser); else cmd=(pwpolicy -u "$name" enableuser); fi
  elif command -v usermod > /dev/null 2>&1; then
    if [[ "$action" == lock ]]; then cmd=(usermod -L "$name"); else cmd=(usermod -U "$name"); fi
  else
    busybox=true
    if [[ "$action" == lock ]]; then cmd=(passwd -l "$name"); else cmd=(passwd -u "$name"); fi
  fi
  cmd=("${USERS_SUDO[@]}" "${cmd[@]}")

  if $busybox; then
    # Busybox passwd: run through a wrapper that accepts "already locked".
    ADMIN_SHOW="${cmd[*]}" admin_exec "$what" users_busybox_passwd "${cmd[@]}" || return 1
  else
    admin_exec "$what" "${cmd[@]}" || return 1
  fi
  [[ "$ADMIN_DRY_RUN" == 1 ]] && return 0

  viz_badge ok "user $name ${action}ed"
  if [[ "$action" == lock ]]; then
    printf '  %sNote: SSH keys can still work; remove ~%s/.ssh/authorized_keys to block them too.%s\n' \
      "$VIZ_DIM" "$name" "$VIZ_RESET"
  fi
  return 0
}

users_delete() {
  local name="$1" home
  local -a cmd
  users_check "$name" existing || return $?
  users_set_sudo
  home="$(users_all | awk -F'\t' -v n="$name" '$1 == n { print $3 }')"
  viz_title "Delete user $name"
  viz_kv "Home folder" "${home:--} (kept)"
  if who | awk '{ print $1 }' | grep -qx "$name"; then
    ui_error "$name is logged in right now; log them out first"
    return 1
  fi

  if is_mac; then
    cmd=(sysadminctl -deleteUser "$name" -keepHome)
  elif command -v userdel > /dev/null 2>&1; then
    cmd=(userdel "$name")                 # without -r, the home folder stays
  else
    cmd=(deluser "$name")                 # busybox: keeps the home folder too
  fi
  admin_exec "Delete the account, keep the home folder" "${USERS_SUDO[@]}" "${cmd[@]}" || return 1
  [[ "$ADMIN_DRY_RUN" == 1 ]] && return 0
  viz_badge ok "user $name deleted; files are still in ${home:-its home folder}"
}

admin_cmd_users() {
  local admin=0 arg
  local -a args=()
  for arg in "$@"; do
    if [[ "$arg" == --admin ]]; then admin=1; else args+=("$arg"); fi
  done
  set -- "${args[@]}"
  case "${1:-}" in
    "")        users_overview ;;
    add)       users_add "${2:-}" "$admin" ;;
    lock)      users_lock "${2:-}" lock ;;
    unlock)    users_lock "${2:-}" unlock ;;
    delete)    users_delete "${2:-}" ;;
    -h|--help) users_usage ;;
    *)         admin_usage_error "unknown users action: $1" users_usage ;;
  esac
}
