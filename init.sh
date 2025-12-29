#!/bin/bash
#
# General notes:
#
# * $(...) removes all trailing line breaks.
# * $SECONDS is a special shell variable that contains the seconds since the shell has started.
#

set -euo pipefail

###########################################################################################
#
# Output Functions
#
###########################################################################################

print_heading() {
    echo -e "\033[36m$1\033[0m"
    echo
}

print_error() {
    echo -e "\033[31m$1\033[0m" >&2
}

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
        print_heading "Running 'apt update'..."
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
        print_heading "$2 is not installed. Installing it..."

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

show_message_box() {
    local title="$1"
    local message="$2"
    local height="${3:-8}"  # Default to 8 if not provided

    whiptail --msgbox "$message" $height 78 --title "$title"
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
            print_error "UNEXPECTED: whiptail returned unexpected exit code: $?"
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

is_ssh_session() {
    # Check for SSH environment variables first (common case)
    if [[ -n "${SSH_CONNECTION-}" || -n "${SSH_CLIENT-}" || -n "${SSH_TTY-}" ]]; then
        return 0
    fi

    # Check parent process tree for sshd (handles sudo -i case)
    local pid=$$
    local depth=0
    local max_depth=50

    while [[ $pid -gt 1 && $depth -lt $max_depth ]]; do
        if [[ ! -f "/proc/$pid/cmdline" ]]; then
            break
        fi

        local cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')
        if [[ "$cmdline" == *"sshd"* ]]; then
            return 0
        fi

        pid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)
        ((depth++))
    done

    if [[ $depth -ge $max_depth ]]; then
        print_error "UNEXPECTED: Maximum process tree depth exceeded while checking for SSH session."
        exit 1
    fi

    return 1
}

check_ssh_without_screen() {
    # Detect SSH session
    if ! is_ssh_session; then
        return
    fi

    # Don't nag if already inside a multiplexer
    if [[ -n "${STY-}" || -n "${TMUX-}" ]]; then
        return
    fi

    SSH_NOTE="
You are in an SSH session but not inside a screen session. This script must be
run in a screen session because the network connection is drop while this script
runs - and this would otherwise kill the script.
"
    show_message_box 'SSH session detected' "$SSH_NOTE" 12
    exit 1
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

check_for_ethernet_device() {
    if [ -d /sys/class/net ]; then
        for iface in /sys/class/net/*/; do
            iface_name=$(basename "$iface")
            # Check for ethernet devices (eth* or en*)
            if [[ "$iface_name" =~ ^(eth|en) ]]; then
                return 0  # Ethernet device found
            fi
        done
    fi
    return 1  # No ethernet device found
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
  print_error "ERROR: This script must be run as root."
  exit 1
fi

# Check that systemd is available on the system.
if ! check_service_installed 'systemd-networkd'; then
    print_error "UNEXPECTED: systemd is not available" >&2
    exit 1
fi

# Make sure whiptail is installed
ensure_whiptail

# Make sure where in a screen session if we're in an SSH session
check_ssh_without_screen

print_heading "Checking for WiFi devices..."
check_for_wifi_device
WIFI_PRESENT=$?


#------------------------------------------------------------------------------------------
# Do WiFi configuration (SSID, password)
#------------------------------------------------------------------------------------------

WIFI_DEVICE=''

if [ $WIFI_PRESENT ]; then
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


    if [ $CONFIGURE_WIFI ]; then
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
# Switch to systemd networking
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
    print_heading "systemd-networkd is not enabled. Enabling it..."

    systemctl enable --now systemd-networkd
    echo
fi

# Check if systemd-resolved is installed and is enabled.
# NOTE: This will take over DNS immediately. Meaning: No more package installation is possible after this.
if ! check_service_installed 'systemd-resolved'; then
    print_heading "systemd-resolved is not installed. Installing it..."

    install_package systemd-resolved
    echo
elif ! check_service_is_active 'systemd-resolved'; then
    print_heading "systemd-resolved is not enabled. Enabling it..."

    systemctl enable --now systemd-resolved
    echo
fi

print_heading "Removing other network configuration tools..."

apt purge -y ifupdown dhcpcd-base resolvconf netplan.io network-manager

rm -rf /etc/netplan
rm -rf /etc/NetworkManager


#------------------------------------------------------------------------------------------
# Switch to iwd for WiFi
#------------------------------------------------------------------------------------------

if [ -n "$WIFI_DEVICE" ]; then
    # Re-establish WiFi link (before switching to systemd)
    print_heading "Connecting $WIFI_DEVICE to WiFi network $WIFI_SSID..."

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

    # Wait for WiFi device to become available (will not(!) be instantaneous after iwd is enabled).
    WIFI_DEVICE_WAIT_SEC=120
    WIFI_DEVICE_DEADLINE=$((SECONDS + WIFI_DEVICE_WAIT_SEC))
    echo "Waiting for $WIFI_DEVICE to appear in iwd (timeout: ${WIFI_DEVICE_WAIT_SEC}s)..."
    while ! iwctl device $WIFI_DEVICE show >/dev/null 2>&1; do
        if (( SECONDS >= WIFI_DEVICE_DEADLINE )); then
            print_error "ERROR: $WIFI_DEVICE did not become available in iwd within ${WIFI_DEVICE_WAIT_SEC}s."
            echo

            # Show list of available devices for debugging purposes.
            iwctl station list

            exit 1
        fi
        sleep 2
    done

    # Connect WiFi device to WiFi network
    iwctl "--passphrase=$WIFI_PASSWORD" station $WIFI_DEVICE connect "$WIFI_SSID"

    # Remove wpa-supplicant
    apt purge -y wpasupplicant
fi
