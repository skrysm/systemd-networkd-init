# Switch to systemd

Switches Debian-based systems from **ipupdown** and **NetworkManager** to **systemd-networkd**. Also switches from **wpa_supplicant** to **iwd**, if WiFi is used by the system (mainly on Raspberry Pi systems).

Also removes **netplan** (see below).

This script is intended for headless server systems, not for desktop systems.

It's intended for these distros:

* Debian
* Ubuntu
* Raspberry Pi OS

See also: [Network Configuration for Debian, Ubuntu, Raspberry Pi OS](https://manski.net/articles/linux/network-config)

## How to use

**To execute (as root):**

```sh
sudo -i
curl -fsSL https://raw.githubusercontent.com/skrysm/systemd-networkd-init/main/init.sh | bash
```

## Why this script?

I personally find [network configuration on Debian-based server systems](https://manski.net/articles/linux/network-config) a mess. Each distro uses a different method:

* Debian: ifupdown
* Ubuntu: systemd-networkd with netplan
* Raspberry Pi OS: NetworkManager with netplan

This script unifies the network configuration as: **systemd-networkd *without* netplan** (and **iwd** for WiFi, if necessary)

With this, the network configuration is always found in:

* systemd-networkd: `/etc/systemd/network/`
* iwd: `/var/lib/iwd/`

## Why no NetworkManager

Using *systemd-networkd* over *NetworkManager* is mainly opinionated (I needed to pick one). One thing I found is that NetworkManager seems to prefer UIs for configuration over configuration files - and I explicitly wanted configuration files.

## Why no netplan

My first thought was to use netplan on all systems (instead of forcing systemd-networkd) - but this didn't work because on Raspberry Pi OS 13 netplan and/or NetworkManager are heavily patched so that any configuration under `/etc/netplan` is removed and replaced with a generated one every time netplan runs.

To goal of this repo is to have stable, human-readable and human-editable configuration files for network configuration - and this is no longer (easily) possible on Raspberry Pi OS 13.

Also, netplan doesn't support iwd but only wpa-supplicant for WiFi.
