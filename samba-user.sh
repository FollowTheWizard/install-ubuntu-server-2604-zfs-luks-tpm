#!/usr/bin/env bash
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
    echo "Run as root."
    exit 1
}

usage() {
    cat <<EOF

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
            echo "Required command not found: $c"
            exit 1
        }
    done
}

samba_user_exists() {
    local user="$1"
    pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$user"
}

###############################################################################
# Validate username
###############################################################################

validate_user() {
    local user="$1"

    [[ "$user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || {
        echo "Invalid username: $user"
        exit 1
    }
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
        read -r -p "Create Linux user '$user'? [y/N]: " answer

        if [[ "$answer" =~ ^[Yy]$ ]]; then
            adduser "$user"
        else
            echo "Cancelled."
            exit 1
        fi
    fi

    if ! getent group sambashare >/dev/null; then
        groupadd -f sambashare
    fi

    usermod -aG sambashare "$user"

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

    if id "$user" >/dev/null 2>&1; then
        gpasswd -d "$user" sambashare >/dev/null 2>&1 || true
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
        { echo "Linux user '$user' does not exist."; exit 1; }

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist. Use: $0 add $user"; exit 1; }

    smbpasswd "$user"
}

###############################################################################
# Disable
###############################################################################

disable_user() {

    local user="$1"

    validate_user "$user"

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist."; exit 1; }

    smbpasswd -d "$user"
}

###############################################################################
# Enable
###############################################################################

enable_user() {

    local user="$1"

    validate_user "$user"

    samba_user_exists "$user" ||
        { echo "Samba user '$user' does not exist."; exit 1; }

    smbpasswd -e "$user"
}

###############################################################################
# List
###############################################################################

list_users() {

    echo
    echo "Samba users:"
    echo

    pdbedit -L -v |
        grep -E 'Unix username|Account Flags' ||
        true
}

###############################################################################
# Main
###############################################################################

case "$ACTION" in

    add)
        [[ $# -eq 2 ]] || usage
        require_cmd id getent adduser groupadd usermod smbpasswd pdbedit
        add_user "$2"
        ;;

    remove)
        [[ $# -eq 2 ]] || usage
        require_cmd id gpasswd smbpasswd pdbedit
        remove_user "$2"
        ;;

    passwd)
        [[ $# -eq 2 ]] || usage
        require_cmd id smbpasswd pdbedit
        change_password "$2"
        ;;

    disable)
        [[ $# -eq 2 ]] || usage
        require_cmd smbpasswd pdbedit
        disable_user "$2"
        ;;

    enable)
        [[ $# -eq 2 ]] || usage
        require_cmd smbpasswd pdbedit
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
