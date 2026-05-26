#
# General notes:
#
# * $(...) removes all trailing line breaks.
# * $SECONDS is a special shell variable that contains the seconds since the shell has started.
#

# Exit immediately if any command exits with non-zero status
set -e
# Exit if an undefined variable is used
set -u
# Fail if any command in a pipeline fails (not just the last one)
set -o pipefail

# Enable for debugging
#set -x
#PS4='+ ${BASH_SOURCE}:${LINENO}: '
# Print line at which the script failed, if it failed (due to "set -e").
# NOTE: There are a lot of issues when using $(...) with traps (i.e. they don't work as
#   expected). That's why this isn't enabled by default.
#trap 'print_error "Script failed at line $LINENO"' ERR


###########################################################################################
#
# Logging/Output
#
###########################################################################################

# Colors for output (optional)
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
        print_title "Running 'apt-get update'..."
        ${SUDO} apt-get update
        echo
        ${SUDO} touch "$apt_update_marker_file"
    fi
}

install_package() {
    ensure_apt_is_updated

    print_title "Installing package '$1'..."
    apt-get install -y --no-install-recommends $1
}

ensure_package() {
    if ! command -v "$1" &> /dev/null; then
        print_title "$2 is not installed. Installing it..."

        install_package $2
        echo
    fi
}

ensure_iwd() {
    ensure_package 'iwctl' 'iwd'
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

#------------------------------------------------------------------------------------------
# Do WiFi configuration (SSID, password)
#------------------------------------------------------------------------------------------

WIFI_DEVICE="${WIFI_DEVICE:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

if [ -n "$WIFI_DEVICE" ]; then
    if [[ -z "${WIFI_SSID:-}" || -z "${WIFI_PASSWORD:-}" ]]; then
        print_error "ERROR: WiFi configuration requested but WIFI_SSID or WIFI_PASSWORD is not set."
        exit 1
    fi

    # Also install "iwd" if WiFi is used.
    ensure_iwd
fi


#------------------------------------------------------------------------------------------
# Switch to systemd networking
#------------------------------------------------------------------------------------------

print_title "Enabling and configuring systemd-networkd..."

# Write config to enable DHCP for all ethernet and wifi network interfaces.
SYSTEMD_DHCP_CONF_FILE=/etc/systemd/network/10-all-interfaces-dhcp.network
echo -e "Writing systemd-networkd DHCP config to: ${GREEN}$SYSTEMD_DHCP_CONF_FILE${NC}"
echo
cat <<EOF > "$SYSTEMD_DHCP_CONF_FILE"
[Match]
# NOTE: Don't use Type=ether or it will break Docker's container networking.
Name=en*
Name=eth*
Name=wl*

[Network]
DHCP=yes
EOF

# For easier visibility, print the contents of the file to the terminal. Also indent for easier visibility.
sed 's/^/    /' "$SYSTEMD_DHCP_CONF_FILE"
echo

# Check if systemd-networkd is enabled.
if ! check_service_is_active 'systemd-networkd'; then
    print_title "systemd-networkd is not enabled. Enabling it..."

    systemctl enable --now systemd-networkd
    echo
fi

# Check if systemd-resolved is installed and is enabled.
# NOTE: This will take over DNS immediately. Meaning: No more package installation is possible after this.
if ! check_service_installed 'systemd-resolved'; then
    print_title "systemd-resolved is not installed. Installing it..."

    install_package systemd-resolved
    echo
elif ! check_service_is_active 'systemd-resolved'; then
    print_title "systemd-resolved is not enabled. Enabling it..."

    systemctl enable --now systemd-resolved
    echo
fi

print_title "Removing other network configuration tools..."

# NOTE: We don't remove "dhcpcd-base" here because on Ubuntu this package is required for "initramfs-tools".
apt-get purge -y ifupdown resolvconf netplan.io network-manager

rm -rf /etc/netplan
rm -rf /etc/NetworkManager

echo


#------------------------------------------------------------------------------------------
# Switch to iwd for WiFi
#------------------------------------------------------------------------------------------

if [ -n "$WIFI_DEVICE" ]; then
    # Re-establish WiFi link (before switching to systemd)
    print_title "Connecting $WIFI_DEVICE to WiFi network $WIFI_SSID..."

    # NOTE: This breaks the network connection and possibly DNS, if done before configuring
    #   systemd. So, it must be done after(!) systemd has been configured and especially after
    #   systemd-resolved has been installed.
    if check_service_is_running wpa_supplicant; then
        echo "Stopping wpa_supplicant..."
        echo
        systemctl stop wpa_supplicant
    fi

    # Make sure iwd is running and enabled.
    echo "Enabling iwd..."
    echo
    systemctl enable --now iwd

    # Wait for WiFi device to become available (will not(!) be instantaneous after iwd is enabled).
    WIFI_DEVICE_WAIT_SEC=120
    WIFI_DEVICE_DEADLINE=$((SECONDS + WIFI_DEVICE_WAIT_SEC))
    echo "Waiting for $WIFI_DEVICE to appear in iwd (timeout: ${WIFI_DEVICE_WAIT_SEC}s)..."
    while ! iwctl device "$WIFI_DEVICE" show >/dev/null 2>&1; do
        if (( SECONDS >= WIFI_DEVICE_DEADLINE )); then
            print_error "ERROR: $WIFI_DEVICE did not become available in iwd within ${WIFI_DEVICE_WAIT_SEC}s."
            echo

            # Show list of available devices for debugging purposes.
            iwctl station list

            exit 1
        fi
        sleep 2
    done

    echo "$WIFI_DEVICE found"
    echo

    # Connect WiFi device to WiFi network
    echo "Connecting "$WIFI_DEVICE" to network '$WIFI_SSID'..."
    echo
    iwctl "--passphrase=$WIFI_PASSWORD" station "$WIFI_DEVICE" connect "$WIFI_SSID"

    # Remove wpa-supplicant and wireless-tools
    echo "Removing wpa-supplicant and wireless-tools..."
    echo
    apt-get purge -y wpasupplicant wireless-tools
    echo
else
    echo -e "${CYAN}${DIM}WiFi configuration skipped.${NC}"
    echo
fi

# Let's do a reboot to make sure everything is clean.
print_title "Done. Rebooting..."
reboot
