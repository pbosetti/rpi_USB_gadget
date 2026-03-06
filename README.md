# Raspberry Pi 5 USB Ethernet Gadget Setup

This repository contains a setup script to enable Ethernet-over-USB gadget mode on a Raspberry Pi 5.

## Script

- `setup_usb_ethernet_gadget.sh`

## What it does

- Supports `static` mode with a fixed IP/netmask on the Pi side.
- Supports `dhcp` mode for host-provided addressing or Internet Connection Sharing.
- Supports `auto`, `manual`, and `official` backends.
- In `auto`, prefers `rpi-usb-gadget` on Raspberry Pi OS Trixie when `--mode dhcp` is used.
- Falls back to a manual `g_ether` + systemd setup otherwise.
- Supports `--diagnose` to inspect readiness without changing the system.
- Configures boot overlay for USB peripheral mode (`dwc2`) when the manual backend is used.
- Installs a startup script at `/usr/local/sbin/usb_ethernet_gadget_start.sh` for the manual backend.
- Installs and enables a systemd service `usb-ethernet-gadget.service` for the manual backend.
- Creates backups in `./usb_gadget_backup` before changing system files.
- Stores backup files using original hierarchy (example: `usb_gadget_backup/etc/default/usb-ethernet-gadget`).
- Prints hardware and power diagnostics before applying changes.

## Usage

```bash
chmod +x setup_usb_ethernet_gadget.sh
sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0
```

Manual DHCP mode:

```bash
sudo ./setup_usb_ethernet_gadget.sh --mode dhcp --backend manual
```

Automatic backend selection:

```bash
sudo ./setup_usb_ethernet_gadget.sh --mode dhcp
```

Read-only diagnostics:

```bash
./setup_usb_ethernet_gadget.sh --diagnose
```

Explicitly use the official Raspberry Pi OS Trixie tooling:

```bash
sudo ./setup_usb_ethernet_gadget.sh --mode dhcp --backend official
```

Optional interface name for the manual backend (default is `usb0`):

```bash
sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0 --iface usb0 --backend manual
```

Revert all previously changed files from backup:

```bash
sudo ./setup_usb_ethernet_gadget.sh --revert
```

## Notes

- `usb_gadget_backup` is created under the current working directory where you run the script.
- Keep the backup folder if you want `--revert` to be available later.
- On Raspberry Pi 5, use the OTG-capable USB-C connection for gadget mode. If the board is not powering reliably through that link, power it separately and keep USB-C available for data.
- The official backend is used only for `--mode dhcp` and expects `usb0`.
- The manual DHCP backend requires a DHCP client on the Pi such as `dhclient`, `dhcpcd`, or `udhcpc`.
- `--diagnose` checks model detection, OTG overlay presence, `dwc2` boot configuration, `g_ether` availability, official backend tooling, DHCP client availability, current service state, and current `usb0` address state.
- A reboot is recommended after first setup so boot overlay/module changes are definitely active.
- The manual backend service is started once immediately by the installer and then on every boot.


# Author

paolo[dot]bosetti[at]unitn[dot]it
