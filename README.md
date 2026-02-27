# Raspberry Pi 5 USB Ethernet Gadget Setup

This repository contains a setup script to enable Ethernet-over-USB (ECM gadget mode) on a Raspberry Pi.

## Script

- `setup_usb_ethernet_gadget.sh`

## What it does

- Configures boot overlay for USB peripheral mode (`dwc2`).
- Ensures required modules load at boot (`dwc2`, `libcomposite`).
- Installs a startup script at `/usr/local/sbin/usb_ethernet_gadget_start.sh`.
- Installs and enables a systemd service: `usb-ethernet-gadget.service`.
- Assigns a static IPv4 and netmask to the USB gadget interface.
- Creates backups in `./usb_gadget_backup` before changing system files.
- Stores backup files using original hierarchy (example: `usb_gadget_backup/etc/default/usb-ethernet-gadget`).

## Usage

```bash
chmod +x setup_usb_ethernet_gadget.sh
sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0
```

Optional interface name (default is `usb0`):

```bash
sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0 --iface usb0
```

Revert all previously changed files from backup:

```bash
sudo ./setup_usb_ethernet_gadget.sh --revert
```

## Notes

- `usb_gadget_backup` is created under the current working directory where you run the script.
- Keep the backup folder if you want `--revert` to be available later.
- A reboot is recommended after first setup so boot overlay/module changes are definitely active.
- The service is started once immediately by the installer and then on every boot.


# Author

paolo[dot]bosetti[at]unitn[dot]it