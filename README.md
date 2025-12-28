# Switch to systemd

Switches Debian-based systems from ipupdown and NetworkManager to systemd-networkd. Also switches from wpa_supplicant to iwd, if WiFi is used by the system (mainly on Raspberry Pi systems).

**To execute:**

```sh
curl -fsSL https://raw.githubusercontent.com/skrysm/systemd-networkd-init/main/init.sh | bash
```
