#!/usr/bin/env bash
set -euo pipefail

DEFAULT_IP="192.168.7.2"
DEFAULT_NETMASK="255.255.255.0"
DEFAULT_IFACE="usb0"
DEFAULT_MODE="static"
DEFAULT_BACKEND="auto"
BACKUP_DIR_NAME="usb_gadget_backup"

usage() {
  cat <<'USAGE'
Usage:
  sudo ./setup_usb_ethernet_gadget.sh [options]

Options:
  --ip <ipv4>              Static IPv4 exposed by Raspberry Pi over USB
                           Default: 192.168.7.2
  --netmask <mask>         Netmask for static USB IPv4
                           Default: 255.255.255.0
  --iface <name>           Gadget network interface name
                           Default: usb0
  --mode <static|dhcp>     Addressing mode for the USB link
                           Default: static
  --backend <auto|manual|official>
                           `auto` prefers `rpi-usb-gadget` on Raspberry Pi OS
                           Trixie when `--mode dhcp` is used and falls back to
                           the manual `g_ether` setup otherwise
                           Default: auto
  --diagnose               Print readiness diagnostics without changing the system
  --revert                 Revert changes using files from ./usb_gadget_backup
  -h, --help               Show this help

Examples:
  sudo ./setup_usb_ethernet_gadget.sh --ip 10.55.0.1 --netmask 255.255.255.0
  sudo ./setup_usb_ethernet_gadget.sh --diagnose
  sudo ./setup_usb_ethernet_gadget.sh --mode dhcp
  sudo ./setup_usb_ethernet_gadget.sh --mode dhcp --backend official
  sudo ./setup_usb_ethernet_gadget.sh --revert
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

note() {
  echo "Info: $*"
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run as root (use sudo)."
  fi
}

require_commands() {
  local cmd
  for cmd in awk chmod cp grep ip mkdir modprobe rm systemctl touch tr; do
    have_command "$cmd" || fail "Required command not found: $cmd"
  done
}

require_diagnose_commands() {
  local cmd
  for cmd in awk grep tr; do
    have_command "$cmd" || fail "Required command not found for diagnostics: $cmd"
  done
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

boot_overlay_enabled() {
  local boot_config
  boot_config="$(detect_boot_config)"
  grep -Eq '^[[:space:]]*dtoverlay=dwc2,dr_mode=peripheral([[:space:]]*#.*)?$' "$boot_config"
}

module_load_config_present() {
  local module_name="$1"
  local file
  for file in /etc/modules /etc/modules-load.d/*.conf; do
    [[ -e "$file" ]] || continue
    if grep -Eq "^[[:space:]]*${module_name}([[:space:]]*#.*)?$" "$file"; then
      return 0
    fi
  done
  return 1
}

read_pi_model() {
  if [[ -r /proc/device-tree/model ]]; then
    tr -d '\0' < /proc/device-tree/model
    return
  fi
  echo "unknown"
}

is_rpi_os_trixie() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${VERSION_CODENAME:-}" == "trixie" ]] || return 1
  [[ "${ID:-}" == "raspbian" || "${ID:-}" == "debian" ]]
}

select_dhcp_client() {
  if have_command dhclient; then
    echo "dhclient"
    return 0
  fi
  if have_command dhcpcd; then
    echo "dhcpcd"
    return 0
  fi
  if have_command udhcpc; then
    echo "udhcpc"
    return 0
  fi
  return 1
}

backup_path_for() {
  local target="$1"
  echo "${BACKUP_DIR}/${target#/}"
}

manifest_has_entry() {
  local target="$1"
  [[ -f "$MANIFEST_FILE" ]] || return 1
  grep -Fxq "M ${target}" "$MANIFEST_FILE" || grep -Fxq "N ${target}" "$MANIFEST_FILE"
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
  USB_MODE="$DEFAULT_MODE"
  BACKEND_REQUESTED="$DEFAULT_BACKEND"
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
      --mode)
        [[ $# -ge 2 ]] || fail "Missing value for --mode"
        USB_MODE="$2"
        shift 2
        ;;
      --backend)
        [[ $# -ge 2 ]] || fail "Missing value for --backend"
        BACKEND_REQUESTED="$2"
        shift 2
        ;;
      --diagnose)
        ACTION="diagnose"
        shift
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

  if [[ "$ACTION" != "setup" ]]; then
    return
  fi

  case "$USB_MODE" in
    static|dhcp) ;;
    *) fail "Invalid mode: ${USB_MODE}. Use static or dhcp." ;;
  esac

  case "$BACKEND_REQUESTED" in
    auto|manual|official) ;;
    *) fail "Invalid backend: ${BACKEND_REQUESTED}. Use auto, manual, or official." ;;
  esac

  if [[ "$USB_MODE" == "static" ]]; then
    is_valid_ipv4 "$USB_IP" || fail "Invalid IPv4 address: $USB_IP"
    is_valid_ipv4 "$USB_NETMASK" || fail "Invalid netmask: $USB_NETMASK"
    USB_CIDR="$(netmask_to_cidr "$USB_NETMASK")" || fail "Netmask is not contiguous: $USB_NETMASK"
  fi
}

resolve_backend() {
  BACKEND_REASON=""
  case "$BACKEND_REQUESTED" in
    manual)
      USB_BACKEND="manual"
      BACKEND_REASON="requested explicitly"
      ;;
    official)
      [[ "$USB_MODE" == "dhcp" ]] || fail "The official backend currently supports only --mode dhcp."
      [[ "$USB_IFACE" == "usb0" ]] || fail "The official backend expects --iface usb0."
      is_rpi_os_trixie || fail "The official backend requires Raspberry Pi OS Trixie."
      have_command rpi-usb-gadget || fail "The official backend requires the rpi-usb-gadget command to be installed."
      have_command nmcli || fail "The official backend requires NetworkManager's nmcli command."
      USB_BACKEND="official"
      BACKEND_REASON="requested explicitly"
      ;;
    auto)
      if [[ "$USB_MODE" == "dhcp" ]] && [[ "$USB_IFACE" == "usb0" ]] && is_rpi_os_trixie && have_command rpi-usb-gadget && have_command nmcli; then
        USB_BACKEND="official"
        BACKEND_REASON="Raspberry Pi OS Trixie with rpi-usb-gadget available"
      else
        USB_BACKEND="manual"
        if [[ "$USB_MODE" != "dhcp" ]]; then
          BACKEND_REASON="static mode requires manual backend"
        elif [[ "$USB_IFACE" != "usb0" ]]; then
          BACKEND_REASON="official backend expects usb0"
        elif ! is_rpi_os_trixie; then
          BACKEND_REASON="official backend not available on this OS"
        elif ! have_command rpi-usb-gadget; then
          BACKEND_REASON="rpi-usb-gadget not installed"
        elif ! have_command nmcli; then
          BACKEND_REASON="official backend requires NetworkManager"
        else
          BACKEND_REASON="manual backend selected"
        fi
      fi
      ;;
  esac
}

print_preflight_diagnostics() {
  local model
  model="$(read_pi_model)"

  note "Detected model: ${model}"
  note "Selected backend: ${USB_BACKEND} (${BACKEND_REASON})"
  note "Selected mode: ${USB_MODE}"

  if [[ "$model" != "unknown" ]] && [[ "$model" != *"Raspberry Pi"* ]]; then
    warn "This does not look like a Raspberry Pi. USB gadget bring-up is unlikely to work here."
  fi

  if [[ "$model" == *"Raspberry Pi 5"* ]]; then
    warn "Raspberry Pi 5 gadget mode requires the OTG-capable USB-C port. If the board is unstable when powered through USB-C, power it separately and keep USB-C for data."
  fi

  if [[ "$USB_BACKEND" == "manual" ]] && [[ "$USB_MODE" == "dhcp" ]]; then
    DHCP_CLIENT="$(select_dhcp_client)" || fail "DHCP mode requires dhclient, dhcpcd, or udhcpc for the manual backend."
    note "Manual DHCP client: ${DHCP_CLIENT}"
  fi

  if have_command vcgencmd; then
    local throttled
    throttled="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}' || true)"
    if [[ -n "$throttled" ]] && [[ "$throttled" != "0x0" ]]; then
      warn "Power/thermal status is not clean (get_throttled=${throttled}). USB gadget reliability may be affected."
    fi
  fi
}

diagnose_system() {
  local model
  local boot_config
  local status

  model="$(read_pi_model)"
  echo "USB Ethernet gadget diagnostics"
  echo "  Model:             ${model}"

  if is_rpi_os_trixie; then
    echo "  OS support:        Raspberry Pi OS Trixie detected"
  else
    echo "  OS support:        Raspberry Pi OS Trixie not detected"
  fi

  if boot_config="$(detect_boot_config 2>/dev/null)"; then
    echo "  Boot config:       ${boot_config}"
    if boot_overlay_enabled; then
      echo "  OTG overlay:       enabled"
    else
      echo "  OTG overlay:       missing dtoverlay=dwc2,dr_mode=peripheral"
    fi
  else
    echo "  Boot config:       not found"
  fi

  if module_load_config_present "dwc2"; then
    echo "  Boot module dwc2:  configured"
  else
    echo "  Boot module dwc2:  not configured"
  fi

  if have_command modinfo && modinfo g_ether >/dev/null 2>&1; then
    echo "  Kernel module:     g_ether available"
  else
    echo "  Kernel module:     g_ether not found by modinfo"
  fi

  if have_command rpi-usb-gadget; then
    echo "  Official backend:  rpi-usb-gadget installed"
  else
    echo "  Official backend:  rpi-usb-gadget not installed"
  fi

  if have_command nmcli; then
    echo "  NetworkManager:    nmcli available"
  else
    echo "  NetworkManager:    nmcli missing"
  fi

  if DHCP_CLIENT="$(select_dhcp_client 2>/dev/null)"; then
    echo "  DHCP client:       ${DHCP_CLIENT}"
  else
    echo "  DHCP client:       none detected"
  fi

  if have_command systemctl; then
    if systemctl is-enabled usb-ethernet-gadget.service >/dev/null 2>&1; then
      status="$(systemctl is-active usb-ethernet-gadget.service 2>/dev/null || true)"
      echo "  Manual service:    enabled (${status:-unknown})"
    elif systemctl list-unit-files | grep -Fq "usb-ethernet-gadget.service"; then
      status="$(systemctl is-active usb-ethernet-gadget.service 2>/dev/null || true)"
      echo "  Manual service:    installed but disabled (${status:-unknown})"
    else
      echo "  Manual service:    not installed"
    fi
  else
    echo "  Manual service:    unavailable (systemctl missing)"
  fi

  if have_command ip; then
    if ip link show "$USB_IFACE" >/dev/null 2>&1; then
      local addr
      addr="$(ip -o -4 addr show dev "$USB_IFACE" | awk '{print $4}' | paste -sd ',' -)"
      echo "  Interface state:   present (${USB_IFACE})"
      echo "  IPv4 address:      ${addr:-none}"
    else
      echo "  Interface state:   ${USB_IFACE} not present"
    fi
  else
    echo "  Interface state:   unavailable (ip command missing)"
  fi

  if have_command vcgencmd; then
    status="$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}' || true)"
    echo "  Power status:      ${status:-unknown}"
  else
    echo "  Power status:      vcgencmd unavailable"
  fi

  echo
  echo "Assessment"

  if [[ "$model" != *"Raspberry Pi"* ]]; then
    echo "  - This host does not identify as a Raspberry Pi. Gadget mode is unlikely to work."
  fi

  if [[ "$model" == *"Raspberry Pi 5"* ]]; then
    echo "  - Use the OTG-capable USB-C port for data. If power is unstable, power the board separately."
  fi

  if ! boot_overlay_enabled 2>/dev/null; then
    echo "  - Enable dtoverlay=dwc2,dr_mode=peripheral for manual g_ether bring-up."
  fi

  if ! module_load_config_present "dwc2"; then
    echo "  - Configure dwc2 to load at boot for the manual backend."
  fi

  if [[ "$BACKEND_REQUESTED" == "official" || "$BACKEND_REQUESTED" == "auto" ]]; then
    if ! is_rpi_os_trixie; then
      echo "  - Official backend is unavailable because Raspberry Pi OS Trixie is not detected."
    elif ! have_command rpi-usb-gadget; then
      echo "  - Official backend is unavailable because rpi-usb-gadget is not installed."
    elif ! have_command nmcli; then
      echo "  - Official backend is unavailable because NetworkManager/nmcli is missing."
    fi
  fi

  if [[ "$USB_MODE" == "dhcp" ]] && [[ "$BACKEND_REQUESTED" != "official" ]] && ! select_dhcp_client >/dev/null 2>&1; then
    echo "  - Manual DHCP mode is unavailable until dhclient, dhcpcd, or udhcpc is installed."
  fi
}

write_default_config() {
  cat > /etc/default/usb-ethernet-gadget <<DEFAULTS
USB_IP="${USB_IP}"
USB_NETMASK="${USB_NETMASK}"
USB_IFACE="${USB_IFACE}"
USB_MODE="${USB_MODE}"
USB_BACKEND="${USB_BACKEND}"
DEFAULTS
}

install_runtime_script() {
  cat > /usr/local/sbin/usb_ethernet_gadget_start.sh <<'RUNTIME'
#!/usr/bin/env bash
set -euo pipefail

PID_BASE="/run/usb-ethernet-gadget"

if [[ -f /etc/default/usb-ethernet-gadget ]]; then
  # shellcheck source=/etc/default/usb-ethernet-gadget
  source /etc/default/usb-ethernet-gadget
fi

USB_IP="${USB_IP:-192.168.7.2}"
USB_NETMASK="${USB_NETMASK:-255.255.255.0}"
USB_IFACE="${USB_IFACE:-usb0}"
USB_MODE="${USB_MODE:-static}"
ACTION="${1:-start}"

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

wait_for_interface() {
  local iface="$1"
  local attempt
  for attempt in $(seq 1 40); do
    if ip link show "$iface" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "Timed out waiting for interface ${iface}" >&2
  return 1
}

select_dhcp_client() {
  if command -v dhclient >/dev/null 2>&1; then
    echo "dhclient"
    return 0
  fi
  if command -v dhcpcd >/dev/null 2>&1; then
    echo "dhcpcd"
    return 0
  fi
  if command -v udhcpc >/dev/null 2>&1; then
    echo "udhcpc"
    return 0
  fi
  return 1
}

stop_dhcp_client() {
  if [[ -f "${PID_BASE}.dhclient.pid" ]]; then
    dhclient -r -pf "${PID_BASE}.dhclient.pid" "$USB_IFACE" >/dev/null 2>&1 || true
    rm -f "${PID_BASE}.dhclient.pid"
  fi

  if command -v dhcpcd >/dev/null 2>&1; then
    dhcpcd -x "$USB_IFACE" >/dev/null 2>&1 || dhcpcd -k "$USB_IFACE" >/dev/null 2>&1 || true
  fi

  if [[ -f "${PID_BASE}.udhcpc.pid" ]]; then
    kill "$(cat "${PID_BASE}.udhcpc.pid")" >/dev/null 2>&1 || true
    rm -f "${PID_BASE}.udhcpc.pid"
  fi
}

acquire_dhcp() {
  local client
  client="$(select_dhcp_client)" || {
    echo "No DHCP client found. Install dhclient, dhcpcd, or udhcpc." >&2
    exit 1
  }

  case "$client" in
    dhclient)
      dhclient -r "$USB_IFACE" >/dev/null 2>&1 || true
      dhclient -pf "${PID_BASE}.dhclient.pid" "$USB_IFACE"
      ;;
    dhcpcd)
      dhcpcd -w "$USB_IFACE"
      ;;
    udhcpc)
      udhcpc -S -i "$USB_IFACE" -p "${PID_BASE}.udhcpc.pid" >/dev/null 2>&1 &
      sleep 2
      ;;
  esac
}

start_manual_backend() {
  if ! modprobe g_ether; then
    echo "Failed to load g_ether. Ensure dtoverlay=dwc2,dr_mode=peripheral is active and the OTG-capable USB port is used." >&2
    exit 1
  fi

  wait_for_interface "$USB_IFACE"
  ip link set "$USB_IFACE" up
  ip addr flush dev "$USB_IFACE" || true

  if [[ "$USB_MODE" == "static" ]]; then
    local cidr
    cidr="$(netmask_to_cidr "$USB_NETMASK")"
    ip addr add "${USB_IP}/${cidr}" dev "$USB_IFACE"
    return
  fi

  stop_dhcp_client
  acquire_dhcp
}

stop_manual_backend() {
  stop_dhcp_client
  ip addr flush dev "$USB_IFACE" >/dev/null 2>&1 || true
  ip link set "$USB_IFACE" down >/dev/null 2>&1 || true
  modprobe -r g_ether >/dev/null 2>&1 || true
}

case "$ACTION" in
  start) start_manual_backend ;;
  stop) stop_manual_backend ;;
  *)
    echo "Unsupported action: ${ACTION}" >&2
    exit 1
    ;;
esac
RUNTIME

  chmod 0755 /usr/local/sbin/usb_ethernet_gadget_start.sh
}

install_systemd_service() {
  cat > /etc/systemd/system/usb-ethernet-gadget.service <<'SERVICE'
[Unit]
Description=USB Ethernet Gadget for Raspberry Pi
After=systemd-modules-load.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb_ethernet_gadget_start.sh start
ExecStop=/usr/local/sbin/usb_ethernet_gadget_start.sh stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable usb-ethernet-gadget.service
}

configure_boot_manual() {
  local boot_config
  boot_config="$(detect_boot_config)"

  backup_file_if_needed "$boot_config"
  backup_file_if_needed /etc/modules-load.d/usb-ethernet-gadget.conf

  append_if_missing "$boot_config" "dtoverlay=dwc2,dr_mode=peripheral"
  append_if_missing /etc/modules-load.d/usb-ethernet-gadget.conf "dwc2"
}

backup_install_targets() {
  local boot_config
  boot_config="$(detect_boot_config)"

  backup_file_if_needed "$boot_config"
  backup_file_if_needed /etc/default/usb-ethernet-gadget
  backup_file_if_needed /usr/local/sbin/usb_ethernet_gadget_start.sh
  backup_file_if_needed /etc/systemd/system/usb-ethernet-gadget.service
  backup_file_if_needed /etc/modules-load.d/usb-ethernet-gadget.conf
  backup_file_if_needed /etc/modules-load.d/usb-gadget.conf
  backup_file_if_needed /etc/NetworkManager/dnsmasq-shared.d/90-rpi-usb-gadget-lease.conf
}

disable_other_backend() {
  stop_disable_service_if_present
  if have_command rpi-usb-gadget; then
    rpi-usb-gadget off >/dev/null 2>&1 || true
  fi
}

enable_official_backend() {
  [[ "$USB_MODE" == "dhcp" ]] || fail "Official backend only supports DHCP mode."
  [[ "$USB_IFACE" == "usb0" ]] || fail "Official backend currently expects usb0."
  have_command nmcli || fail "Official backend requires nmcli."

  note "Enabling official rpi-usb-gadget backend."
  rpi-usb-gadget on
}

start_manual_service() {
  note "Applying manual gadget service now..."
  if ! systemctl start usb-ethernet-gadget.service; then
    echo "Service start failed. Check: journalctl -u usb-ethernet-gadget.service" >&2
    exit 1
  fi
}

revert_changes() {
  local manifest_file="${BACKUP_DIR}/manifest.txt"
  [[ -f "$manifest_file" ]] || fail "Backup manifest not found: $manifest_file"

  stop_disable_service_if_present
  if have_command rpi-usb-gadget; then
    rpi-usb-gadget off >/dev/null 2>&1 || true
  fi

  while IFS=' ' read -r state target; do
    [[ -n "$state" ]] || continue
    [[ -n "$target" ]] || continue
    restore_or_remove_file "$state" "$target"
  done < "$manifest_file"

  systemctl daemon-reload
  echo "Revert complete. Restored files from: ${BACKUP_DIR}"
}

setup_changes() {
  resolve_backend
  print_preflight_diagnostics
  backup_install_targets
  disable_other_backend
  write_default_config

  if [[ "$USB_BACKEND" == "official" ]]; then
    enable_official_backend
  else
    configure_boot_manual
    install_runtime_script
    install_systemd_service
    start_manual_service
  fi

  echo "Configured USB Ethernet gadget."
  echo "  Backend:   ${USB_BACKEND}"
  echo "  Mode:      ${USB_MODE}"
  echo "  Interface: ${USB_IFACE}"
  if [[ "$USB_MODE" == "static" ]]; then
    echo "  IP:        ${USB_IP}"
    echo "  Netmask:   ${USB_NETMASK} (/${USB_CIDR})"
  fi
  echo "  Backup:    ${BACKUP_DIR}"
  echo
  if [[ "$USB_BACKEND" == "official" ]]; then
    echo "Official backend enabled. Reboot is recommended if the overlay/modules were not already active."
  else
    echo "Manual backend started successfully. Reboot is recommended to ensure boot overlay/module changes are active."
  fi
}

main() {
  parse_args "$@"

  if [[ "$ACTION" == "diagnose" ]]; then
    require_diagnose_commands
    diagnose_system
    return
  fi

  require_root
  require_commands
  prepare_backup_env

  if [[ "$ACTION" == "revert" ]]; then
    revert_changes
  else
    setup_changes
  fi
}

main "$@"
