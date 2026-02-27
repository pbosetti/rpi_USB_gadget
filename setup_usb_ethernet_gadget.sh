#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IP="192.168.7.2"
DEFAULT_NETMASK="255.255.255.0"
DEFAULT_IFACE="usb0"
BACKUP_DIR_NAME="usb_gadget_backup"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./setup_usb_ethernet_gadget.sh [options]

Options:
  --ip <ipv4>          Static IPv4 exposed by Raspberry Pi over USB (default: 192.168.7.2)
  --netmask <mask>     Netmask for the USB IPv4 (default: 255.255.255.0)
  --iface <name>       Gadget network interface name (default: usb0)
  --revert             Revert changes using files from ./usb_gadget_backup
  -h, --help           Show this help

Examples:
  sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0
  sudo ./setup_usb_ethernet_gadget.sh --revert
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run as root (use sudo)."
  fi
}

is_valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets=()

  read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

netmask_to_cidr() {
  local mask="$1"
  local IFS='.'
  local -a octets=()
  local cidr=0
  local tail_only=0

  read -r -a octets <<< "$mask"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  local o bits
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1

    if (( tail_only == 1 )); then
      (( o == 0 )) || return 1
      continue
    fi

    case "$o" in
      255) (( cidr += 8 )) ;;
      254) bits=7; (( cidr += bits )); tail_only=1 ;;
      252) bits=6; (( cidr += bits )); tail_only=1 ;;
      248) bits=5; (( cidr += bits )); tail_only=1 ;;
      240) bits=4; (( cidr += bits )); tail_only=1 ;;
      224) bits=3; (( cidr += bits )); tail_only=1 ;;
      192) bits=2; (( cidr += bits )); tail_only=1 ;;
      128) bits=1; (( cidr += bits )); tail_only=1 ;;
      0) tail_only=1 ;;
      *) return 1 ;;
    esac
  done

  echo "$cidr"
  return 0
}

append_if_missing() {
  local file="$1"
  local line="$2"
  touch "$file"
  if ! grep -Fxq "$line" "$file"; then
    echo "$line" >> "$file"
  fi
}

detect_boot_config() {
  if [[ -f /boot/firmware/config.txt ]]; then
    echo "/boot/firmware/config.txt"
    return
  fi
  if [[ -f /boot/config.txt ]]; then
    echo "/boot/config.txt"
    return
  fi
  fail "Could not find Raspberry Pi boot config file (expected /boot/firmware/config.txt or /boot/config.txt)."
}

backup_path_for() {
  local target="$1"
  echo "${BACKUP_DIR}/${target#/}"
}

manifest_has_entry() {
  local target="$1"
  [[ -f "$MANIFEST_FILE" ]] || return 1
  grep -Eq "^[MN] ${target}$" "$MANIFEST_FILE"
}

backup_file_if_needed() {
  local target="$1"
  local backup_path

  manifest_has_entry "$target" && return 0

  backup_path="$(backup_path_for "$target")"
  mkdir -p "$(dirname "$backup_path")"

  if [[ -e "$target" ]]; then
    cp -a "$target" "$backup_path"
    echo "M ${target}" >> "$MANIFEST_FILE"
  else
    echo "N ${target}" >> "$MANIFEST_FILE"
  fi
}

prepare_backup_env() {
  BACKUP_DIR="$(pwd)/${BACKUP_DIR_NAME}"
  MANIFEST_FILE="${BACKUP_DIR}/manifest.txt"
  mkdir -p "$BACKUP_DIR"
  touch "$MANIFEST_FILE"
}

restore_or_remove_file() {
  local state="$1"
  local target="$2"
  local backup_path

  backup_path="$(backup_path_for "$target")"

  if [[ "$state" == "M" ]]; then
    [[ -e "$backup_path" ]] || fail "Backup missing for ${target}: ${backup_path}"
    mkdir -p "$(dirname "$target")"
    cp -a "$backup_path" "$target"
    return 0
  fi

  if [[ "$state" == "N" ]]; then
    rm -f "$target"
    return 0
  fi

  fail "Invalid manifest entry for ${target}: ${state}"
}

stop_disable_service_if_present() {
  if systemctl list-unit-files | grep -Fq "usb-ethernet-gadget.service"; then
    systemctl disable --now usb-ethernet-gadget.service || true
  else
    systemctl stop usb-ethernet-gadget.service || true
  fi
}

parse_args() {
  USB_IP="$DEFAULT_IP"
  USB_NETMASK="$DEFAULT_NETMASK"
  USB_IFACE="$DEFAULT_IFACE"
  ACTION="setup"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip)
        [[ $# -ge 2 ]] || fail "Missing value for --ip"
        USB_IP="$2"
        shift 2
        ;;
      --netmask)
        [[ $# -ge 2 ]] || fail "Missing value for --netmask"
        USB_NETMASK="$2"
        shift 2
        ;;
      --iface)
        [[ $# -ge 2 ]] || fail "Missing value for --iface"
        USB_IFACE="$2"
        shift 2
        ;;
      --revert)
        ACTION="revert"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  if [[ "$ACTION" == "setup" ]]; then
    is_valid_ipv4 "$USB_IP" || fail "Invalid IPv4 address: $USB_IP"
    is_valid_ipv4 "$USB_NETMASK" || fail "Invalid netmask: $USB_NETMASK"
    USB_CIDR="$(netmask_to_cidr "$USB_NETMASK")" || fail "Netmask is not contiguous: $USB_NETMASK"
  fi
}

install_runtime_script() {
  cat > /usr/local/sbin/usb_ethernet_gadget_start.sh <<'RUNTIME'
#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/default/usb-ethernet-gadget ]]; then
  # shellcheck source=/etc/default/usb-ethernet-gadget
  source /etc/default/usb-ethernet-gadget
fi

USB_IP="${USB_IP:-192.168.7.2}"
USB_NETMASK="${USB_NETMASK:-255.255.255.0}"
USB_IFACE="${USB_IFACE:-usb0}"

netmask_to_cidr() {
  local mask="$1"
  local IFS='.'
  local -a octets=()
  local cidr=0
  local tail_only=0

  read -r -a octets <<< "$mask"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  local o bits
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1

    if (( tail_only == 1 )); then
      (( o == 0 )) || return 1
      continue
    fi

    case "$o" in
      255) (( cidr += 8 )) ;;
      254) bits=7; (( cidr += bits )); tail_only=1 ;;
      252) bits=6; (( cidr += bits )); tail_only=1 ;;
      248) bits=5; (( cidr += bits )); tail_only=1 ;;
      240) bits=4; (( cidr += bits )); tail_only=1 ;;
      224) bits=3; (( cidr += bits )); tail_only=1 ;;
      192) bits=2; (( cidr += bits )); tail_only=1 ;;
      128) bits=1; (( cidr += bits )); tail_only=1 ;;
      0) tail_only=1 ;;
      *) return 1 ;;
    esac
  done

  echo "$cidr"
}

modprobe libcomposite
mkdir -p /sys/kernel/config
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

G=/sys/kernel/config/usb_gadget/usbeth
mkdir -p "$G"

echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
echo 0x0100 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"

mkdir -p "$G/strings/0x409"
SERIAL="$(awk -F': ' '/^Serial/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
if [[ -z "$SERIAL" ]]; then
  SERIAL="0000000000000000"
fi
echo "$SERIAL" > "$G/strings/0x409/serialnumber"
echo "Raspberry Pi" > "$G/strings/0x409/manufacturer"
echo "USB Ethernet Gadget" > "$G/strings/0x409/product"

mkdir -p "$G/configs/c.1/strings/0x409"
echo "USB ECM config" > "$G/configs/c.1/strings/0x409/configuration"
echo 120 > "$G/configs/c.1/MaxPower"

if [[ ! -d "$G/functions/ecm.usb0" ]]; then
  mkdir -p "$G/functions/ecm.usb0"
fi
if [[ ! -L "$G/configs/c.1/ecm.usb0" ]]; then
  ln -s "$G/functions/ecm.usb0" "$G/configs/c.1/ecm.usb0"
fi

if [[ ! -s "$G/UDC" ]]; then
  UDC_NAME="$(ls /sys/class/udc | head -n1)"
  if [[ -z "$UDC_NAME" ]]; then
    echo "No UDC controller found. Ensure OTG peripheral mode is enabled." >&2
    exit 1
  fi
  echo "$UDC_NAME" > "$G/UDC"
fi

USB_CIDR="$(netmask_to_cidr "$USB_NETMASK")"
ip link set "$USB_IFACE" up || true
ip addr flush dev "$USB_IFACE" || true
ip addr add "${USB_IP}/${USB_CIDR}" dev "$USB_IFACE"
RUNTIME

  chmod 0755 /usr/local/sbin/usb_ethernet_gadget_start.sh
}

install_systemd_service() {
  cat > /etc/systemd/system/usb-ethernet-gadget.service <<'SERVICE'
[Unit]
Description=USB Ethernet Gadget (ECM) for Raspberry Pi
After=systemd-modules-load.service sys-kernel-config.mount
Requires=sys-kernel-config.mount

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb_ethernet_gadget_start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable usb-ethernet-gadget.service
}

write_default_config() {
  cat > /etc/default/usb-ethernet-gadget <<DEFAULTS
USB_IP="${USB_IP}"
USB_NETMASK="${USB_NETMASK}"
USB_IFACE="${USB_IFACE}"
DEFAULTS
}

configure_boot() {
  local boot_config
  boot_config="$(detect_boot_config)"

  backup_file_if_needed "$boot_config"
  backup_file_if_needed /etc/modules-load.d/usb-ethernet-gadget.conf

  append_if_missing "$boot_config" "dtoverlay=dwc2,dr_mode=peripheral"
  append_if_missing /etc/modules-load.d/usb-ethernet-gadget.conf "dwc2"
  append_if_missing /etc/modules-load.d/usb-ethernet-gadget.conf "libcomposite"
}

backup_install_targets() {
  backup_file_if_needed /etc/default/usb-ethernet-gadget
  backup_file_if_needed /usr/local/sbin/usb_ethernet_gadget_start.sh
  backup_file_if_needed /etc/systemd/system/usb-ethernet-gadget.service
}

revert_changes() {
  local manifest_file="${BACKUP_DIR}/manifest.txt"
  [[ -f "$manifest_file" ]] || fail "Backup manifest not found: $manifest_file"

  stop_disable_service_if_present

  while IFS=' ' read -r state target; do
    [[ -n "$state" ]] || continue
    [[ -n "$target" ]] || continue
    restore_or_remove_file "$state" "$target"
  done < "$manifest_file"

  systemctl daemon-reload
  echo "Revert complete. Restored files from: ${BACKUP_DIR}"
}

setup_changes() {
  backup_install_targets
  configure_boot
  write_default_config
  install_runtime_script
  install_systemd_service

  echo "Configured USB Ethernet gadget."
  echo "  IP:        ${USB_IP}"
  echo "  Netmask:   ${USB_NETMASK} (/${USB_CIDR})"
  echo "  Interface: ${USB_IFACE}"
  echo "  Backup:    ${BACKUP_DIR}"
  echo
  echo "Applying service now..."
  if ! systemctl start usb-ethernet-gadget.service; then
    echo "Service start failed. Check: journalctl -u usb-ethernet-gadget.service" >&2
    exit 1
  fi
  echo "Service started successfully."
  echo "Reboot is recommended to ensure boot overlay/module changes are active."
}

main() {
  parse_args "$@"
  require_root
  prepare_backup_env

  if [[ "$ACTION" == "revert" ]]; then
    revert_changes
  else
    setup_changes
  fi
}

main "$@"
