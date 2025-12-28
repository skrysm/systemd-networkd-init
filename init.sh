#!/bin/bash
#
# General notes:
#
# * $(...) removes all trailing line breaks.
#

set -euo pipefail

###########################################################################################
#
# Apt Functions
#
###########################################################################################

ensure_apt_is_updated() {
    local timestamp_file="/run/apt-update-timestamp"
    local current_time=$(date +%s)
    local last_update=0

    # Check if timestamp file exists
    if [ -f "$timestamp_file" ]; then
        last_update=$(cat "$timestamp_file")
    fi

    # Calculate time difference (24 hours = 86400 seconds)
    local time_diff=$((current_time - last_update))

    # Only run apt update if it hasn't been run in the last 24 hours
    if [ $time_diff -ge 86400 ]; then
        apt update
        echo "$current_time" > "$timestamp_file"
    fi
}

install_package() {
    # Make sure apt is up-to-date
    ensure_apt_is_updated

    # Do installation
    apt install -y --no-install-recommends $1
}

ensure_package() {
    if ! command -v "$1" &> /dev/null; then
        echo "$2 is not installed. Installing it..."
        echo
        install_package $2
        echo
    fi
}

ensure_whiptail() {
    ensure_package 'whiptail' 'whiptail'
}

ensure_iw() {
    ensure_package 'iw' 'iw'
}

ensure_iwd() {
    ensure_package 'iwctl' 'iwd'
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

# Prompt user for yes/no confirmation
prompt_yes_no() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"  # Default to 8 if not provided

    whiptail --yesno "$message" $height 78 --title "$title"

    case $? in
        0)
            return 0  # Yes
            ;;
        1)
            return 1  # No
            ;;
        255)
            # User pressed ESC
            on_user_cancellation
            ;;
        *)
            echo "ERROR: whiptail returned unexpected exit code: $?" >&2
            exit 1
            ;;
    esac
}

prompt_input() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"  # Default to 8 if not provided

    whiptail --inputbox "$message" $height 78 --title "$title" 3>&1 1>&2 2>&3 || on_user_cancellation
}

prompt_password() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"  # Default to 8 if not provided

    whiptail --passwordbox "$message" $height 78 --title "$title" 3>&1 1>&2 2>&3 || on_user_cancellation
}

###########################################################################################
#
# System Functions
#
###########################################################################################


recommend_screen_over_ssh() {
    # Detect SSH session (covers most setups)
    [[ -n "${SSH_CONNECTION-}" || -n "${SSH_CLIENT-}" || -n "${SSH_TTY-}" ]] || return 0

    # Don't nag if already inside a multiplexer
    [[ -n "${STY-}" || -n "${TMUX-}" ]] && return 0

    SSH_NOTE="
You are in an SSH session but not inside a screen session. It's
recommended to start a screen session to keep this script running if the
connection drops.

Do you still want to continue?
"

    if ! prompt_yes_no 'SSH session detected' "$SSH_NOTE" 14; then
        on_user_cancellation
    fi
}

check_service_installed() {
    if systemctl cat "$1" &>/dev/null; then
        return 0  # Service is installed
    else
        return 1  # Service is not installed
    fi
}

check_service_is_active() {
    if systemctl is-active --quiet "$1"; then
        if systemctl is-enabled --quiet "$1"; then
            return 0  # The service is running and enabled.
        fi
    fi

    return 1  # The service is either not running or not enabled.
}

check_service_is_running() {
    if systemctl is-active --quiet "$1"; then
        return 0  # The service is running.
    fi

    return 1  # The service is not running.
}

# Check if a WiFi device is present on the system
check_for_wifi_device() {
    if [ -d /sys/class/net ] && ls /sys/class/net/*/wireless &> /dev/null; then
        return 0  # WiFi device found
    else
        return 1  # No WiFi device found
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

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: This script must be run as root." >&2
  echo
  exit 1
fi

# Check that systemd is available on the system.
if ! check_service_installed 'systemd-networkd'; then
    echo "UNEXPECTED ERROR: systemd is not available" >&2
    echo
    exit 1
fi

# Make sure whiptail is installed
ensure_whiptail

recommend_screen_over_ssh

echo "Checking for WiFi devices..."
check_for_wifi_device
WIFI_PRESENT=$?

#------------------------------------------------------------------------------------------
# Do WiFi configuration (SSID, password)
#------------------------------------------------------------------------------------------

WIFI_DEVICE=''

if [ $WIFI_PRESENT ]; then
    echo "WiFi device detected"

    if prompt_yes_no "Configure WiFi" "Do you want to enable and configure the WiFi connection?"; then
        # Necessary for determining WiFi network device names
        ensure_iw

        WIFI_DEVICES=$(get_wifi_devices)
        if [ "$(printf '%s\n' "$WIFI_DEVICES" | wc -l)" -gt 1 ]; then
            mapfile -t wifi_array <<<"$WIFI_DEVICES"

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

        # Also install "iwd" if WiFi is used.
        ensure_iwd
    else
        echo "WiFi configuration won't be changed"
        echo
    fi
else
    echo "No WiFi devices found"
    echo
fi

#------------------------------------------------------------------------------------------
# Enable systemd networking
#------------------------------------------------------------------------------------------

# Write config to enable DHCP for all ethernet and wifi network interfaces.
SYSTEMD_DHCP_CONF_FILE=/etc/systemd/network/10-all-interfaces-dhcp.network
echo "Writing systemd-networkd DHCP config to: $SYSTEMD_DHCP_CONF_FILE"
echo
cat <<EOF > $SYSTEMD_DHCP_CONF_FILE
[Match]
Type=ether
Type=wlan

[Network]
DHCP=yes
EOF

# Check if systemd-networkd is enabled.
if ! check_service_is_active 'systemd-networkd'; then
    echo "systemd-networkd is not enabled. Enabling it..."
    echo
    systemctl enable --now systemd-networkd
    echo
fi

# Check if systemd-resolved is installed and is enabled.
# NOTE: This will take over DNS immediately. Meaning: No more package installation is possible after this.
if ! check_service_installed 'systemd-resolved'; then
    echo "systemd-resolved is not installed. Installing it..."
    echo
    install_package systemd-resolved
    echo
elif ! check_service_is_active 'systemd-resolved'; then
    echo "systemd-resolved is not enabled. Enabling it..."
    echo
    systemctl enable --now systemd-resolved
    echo
fi

apt purge -y ifupdown dhcpcd-base resolvconf netplan.io network-manager

rm -rf /etc/netplan
rm -rf /etc/NetworkManager

if [ -n "$WIFI_DEVICE" ]; then
    # Re-establish WiFi link (before switching to systemd)
    echo "Connecting $WIFI_DEVICE to WiFi network $WIFI_SSID..."
    echo

    # NOTE: This breaks the network connection and possibly DNS, if done before configuring
    #   systemd. So, it must be done after(!) systemd has been configured and especially after
    #   systemd-resolved has been installed.
    if check_service_is_running wpa_supplicant; then
        echo "Stopping wpa_supplicant..."
        echo
        systemctl stop wpa_supplicant
    fi

    # Make sure iwd is running and enabled.
    systemctl enable --now iwd

    # This is for debugging purposes.
    iwctl station list

    iwctl "--passphrase=$WIFI_PASSWORD" station $WIFI_DEVICE connect "$WIFI_SSID"

    apt purge -y wpasupplicant
fi
