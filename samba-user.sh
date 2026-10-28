#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 — see LICENSE and NOTICE.
# Derived from FollowTheWizard/install-ubuntu-server-2604-zfs-luks-tpm (samba-user.sh);
# modified (Apache-2.0 §4b). NOT tested against a real Samba installation.
# Changes vs. the original:
#  1. samba_user_exists: fixed-string match (grep -F). The old regex treated the trailing
#     "$" of machine-account names as an end anchor ("foo$" matched user "foo", and an
#     existing "bar$" was not found). Also no `grep -q` inside a pipe under pipefail
#     (SIGPIPE -> false "not found").
#  2. add: if the Samba user already exists, the password is no longer silently reset
#     (smbpasswd -a on an existing user overwrites it); group membership is still ensured.
#  3. add: `read` at EOF / non-interactive stdin no longer aborts silently under set -e.
#  4. require_cmd: says which package provides smbpasswd/pdbedit; does not hard-require
#     `adduser` (absent on minimal Ubuntu installs — falls back to `useradd` + `passwd`).
#  5. validate_user: enforces POSIX 32-char username length limit.
#  6. list_users / samba_user_exists: captures `pdbedit` output before filtering so real
#     `pdbedit` errors are not masked by `|| true` under `pipefail`, and prints `(none)`
#     when no Samba users exist.
#  7. enable_user: verifies the underlying Linux account exists and ensures `sambashare`
#     group membership.
set -Eeuo pipefail

###############################################################################
# Samba user management
#
# Usage:
#   sudo ./samba-user.sh add username
#   sudo ./samba-user.sh remove username
#   sudo ./samba-user.sh passwd username
#   sudo ./samba-user.sh disable username
#   sudo ./samba-user.sh enable username
#   sudo ./samba-user.sh list
###############################################################################

[[ $EUID -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}

usage() {
    cat >&2 <<EOF

Usage:

  $0 add USER
  $0 remove USER
  $0 passwd USER
  $0 disable USER
  $0 enable USER
  $0 list

EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

ACTION="$1"

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || {
            echo "Required command not found: $c" >&2
            case "$c" in
                smbpasswd|pdbedit) echo "Install Samba first:  apt install samba" >&2 ;;
            esac
            exit 1
        }
    done
}

samba_user_exists() {
    local user="$1" pd_out users
    # Capture first: `pdbedit | ... | grep -q` under pipefail can return 141 (SIGPIPE)
    # when grep exits early. -F: names may end in "$", which is a regex anchor.
    pd_out=$(pdbedit -L) || {
        echo "Failed to query Samba user database (pdbedit -L)." >&2
        exit 1
    }
    users=$(cut -d: -f1 <<< "$pd_out")
    grep -qxF -- "$user" <<< "$users"
}

###############################################################################
# Validate username
###############################################################################

validate_user() {
    local user="$1"

    if [[ -z "$user" ]] || (( ${#user} > 32 )) || [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        echo "Invalid username: $user" >&2
        exit 1
    fi
}

###############################################################################
# Add
###############################################################################

add_user() {

    local user="$1"

    validate_user "$user"

    if ! id "$user" >/dev/null 2>&1; then
        echo "Linux user '$user' does not exist."
        echo
        read -r -p "Create Linux user '$user'? [y/N]: " answer || answer=""

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            if command -v adduser >/dev/null 2>&1; then
                adduser "$user"
            else
                require_cmd useradd passwd
                useradd -m -s /bin/bash "$user"
                passwd "$user"
            fi
        else
            echo "Cancelled." >&2
            exit 1
        fi
    fi

    if ! getent group sambashare >/dev/null; then
        groupadd -f sambashare
    fi

    usermod -aG sambashare "$user"

    if samba_user_exists "$user"; then
        echo
        echo "'$user' is already a Samba user - password and account state unchanged."
        echo "Use '$0 passwd $user' to change the password, '$0 enable $user' to re-enable."
        return 0
    fi

    echo
    echo "Adding Samba password for '$user'."
    smbpasswd -a "$user"

    smbpasswd -e "$user"

    echo
    echo "Samba user created:"
    echo "  $user"
}

###############################################################################
# Remove
###############################################################################

remove_user() {

    local user="$1"

    validate_user "$user"

    if samba_user_exists "$user"; then
        smbpasswd -x "$user"
    else
        echo "User '$user' is not a Samba user."
    fi

    if id "$user" >/dev/null 2>&1 && getent group sambashare >/dev/null 2>&1; then
        if id -nG "$user" | tr ' ' '\n' | grep -qxF "sambashare"; then
            gpasswd -d "$user" sambashare >/dev/null
        fi
    fi

    echo
    echo "Samba access removed for '$user'."
    echo "The Linux account itself was NOT deleted."
}

###############################################################################
# Password
###############################################################################

change_password() {

    local user="$1"

    validate_user "$user"

    id "$user" >/dev/null 2>&1 ||
        { echo "Linux user '$user' does not exist." >&2; exit 1; }

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist. Use: $0 add $user" >&2; exit 1; }

    smbpasswd "$user"
}

###############################################################################
# Disable
###############################################################################

disable_user() {

    local user="$1"

    validate_user "$user"

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist." >&2; exit 1; }

    smbpasswd -d "$user"
}

###############################################################################
# Enable
###############################################################################

enable_user() {

    local user="$1"

    validate_user "$user"

    id "$user" >/dev/null 2>&1 ||
        { echo "Linux user '$user' does not exist." >&2; exit 1; }

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist. Use: $0 add $user" >&2; exit 1; }

    if ! getent group sambashare >/dev/null; then
        groupadd -f sambashare
    fi
    usermod -aG sambashare "$user"

    smbpasswd -e "$user"
}

###############################################################################
# List
###############################################################################

list_users() {
    local pd_out filtered

    echo
    echo "Samba users:"
    echo

    pd_out=$(pdbedit -L -v)
    filtered=$(grep -E 'Unix username|Account Flags' <<< "$pd_out" || true)
    if [[ -n "$filtered" ]]; then
        printf '%s\n' "$filtered"
    else
        echo "  (none)"
    fi
}

###############################################################################
# Main
###############################################################################

case "$ACTION" in

    add)
        [[ $# -eq 2 ]] || usage
        require_cmd id getent groupadd usermod smbpasswd pdbedit cut grep
        add_user "$2"
        ;;

    remove)
        [[ $# -eq 2 ]] || usage
        require_cmd id getent gpasswd smbpasswd pdbedit cut grep tr
        remove_user "$2"
        ;;

    passwd)
        [[ $# -eq 2 ]] || usage
        require_cmd id smbpasswd pdbedit cut grep
        change_password "$2"
        ;;

    disable)
        [[ $# -eq 2 ]] || usage
        require_cmd smbpasswd pdbedit cut grep
        disable_user "$2"
        ;;

    enable)
        [[ $# -eq 2 ]] || usage
        require_cmd id getent groupadd usermod smbpasswd pdbedit cut grep
        enable_user "$2"
        ;;

    list)
        [[ $# -eq 1 ]] || usage
        require_cmd pdbedit grep
        list_users
        ;;

    *)
        usage
        ;;

esac
