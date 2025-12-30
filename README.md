# Switch to systemd

Switches Debian-based systems from ipupdown and NetworkManager to systemd-networkd. Also switches from wpa_supplicant to iwd, if WiFi is used by the system (mainly on Raspberry Pi systems).

Also removes netplan (see below).

**To execute (as root):**

```sh
curl -fsSL https://raw.githubusercontent.com/skrysm/systemd-networkd-init/main/init.sh | bash
```

## Why no netplan

My first thought was to use netplan on all systems (instead of forcing systemd-networkd) - but this didn't work because on Raspberry Pi OS 13 netplan and/or NetworkManager are heavily patched so that any configuration under `/etc/netplan` is removed and replaced with a generated one every time netplan runs.

To goal of this repo is to have stable, human-readable and human-editable configuration files for network configuration - and this is no longer (easily) possible on Raspberry Pi OS 13.

Also, netplan doesn't support iwd but only wpa-supplicant for WiFi.
