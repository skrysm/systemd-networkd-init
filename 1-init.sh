#!/usr/bin/env bash

# Exit immediately if any command exits with non-zero status
set -e
# Exit if an undefined variable is used
set -u
# Fail if any command in a pipeline fails (not just the last one)
set -o pipefail


###########################################################################################
#
# Global Variables
#
###########################################################################################

# For testing purposes, GIT_BRANCH can be overwritten via: export GIT_BRANCH=xxx
GIT_BRANCH="${GIT_BRANCH:-main}"
SCRIPT_URL="https://raw.githubusercontent.com/skrysm/systemd-networkd-init/${GIT_BRANCH}/2-switch.sh"

UNIT_NAME=switch-networking-to-networkd
LOG_FILE="/var/log/${UNIT_NAME}.log"

# NOTE: Calling this script via "curl ... | sudo bash" breaks the navigation in whiptail. So move the sudo
#   calls into this script. I'd prefer the "curl ... | sudo bash" but I couldn't find a way to make whiptails
#   work in this scenario.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: sudo is required when not running as root." >&2
    exit 1
  fi
fi


###########################################################################################
#
# Logging/Output
#
###########################################################################################

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly DIM='\033[2m'
readonly NC='\033[0m' # No Color

print_error() {
    echo -e "${RED}$*${NC}" >&2
}

print_warn() {
    echo -e "${YELLOW}$*${NC}" >&2
}

print_title() {
    echo -e "${CYAN}$*${NC}"
    echo
}


###########################################################################################
#
# Apt Functions
#
###########################################################################################

ensure_apt_is_updated() {
    # This file makes sure we only run "apt update" once (i.e. don't run it unnecessarily often).
    local apt_update_marker_file="/run/apt-update-marker"

    if [ ! -f "$apt_update_marker_file" ]; then
        print_title "Running 'apt update'..."
        ${SUDO} apt update
        echo
        ${SUDO} touch "$apt_update_marker_file"
    fi
}

install_package() {
    ensure_apt_is_updated

    print_title "Installing package '$1'..."
    ${SUDO} apt install -y --no-install-recommends "$1"
}

ensure_package() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_title "$2 is not installed. Installing it..."
        install_package "$2"
        echo
    fi
}

ensure_whiptail() {
    ensure_package whiptail whiptail
}

ensure_iw() {
    ensure_package iw iw
}


###########################################################################################
#
# Prompt Functions
#
# See also: https://en.wikibooks.org/wiki/Bash_Shell_Scripting/Whiptail
#
###########################################################################################

on_user_cancellation() {
    echo -e "\033[90mUser cancellation. Exiting.\033[0m" >&2
    echo
    exit 255
}

prompt_yes_no() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"

    whiptail --yesno "$message" $height 78 --title "$title"
    local result=$?

    case $result in
        0)
            return 0
            ;;
        1)
            return 1
            ;;
        255)
            on_user_cancellation
            ;;
        *)
            print_error "UNEXPECTED: whiptail returned unexpected exit code: $result"
            exit 1
        ;;
    esac
}

prompt_input() {
    local title="$1"
    local message
    message=$(printf '%s' "$2" | sed -z 's/^\n*//;s/\n*$//')
    local height="${3:-8}"

    whiptail --inputbox "$message" $height 78 --title "$title" 3>&1 1>&2 2>&3 || on_user_cancellation
}

prompt_password() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"

    whiptail --passwordbox "$message" $height 78 --title "$title" 3>&1 1>&2 2>&3 || on_user_cancellation
}


###########################################################################################
#
# System Functions
#
###########################################################################################

check_service_installed() {
    if systemctl cat "$1" &>/dev/null; then
        return 0  # Service is installed
    else
        return 1  # Service is not installed
    fi
}

check_for_ethernet_device() {
    if [ -d /sys/class/net ]; then
        for iface in /sys/class/net/*/; do
            iface_name=$(basename "$iface")
            if [[ "$iface_name" =~ ^(eth|en) ]]; then
                return 0
            fi
        done
    fi
    return 1
}

check_for_wifi_device() {
    if [ -d /sys/class/net ] && ls /sys/class/net/*/wireless >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

get_wifi_devices() {
    iw dev | awk '$1=="Interface"{print $2}'
}

###########################################################################################
#
# Main Script
#
###########################################################################################

#------------------------------------------------------------------------------------------
# Check preconditions
#------------------------------------------------------------------------------------------

# Check that systemd is available on the system.
if ! check_service_installed 'systemd-networkd'; then
    print_error "UNEXPECTED: systemd is not available" >&2
    exit 1
fi

# Make sure whiptail is installed
ensure_whiptail

# NOTE: This prompt is also a test ballon to check if whiptail is working (because on most systems the
#   user won't see any prompt - as they're only used for WiFi configuration).
if ! prompt_yes_no "Configure Network" "During network configuration any SSH connection may drop. Also the system will be rebooted at the end. Do you want to continue?"; then
    on_user_cancellation
fi


#------------------------------------------------------------------------------------------
# Do WiFi configuration (SSID, password)
#------------------------------------------------------------------------------------------

# Pre-declare variables so that bash doesn't complain about unbound variables in case of no WiFi.
WIFI_DEVICE=''
WIFI_SSID=''
WIFI_PASSWORD=''

print_title "Checking for WiFi devices..."
if check_for_wifi_device; then
    echo "WiFi device detected"

    if check_for_ethernet_device; then
        if prompt_yes_no "Configure WiFi" "Do you want to enable and configure the WiFi connection?"; then
            CONFIGURE_WIFI=0
        else
            CONFIGURE_WIFI=1
        fi
    else
        # Always configure WiFi if no ethernet is present (like on a Raspberry Pi Zero 2W)
        CONFIGURE_WIFI=0
    fi


    if [ "$CONFIGURE_WIFI" -eq 0 ]; then
        # Necessary for determining WiFi network device names
        ensure_iw

        WIFI_DEVICES=$(get_wifi_devices)
        if [ "$(printf '%s\n' "$WIFI_DEVICES" | wc -l)" -gt 1 ]; then
            mapfile -t wifi_array <<<"${WIFI_DEVICES}"

            menu_items=()
            for i in "${!wifi_array[@]}"; do
                iface="${wifi_array[$i]}"
                menu_items+=("$iface" "WiFi interface $((i+1))")
            done

            WIFI_DEVICE="$(
                whiptail --title "WiFi selection" \
                         --menu "Select WiFi interface:" \
                         25 78 16 \
                         "${menu_items[@]}" \
                         3>&1 1>&2 2>&3
            )" || on_user_cancellation
        else
            # Just one device
            WIFI_DEVICE=$WIFI_DEVICES
        fi

        echo
        echo "Using WiFi device: $WIFI_DEVICE"

        # Prompt for WiFi SSID
        WIFI_SSID=$(prompt_input "Configure WiFi" "Enter WiFi SSID for $WIFI_DEVICE:")
        echo "SSID: $WIFI_SSID"
        echo

        # Prompt for WiFi password
        WIFI_PASSWORD=$(prompt_password "Configure WiFi" "Enter WiFi password for SSID '$WIFI_SSID':")
    else
        echo "WiFi configuration won't be changed"
        echo
    fi
else
    echo "No WiFi devices found"
    echo
fi


#------------------------------------------------------------------------------------------
# Switch to systemd networking
#------------------------------------------------------------------------------------------

print_title "Downloading switch script..."

echo "Downloading from: ${SCRIPT_URL}"
echo
if [[ -n "${SUDO}" ]]; then
    # If not already root, download script first to the user's home directory and move it later to /run.
    # This way we can download the script without "sudo".
    SWITCH_SCRIPT_BASE_PATH="$HOME"
else
    SWITCH_SCRIPT_BASE_PATH="/run"
fi

SWITCH_SCRIPT_PATH=$(mktemp -p "$SWITCH_SCRIPT_BASE_PATH" "configure-network.XXXXXX.sh")
curl -fsSL "$SCRIPT_URL" -o "$SWITCH_SCRIPT_PATH"

if [[ -n "${SUDO}" ]]; then
    ${SUDO} mv "$SWITCH_SCRIPT_PATH" "/run"
    SWITCH_SCRIPT_PATH="/run/$(basename "$SWITCH_SCRIPT_PATH")"
    echo
fi


print_title "Running switch script via systemd-run..."

# Runs the switch script through systemd. This way it doesn't stop if this command is executed from an SSH session (which will
# be killed during the execution of the switch script).
#
# NOTES:
# * `--collect` removes the systemd unit after it has finished (but doesn't clear its logs).
# * `--property=Type=exec` is recommended to detect certain types of startup errors.
# * `--setenv` passes the WiFi values to the non-interactive switch script.
# * If this command doesn't execute as expected, check "journalctl -u switch-networking-to-networkd".
${SUDO} systemd-run \
    "--unit=${UNIT_NAME}" \
    --property=Type=exec \
    --collect \
    --setenv=WIFI_DEVICE="$WIFI_DEVICE" \
    --setenv=WIFI_SSID="$WIFI_SSID" \
    --setenv=WIFI_PASSWORD="$WIFI_PASSWORD" \
    bash -c "bash $SWITCH_SCRIPT_PATH >${LOG_FILE} 2>&1"

echo
echo "Log file stored at: ${LOG_FILE}"
echo

# Make sure the log file exists so that it can be observed by "tail".
${SUDO} touch "$LOG_FILE"

# Print the switch script's output for as long as possible.
# ("-n +1" prints everything starting with line 1.)
tail -n +1 -f "$LOG_FILE"
