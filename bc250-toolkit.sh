#!/usr/bin/env bash
# ==============================================================================
# Bazzite BC250 Toolkit
# Bazzite/Fedora Atomic adaptation inspired by redbeard1083/bc250-toolkit.
#
# Intentional differences from the original CachyOS-oriented workflow:
# - no pacman/paru
# - no mkinitcpio
# - no direct Limine editing
# - uses rpm-ostree, rpm-ostree kargs, systemd and COPR
# - designed to be the first tool launched after a fresh Bazzite install
# ==============================================================================
set -Eeuo pipefail

VERSION="2.9-bazzite"
APP_TITLE="Bazzite BC250 Toolkit"
APP_SUBTITLE="System Setup & Configuration"

CONFIG_DIR="/etc/bc250-bazzite-toolkit"
GPU_CONFIG="/etc/cyan-skillfish-governor-smu/config.toml"
PROFILE_STATE="$CONFIG_DIR/active-profile.env"
SWAPFILE="/var/swap/swapfile"
CPU_REPO="https://github.com/bc250-collective/bc250_smu_oc.git"
CPU_REPO_DIR="/opt/bc250_smu_oc"

# 40 CU live manager: recommended Bazzite path.
# This replaces the old amdgpu-module build workflow in the main 40 CU menu.
CU_LIVE_MANAGER_URL="https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh"
CU_LIVE_MANAGER_WORKDIR="/opt/bc250-cu-live-manager"
CU_LIVE_MANAGER_LOCAL="${CU_LIVE_MANAGER_WORKDIR}/bc250-cu-live-manager.sh"
CU_LIVE_MANAGER_BIN="/usr/local/bin/bc250-cu-live-manager"
CU_LIVE_MANAGER_SERVICE="bc250-cu-live-manager.service"

# Terminal colors, readable in Konsole and most ANSI terminals.
RESET="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
WHITE="\e[97m"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo /root)"


detect_downloads_dir() {
  # Detect the user's localized Downloads directory.
  # This matters on French Bazzite/KDE systems where the folder is often
  # "Téléchargements" instead of "Downloads".
  local dir=""

  if command -v xdg-user-dir >/dev/null 2>&1; then
    dir="$(sudo -u "$REAL_USER" env HOME="$REAL_HOME" xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    if [[ -n "$dir" && -d "$dir" ]]; then
      echo "$dir"
      return 0
    fi
  fi

  local candidate
  for candidate in \
    "$REAL_HOME/Téléchargements" \
    "$REAL_HOME/Telechargements" \
    "$REAL_HOME/Downloads" \
    "$REAL_HOME/Desktop" \
    "$REAL_HOME"; do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  echo "$REAL_HOME"
}

USER_DOWNLOADS_DIR="$(detect_downloads_dir)"
CANONICAL_HOME_SCRIPT="${REAL_HOME}/bc250-toolkit.sh"
CANONICAL_HOME_SCRIPT_ALT="${REAL_HOME}/bc250-toolkit-bazzite.sh"


trap 'echo -e "\n${RED}✘ Error on line $LINENO.${RESET}" >&2' ERR

# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------

clear_screen() {
  clear || true
}

line() {
  echo -e "${DIM}──────────────────────────────────────────────────────────────${RESET}"
}

heavy_line() {
  echo -e "${DIM}══════════════════════════════════════════════════════════════${RESET}"
}

center_text() {
  local text="$1"
  local width=62
  local len=${#text}
  local pad=$(( (width - len) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%*s%s%*s" "$pad" "" "$text" "$((width - len - pad))" ""
}

banner() {
  clear_screen
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║                                                              ║"
  echo "║$(center_text "$APP_TITLE")║"
  echo "║$(center_text "$APP_SUBTITLE")║"
  echo "║                                                              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${RESET}${DIM}Version: ${VERSION}${RESET}"
  echo
}

title() {
  echo -e "${BOLD}${WHITE}$1${RESET}"
  line
}

section() {
  echo -e "${BOLD}${YELLOW}$1${RESET}"
  line
}

menu_item() {
  local key="$1"
  local label="$2"
  local desc="${3:-}"
  printf "  ${BOLD}[ %s]${RESET}  %-19s %s\n" "$key" "$label" "$desc"
}

info() { echo -e "${CYAN}→${RESET} $*"; }
ok()   { echo -e "${GREEN}✓${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✘${RESET} $*" >&2; }

pause() {
  echo
  read -r -p "Press Enter to continue..." _
}

confirm() {
  local prompt="${1:-Continue?}"
  local ans
  echo -e "${YELLOW}${prompt}${RESET} [y/N]"
  read -r -p "> " ans
  [[ "$ans" =~ ^[YyOo]$ ]]
}

die() {
  err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}


systemd_unit_exists() {
  local unit="$1"
  systemctl cat "$unit" >/dev/null 2>&1 && return 0
  systemctl list-unit-files --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"
}


toolkit_user_path() {
  echo "${REAL_HOME}/.local/bin:${REAL_HOME}/.cargo/bin:${REAL_HOME}/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
}

shell_quote() {
  printf "%q" "$1"
}

command_path_as_user() {
  local cmd="$1"
  sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "command -v '$cmd' 2>/dev/null || true"
}


command_exists_as_user() {
  local cmd="$1"
  [[ -n "$(command_path_as_user "$cmd")" ]]
}


distrobox_container_exists_as_user() {
  local box="$1"
  sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "distrobox-list 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, \"\", \$2); print \$2}' | grep -qx '$box'"
}


first_existing_distrobox_for_amdgpu_top() {
  local box
  for box in amdtools amdgpu-tools fedora fedora-43 fedora-toolbox toolbox; do
    if command_exists_as_user distrobox && distrobox_container_exists_as_user "$box"; then
      if sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "distrobox-enter -n '$box' -- bash -lc 'command -v amdgpu_top >/dev/null 2>&1'" >/dev/null 2>&1; then
        echo "$box"
        return 0
      fi
    fi
  done
  return 1
}

safe_mkdirs() {
  mkdir -p "$CONFIG_DIR"
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local dst="$file.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$file" "$dst"
  ok "Backup created: $dst"
}

# ------------------------------------------------------------------------------
# System helpers
# ------------------------------------------------------------------------------

is_bazzite_like() {
  [[ -f /etc/os-release ]] && grep -Eqi 'bazzite|fedora|ublue' /etc/os-release
}

require_bazzite_atomic() {
  if ! is_bazzite_like; then
    warn "Bazzite/Fedora/uBlue not clearly detected in /etc/os-release."
    warn "Continuing, but verify that this is really the target system."
  fi

  if ! command_exists rpm-ostree; then
    die "rpm-ostree not found. This script is for Bazzite/Fedora Atomic, not Arch/CachyOS."
  fi
}

rpm_ostree_install_required() {
  require_bazzite_atomic
  info "rpm-ostree install: $*"

  if rpm-ostree install --idempotent --allow-inactive "$@"; then
    ok "Layer request completed."
    return 0
  fi

  err "rpm-ostree failed for: $*"
  return 1
}

rpm_ostree_install_optional() {
  require_bazzite_atomic
  info "rpm-ostree install optional: $*"

  if rpm-ostree install --idempotent --allow-inactive "$@"; then
    ok "Optional package installed/requested: $*"
    return 0
  fi

  warn "Optional package unavailable or failed: $*"
  return 0
}

kargs_current_words() {
  rpm-ostree kargs 2>/dev/null | tr ' ' '\n' || true
}

karg_delete_exact() {
  local arg="$1"
  [[ -n "$arg" ]] || return 0
  rpm-ostree kargs --delete="$arg" >/dev/null 2>&1 || true
}

karg_delete_key() {
  local key="$1"
  local arg
  while read -r arg; do
    [[ -n "$arg" ]] && karg_delete_exact "$arg"
  done < <(kargs_current_words | grep -E "^${key}(=|$)" || true)
}

karg_set_key_value() {
  local key="$1"
  local value="$2"
  karg_delete_key "$key"
  rpm-ostree kargs --append="${key}=${value}"
}

karg_append_if_missing() {
  local arg="$1"
  rpm-ostree kargs --append-if-missing="$arg"
}


kargs_collect_existing_for_keys() {
  local key arg
  for key in "$@"; do
    while read -r arg; do
      [[ -n "$arg" ]] && printf '%s\n' "$arg"
    done < <(kargs_current_words | grep -E "^${key}(=|$)" || true)
  done
}

kargs_apply_pairs_batched() {
  # Usage:
  #   kargs_apply_pairs_batched key=value key=value flag
  #
  # The function deletes any existing kargs with the same key, then appends
  # the requested values in a single rpm-ostree kargs transaction.
  require_bazzite_atomic

  local requested=("$@")
  local keys=()
  local item key current
  local cmd=(rpm-ostree kargs)

  for item in "${requested[@]}"; do
    if [[ "$item" == *=* ]]; then
      key="${item%%=*}"
    else
      key="$item"
    fi
    keys+=("$key")
  done

  while read -r current; do
    [[ -n "$current" ]] && cmd+=("--delete=${current}")
  done < <(kargs_collect_existing_for_keys "${keys[@]}" | sort -u)

  for item in "${requested[@]}"; do
    cmd+=("--append=${item}")
  done

  info "Applying kernel arguments in one rpm-ostree transaction:"
  printf '  %q' "${cmd[@]}"
  echo

  "${cmd[@]}"
}

apply_zswap_kargs_batched() {
  local percent="${1:-25}"
  kargs_apply_pairs_batched \
    "zswap.enabled=1" \
    "zswap.max_pool_percent=${percent}" \
    "zswap.compressor=lz4" \
    "systemd.zram=0"
}

apply_boot_noise_kargs_batched() {
  kargs_apply_pairs_batched "loglevel=0"
}

apply_boot_logo_kargs_batched() {
  # Restore Plymouth/Bazzite graphical boot: keep rhgb/quiet/splash and remove loglevel=0.
  karg_delete_key "loglevel"
  karg_append_if_missing "quiet"
  karg_append_if_missing "splash"
  karg_append_if_missing "rhgb"
}

apply_run_all_kargs_batched() {
  local percent="${1:-25}"
  kargs_apply_pairs_batched \
    "zswap.enabled=1" \
    "zswap.max_pool_percent=${percent}" \
    "zswap.compressor=lz4" \
    "systemd.zram=0" \
    "quiet" \
    "splash" \
    "rhgb"
  karg_delete_key "loglevel"
}

# ------------------------------------------------------------------------------
# COPR / GPU governor
# ------------------------------------------------------------------------------

enable_filippor_copr() {
  require_bazzite_atomic
  title "GPU Governor Repository"

  if ls /etc/yum.repos.d/*filippor*bazzite*.repo >/dev/null 2>&1 || \
     [[ -f /etc/yum.repos.d/_copr:copr.fedorainfracloud.org:filippor:bazzite.repo ]]; then
    ok "COPR filippor/bazzite already present."
    return 0
  fi

  if command_exists dnf5; then
    dnf5 -y copr enable filippor/bazzite
  elif command_exists dnf; then
    dnf -y copr enable filippor/bazzite
  elif command_exists copr; then
    yes y | copr enable filippor/bazzite
  else
    local fedora_ver repo_url repo_dst
    fedora_ver="$(rpm -E %fedora)"
    repo_url="https://copr.fedorainfracloud.org/coprs/filippor/bazzite/repo/fedora-${fedora_ver}/filippor-bazzite-fedora-${fedora_ver}.repo"
    repo_dst="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:filippor:bazzite.repo"

    if command_exists curl; then
      curl -fsSL "$repo_url" -o "$repo_dst"
    elif command_exists wget; then
      wget -O "$repo_dst" "$repo_url"
    else
      die "Need dnf/dnf5/copr or curl/wget to enable COPR automatically."
    fi
  fi

  rpm-ostree refresh-md || true
  ok "COPR filippor/bazzite ready."
}

disable_conflicting_gpu_governors() {
  title "GPU Governor Conflicts"
  local svc
  for svc in \
    cyan-skillfish-governor.service \
    cyan-skillfish-governor-tt.service \
    oberon-governor.service; do
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  done
  ok "Conflicting GPU governor services disabled if present."
}

install_gpu_governor() {
  title "GPU Governor"
  disable_conflicting_gpu_governors
  enable_filippor_copr
  rpm_ostree_install_required cyan-skillfish-governor-smu || return 1
  warn "If rpm-ostree created a new deployment, reboot before starting the service."
}

restart_gpu_governor_if_available() {
  systemctl daemon-reload >/dev/null 2>&1 || true

  if systemd_unit_exists cyan-skillfish-governor-smu.service; then
    info "Starting/restarting cyan-skillfish-governor-smu.service"
    systemctl enable --now cyan-skillfish-governor-smu.service >/dev/null 2>&1 || true
    systemctl restart cyan-skillfish-governor-smu.service || warn "Could not restart cyan-skillfish-governor-smu.service"
    systemctl status cyan-skillfish-governor-smu.service --no-pager || true
  else
    warn "cyan-skillfish-governor-smu.service is not available on this deployment yet."
    warn "If rpm-ostree just layered cyan-skillfish-governor-smu, reboot first."
  fi
}
write_gpu_config() {
  local profile="$1"
  local max_freq="$2"
  local throttle_temp="$3"
  local recover_temp="$4"
  local cpu_label="${5:-unchanged}"

  safe_mkdirs
  mkdir -p "$(dirname "$GPU_CONFIG")"
  backup_file "$GPU_CONFIG"

  cat > "$GPU_CONFIG" <<EOF_CONFIG
# Generated by ${APP_TITLE} ${VERSION}
# Profile: ${profile}
# Target: Bazzite / Fedora Atomic BC250
# Path: ${GPU_CONFIG}

[timing.intervals]
sample = 250
adjust = 100_000

[gpu-usage]
fix-metrics = true
method = "busy-flag"
flush-every = 10

[gpu]
set-method = "smu"

[frequency-range]
min = 500
max = ${max_freq}

[timing.ramp-rates]
normal = 1
burst = 50

[timing]
burst-samples = 60
down-events = 5

[frequency-thresholds]
adjust = 10

[load-target]
upper = 0.65
lower = 0.50

[temperature]
throttling = ${throttle_temp}
throttling_recovery = ${recover_temp}

[[safe-points]]
frequency = 500
voltage = 700

[[safe-points]]
frequency = 1000
voltage = 800

[[safe-points]]
frequency = 1175
voltage = 850

[[safe-points]]
frequency = 1500
voltage = 900

[[safe-points]]
frequency = 1600
voltage = 910

[[safe-points]]
frequency = 1700
voltage = 920

[[safe-points]]
frequency = 1850
voltage = 930

[[safe-points]]
frequency = 2000
voltage = 950

[[safe-points]]
frequency = 2100
voltage = 1000

[[safe-points]]
frequency = 2250
voltage = 1050

[[safe-points]]
frequency = 2300
voltage = 1075

[[safe-points]]
frequency = 2350
voltage = 1100

[[safe-points]]
frequency = 2400
voltage = 1125
EOF_CONFIG

  profile_state_write "$profile" "$cpu_label" "$max_freq" "$throttle_temp" "$recover_temp"

  ok "Profile written: ${profile} — GPU ${max_freq}MHz / max ${throttle_temp}°C"
}


profile_state_write() {
  local profile="${1:-Unknown}"
  local cpu_label="${2:-unchanged}"
  local gpu_max="${3:-?}"
  local gpu_throttle="${4:-?}"
  local gpu_recover="${5:-?}"

  safe_mkdirs
  cat > "$PROFILE_STATE" <<EOF_STATE
PROFILE="${profile}"
CPU_LABEL="${cpu_label}"
GPU_MAX_MHZ="${gpu_max}"
GPU_THROTTLE_C="${gpu_throttle}"
GPU_RECOVER_C="${gpu_recover}"
UPDATED_AT="$(date -Is)"
EOF_STATE
}

profile_state_update_cpu_label() {
  local cpu_label="$1"

  local profile="Unknown"
  local gpu_max="?"
  local gpu_throttle="?"
  local gpu_recover="?"

  if [[ -f "$PROFILE_STATE" ]]; then
    # shellcheck disable=SC1090
    source "$PROFILE_STATE" || true
    profile="${PROFILE:-$profile}"
    gpu_max="${GPU_MAX_MHZ:-$gpu_max}"
    gpu_throttle="${GPU_THROTTLE_C:-$gpu_throttle}"
    gpu_recover="${GPU_RECOVER_C:-$gpu_recover}"
  fi

  profile_state_write "$profile" "$cpu_label" "$gpu_max" "$gpu_throttle" "$gpu_recover"
}

cpu_service_state_label() {
  if systemctl is-active --quiet bc250-smu-oc.service 2>/dev/null; then
    echo "CPU service active"
  elif systemctl is-enabled --quiet bc250-smu-oc.service 2>/dev/null; then
    echo "CPU service enabled but not active"
  else
    echo "CPU service inactive"
  fi
}

print_gpu_config_summary() {
  if [[ ! -f "$GPU_CONFIG" ]]; then
    warn "GPU config not found at ${GPU_CONFIG}"
    return 0
  fi

  awk '
    /^\[frequency-range\]/ {section="frequency"; next}
    /^\[temperature\]/ {section="temperature"; next}
    /^\[/ {section=""}
    section=="frequency" && /^(min|max)[[:space:]]*=/ {print "  " $0}
    section=="temperature" && /^(throttling|throttling_recovery)[[:space:]]*=/ {print "  " $0}
  ' "$GPU_CONFIG"
}

print_cpu_config_summary() {
  local state
  state="$(cpu_service_state_label)"
  echo "  ${state}"

  if systemctl is-active --quiet bc250-smu-oc.service 2>/dev/null; then
    echo
    echo "  Service:"
    systemctl status bc250-smu-oc.service --no-pager 2>/dev/null | sed 's/^/    /' | head -25 || true
  fi

  echo
  echo "  Possible overclock.conf files:"
  local found=0 file

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    found=1
    echo "    ${file}"
    sed 's/^/      /' "$file" 2>/dev/null | head -20 || true
  done < <(
    find /etc /usr/local/etc /opt/bc250_smu_oc /var/roothome /root "$REAL_HOME" \
      -maxdepth 5 -name overclock.conf 2>/dev/null || true
  )

  if [[ "$found" == "0" ]]; then
    warn "No overclock.conf found in common locations."
  fi
}


cpu_current_clock_summary() {
  local dir cur sum count avg min max val
  dir="/sys/devices/system/cpu"
  sum=0
  count=0
  min=999999999
  max=0

  for cur in "$dir"/cpu[0-9]*/cpufreq/scaling_cur_freq; do
    [[ -r "$cur" ]] || continue
    val="$(cat "$cur" 2>/dev/null || echo 0)"
    [[ "$val" =~ ^[0-9]+$ ]] || continue
    sum=$((sum + val))
    count=$((count + 1))
    (( val < min )) && min=$val
    (( val > max )) && max=$val
  done

  if [[ "$count" -gt 0 ]]; then
    avg=$((sum / count / 1000))
    min=$((min / 1000))
    max=$((max / 1000))
    echo "${avg} MHz avg, ${min}-${max} MHz range"
  else
    echo "runtime clock unavailable"
  fi
}

latest_cpu_overclock_conf() {
  local file latest=""
  for file in \
    "$CPU_REPO_DIR/overclock.conf" \
    "/etc/bc250_smu_oc/overclock.conf" \
    "/usr/local/etc/bc250_smu_oc/overclock.conf" \
    "/opt/bc250_smu_oc/overclock.conf"; do
    [[ -f "$file" ]] && latest="$file"
  done
  [[ -n "$latest" ]] && echo "$latest"
}

parse_cpu_conf_line() {
  local conf="$1" freq scale temp
  [[ -f "$conf" ]] || return 1
  freq="$(awk -F'= *' '/^frequency/ {print $2; exit}' "$conf" 2>/dev/null | tr -d ' "' || true)"
  scale="$(awk -F'= *' '/^scale/ {print $2; exit}' "$conf" 2>/dev/null | tr -d ' "' || true)"
  temp="$(awk -F'= *' '/^(max_temperature|temperature)/ {print $2; exit}' "$conf" 2>/dev/null | tr -d ' "' || true)"
  [[ -n "$freq" ]] || return 1
  echo "${freq}MHz${scale:+, scale ${scale}}${temp:+, max ${temp}°C}"
}

cpu_runtime_line() {
  local svc conf parsed clock
  svc="$(cpu_service_state_label)"
  clock="$(cpu_current_clock_summary)"
  conf="$(latest_cpu_overclock_conf || true)"

  if systemctl is-active --quiet bc250-smu-oc.service 2>/dev/null; then
    if [[ -n "$conf" ]] && parsed="$(parse_cpu_conf_line "$conf" 2>/dev/null)"; then
      echo "OC service active (${parsed}); runtime ${clock}"
    else
      echo "OC service active; runtime ${clock}"
    fi
  elif systemctl is-enabled --quiet bc250-smu-oc.service 2>/dev/null; then
    if [[ -n "$conf" ]] && parsed="$(parse_cpu_conf_line "$conf" 2>/dev/null)"; then
      echo "OC service enabled but inactive (${parsed}); runtime ${clock}"
    else
      echo "OC service enabled but inactive; runtime ${clock}"
    fi
  else
    if [[ -n "$conf" ]] && parsed="$(parse_cpu_conf_line "$conf" 2>/dev/null)"; then
      echo "no boot CPU OC service; runtime ${clock}; last test file: ${parsed}"
    else
      echo "no boot CPU OC service; runtime ${clock}"
    fi
  fi
}

gpu_runtime_line() {
  local svc="inactive" max="?" throttle="?" recover="?"
  if systemctl is-active --quiet cyan-skillfish-governor-smu.service 2>/dev/null; then
    svc="active"
  elif systemctl is-enabled --quiet cyan-skillfish-governor-smu.service 2>/dev/null; then
    svc="enabled but inactive"
  fi

  if [[ -f "$GPU_CONFIG" ]]; then
    max="$(awk '/^\[frequency-range\]/{s=1;next} /^\[/{s=0} s && /^max[[:space:]]*=/{print $3; exit}' "$GPU_CONFIG" 2>/dev/null || echo '?')"
    throttle="$(awk '/^\[temperature\]/{s=1;next} /^\[/{s=0} s && /^throttling[[:space:]]*=/{print $3; exit}' "$GPU_CONFIG" 2>/dev/null || echo '?')"
    recover="$(awk '/^\[temperature\]/{s=1;next} /^\[/{s=0} s && /^throttling_recovery[[:space:]]*=/{print $3; exit}' "$GPU_CONFIG" 2>/dev/null || echo '?')"
  fi

  echo "${svc}; max ${max}MHz; throttle ${throttle}°C; recovery ${recover}°C"
}

active_profile_line() {
  echo "CPU: $(cpu_runtime_line)"
  echo "GPU: $(gpu_runtime_line)"
}

edit_root_file_safely() {
  local target="$1"
  local label="${2:-configuration file}"

  mkdir -p "$(dirname "$target")"
  touch "$target"

  local tmp editor before after uid xdg_runtime dbus_addr
  tmp="$(mktemp "/tmp/bc250-edit-${REAL_USER}-XXXXXX.toml")"
  cp -a "$target" "$tmp"
  chown "$REAL_USER":"$REAL_USER" "$tmp" 2>/dev/null || true
  chmod 600 "$tmp" 2>/dev/null || true

  before="$(sha256sum "$tmp" | awk '{print $1}')"

  if command_exists_as_user kate; then
    editor="kate"
  elif command_exists_as_user kwrite; then
    editor="kwrite"
  elif command_exists_as_user nano; then
    editor="nano"
  elif command_exists_as_user vi; then
    editor="vi"
  elif command_exists nano; then
    editor="nano"
  elif command_exists vi; then
    editor="vi"
  else
    rm -f "$tmp"
    die "No editor found. Install nano, Kate or KWrite."
  fi

  info "Opening temporary copy of ${target} with ${editor}"
  echo "Temp file: ${tmp}"
  echo
  warn "Do not edit ${target} directly as root with Kate."
  warn "The toolkit will copy the edited file back with root permissions after you close the editor."
  echo

  uid="$(id -u "$REAL_USER" 2>/dev/null || echo 1000)"
  xdg_runtime="/run/user/${uid}"
  dbus_addr="unix:path=${xdg_runtime}/bus"

  case "$editor" in
    kate|kwrite)
      sudo -u "$REAL_USER" \
        env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" DISPLAY="${DISPLAY:-}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" XDG_RUNTIME_DIR="$xdg_runtime" DBUS_SESSION_BUS_ADDRESS="$dbus_addr" \
        "$editor" --block "$tmp" || warn "${editor} returned a non-zero status."
      ;;
    nano|vi)
      if [[ "$editor" == "nano" || "$editor" == "vi" ]]; then
        sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" "$editor" "$tmp"
      fi
      ;;
  esac

  after="$(sha256sum "$tmp" | awk '{print $1}')"

  if [[ "$before" == "$after" ]]; then
    warn "No changes detected. Keeping current ${label}."
    rm -f "$tmp"
    return 0
  fi

  echo
  if confirm "Install edited ${label} to ${target}?"; then
    cp -a "$target" "${target}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    install -m 0644 -o root -g root "$tmp" "$target"
    ok "Updated ${target}"
  else
    warn "Discarded edited copy. Current ${target} unchanged."
  fi

  rm -f "$tmp"
}


edit_gpu_config() {
  title "Edit GPU Config"
  mkdir -p "$(dirname "$GPU_CONFIG")"
  [[ -f "$GPU_CONFIG" ]] || write_gpu_config "Strong" 1850 80 75

  edit_root_file_safely "$GPU_CONFIG" "GPU governor config"

  echo
  if systemctl list-unit-files | grep -q '^cyan-skillfish-governor-smu.service'; then
    if confirm "Restart cyan-skillfish-governor-smu now?"; then
      systemctl restart cyan-skillfish-governor-smu.service || warn "Could not restart cyan-skillfish-governor-smu.service"
      systemctl status cyan-skillfish-governor-smu.service --no-pager || true
    fi
  else
    warn "cyan-skillfish-governor-smu.service is not visible yet. Reboot first if the package was just layered."
  fi
}


run_bc250_detect_with_compatible_temp_arg() {
  local freq="$1"
  local vid="$2"
  local temp="$3"
  local rc

  set +e
  bc250-detect --frequency "$freq" --vid "$vid" --temp "$temp"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bc250-detect --frequency "$freq" --vid "$vid" --temperature "$temp"
    rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    warn "bc250-detect did not accept a temperature argument on this version. Retrying without temp argument."
    bc250-detect --frequency "$freq" --vid "$vid"
    rc=$?
  fi
  set -e

  return "$rc"
}


apply_cpu_target_from_profile() {
  local profile="$1"
  local cpu_freq="$2"
  local cpu_vid="$3"
  local cpu_temp="$4"

  [[ "$cpu_freq" == "unchanged" || "$cpu_freq" == "0" ]] && return 0

  echo
  title "CPU Profile"
  echo "Requested CPU target:"
  echo "  Profile:      ${profile}"
  echo "  Frequency:    ${cpu_freq} MHz"
  echo "  VID:          ${cpu_vid} mV"
  echo "  Max temp:     ${cpu_temp} °C"
  echo
  warn "CPU profile application runs bc250-detect, including its stress/throttling test."
  warn "The final applied value may be lower than the requested target if throttling is detected."
  echo

  if ! command_exists bc250-detect || ! command_exists bc250-apply; then
    warn "bc250-detect / bc250-apply are not available yet."
    warn "Install CPU Governor first, then reboot if rpm-ostree stages a new deployment."
    echo
    profile_state_update_cpu_label "${cpu_freq}MHz requested, not tested"
    if confirm "Request CPU Governor dependencies now?"; then
      install_cpu_governor_deps || true
    fi
    return 0
  fi

  if ! confirm "Run bc250-detect for CPU ${cpu_freq} MHz now?"; then
    profile_state_update_cpu_label "${cpu_freq}MHz requested, not tested"
    return 0
  fi

  mkdir -p "$CPU_REPO_DIR"
  cd "$CPU_REPO_DIR"

  if run_bc250_detect_with_compatible_temp_arg "$cpu_freq" "$cpu_vid" "$cpu_temp"; then
    ok "bc250-detect completed."
  else
    warn "bc250-detect reported failure, crash prevention, or throttling."
  fi

  if [[ -f overclock.conf ]]; then
    echo
    title "Generated CPU Config"
    cat overclock.conf || true
    echo

    local generated_freq generated_scale generated_temp
    generated_freq="$(awk -F'= *' '/^frequency/ {print $2; exit}' overclock.conf 2>/dev/null || true)"
    generated_scale="$(awk -F'= *' '/^scale/ {print $2; exit}' overclock.conf 2>/dev/null || true)"
    generated_temp="$(awk -F'= *' '/^max_temperature/ {print $2; exit}' overclock.conf 2>/dev/null || true)"

    if confirm "Install this CPU overclock.conf at boot?"; then
      bc250-apply --install overclock.conf
      systemctl enable bc250-smu-oc.service || true
      profile_state_update_cpu_label "${generated_freq:-?}MHz installed, scale ${generated_scale:-?}, max ${generated_temp:-?}°C"
      ok "CPU profile installed through bc250-smu-oc.service."
    else
      profile_state_update_cpu_label "${generated_freq:-?}MHz detected, not installed"
      warn "CPU profile was tested but not installed at boot."
    fi
  else
    profile_state_update_cpu_label "${cpu_freq}MHz requested, no config generated"
    warn "No overclock.conf generated."
  fi
}


apply_full_performance_profile() {
  local profile="$1"
  local cpu_freq="$2"
  local cpu_vid="$3"
  local gpu_freq="$4"
  local temp="$5"
  local recover="$6"

  local cpu_label
  if [[ "$cpu_freq" == "unchanged" || "$cpu_freq" == "0" ]]; then
    cpu_label="unchanged"
  else
    cpu_label="${cpu_freq}MHz requested"
  fi

  write_gpu_config "$profile" "$gpu_freq" "$temp" "$recover" "$cpu_label"
  restart_gpu_governor_if_available
  apply_cpu_target_from_profile "$profile" "$cpu_freq" "$cpu_vid" "$temp"
}


cpu_test_menu() {
  while true; do
    banner
    title "CPU testing and apply"
    echo "Current CPU status: $(cpu_runtime_line)"
    echo
    echo "Workflow:"
    echo "  1. Run bc250-detect without -k to discover a stable point."
    echo "  2. Read the final result. If it throttles or falls back, do not keep it."
    echo "  3. Only after a clean pass, install the generated overclock.conf at boot."
    echo
    warn "Do not use -k while searching for limits. Use it only for a known-good setting."
    echo
    menu_item "T" "Test CPU"      "Run bc250-detect; restore defaults after test"
    menu_item "K" "Test + keep"   "Run bc250-detect -k for this session only"
    menu_item "A" "Apply config"  "Install an existing overclock.conf at boot"
    menu_item "S" "Status"        "Show CPU service and config files"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      [Tt]|[Kk])
        local cpu_mhz cpu_vid temp keep_arg
        echo
        echo "Suggested starting points from this machine's tests:"
        echo "  Daily-safe candidate: 3650 MHz, VID 1160 mV, temp 90°C"
        echo "  Performance candidate: 3700 MHz, VID 1180 mV, temp 95°C only"
        echo "  3775/3800/4000 were observed throttling with current cooling."
        echo
        read -r -p "CPU target MHz [3650]: " cpu_mhz
        cpu_mhz="${cpu_mhz:-3650}"
        read -r -p "CPU VID mV [1160]: " cpu_vid
        cpu_vid="${cpu_vid:-1160}"
        read -r -p "Max temp °C [90]: " temp
        temp="${temp:-90}"
        if ! [[ "$cpu_mhz" =~ ^[0-9]+$ && "$cpu_vid" =~ ^[0-9]+$ && "$temp" =~ ^[0-9]+$ ]]; then
          warn "Invalid values."
          pause
          continue
        fi
        mkdir -p "$CPU_REPO_DIR"
        cd "$CPU_REPO_DIR"
        keep_arg=""
        if [[ "$choice" =~ ^[Kk]$ ]]; then
          keep_arg="-k"
          warn "This will keep the CPU OC active until reboot or until defaults are restored."
        fi
        warn "This can throttle, crash, freeze, or overheat an unstable board."
        confirm "Run: bc250-detect -f ${cpu_mhz} -v ${cpu_vid} -t ${temp} ${keep_arg}?" || continue
        # Stop GPU governor only if requested by the user; do not alter silently.
        bc250-detect -f "$cpu_mhz" -v "$cpu_vid" -t "$temp" ${keep_arg} || warn "bc250-detect reported failure or throttling."
        if [[ -f overclock.conf ]]; then
          echo
          title "Generated overclock.conf"
          cat overclock.conf || true
          echo
          warn "Install at boot only if the final result is the frequency you wanted and no throttling was reported."
          if confirm "Install this CPU overclock.conf at boot now?"; then
            bc250-apply --install overclock.conf
            systemctl enable --now bc250-smu-oc.service || true
            profile_state_update_cpu_label "$(parse_cpu_conf_line overclock.conf 2>/dev/null || echo installed)"
            ok "CPU overclock service installed/enabled."
          fi
        fi
        pause
        ;;
      [Aa]) apply_existing_cpu_config; pause ;;
      [Ss]) print_cpu_config_summary; pause ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

gpu_test_menu() {
  while true; do
    banner
    title "GPU governor testing and apply"
    echo "Current GPU status: $(gpu_runtime_line)"
    echo
    echo "Workflow:"
    echo "  1. Choose a conservative max clock."
    echo "  2. Apply the governor config and restart the service."
    echo "  3. Test in game/benchmark while monitoring clocks, power and temperatures."
    echo "  4. Increase step by step only if stable."
    echo
    warn "There is no automatic GPU stress validation here. You must test after applying."
    echo
    menu_item "T" "Set test config" "Write GPU max/throttle/recovery and restart service"
    menu_item "E" "Edit config"     "Manual editor for advanced users"
    menu_item "S" "Service"         "Start/stop/restart GPU governor"
    menu_item "M" "Monitoring"      "Open monitoring tools"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      [Tt])
        local gpu_mhz temp rec
        echo
        echo "Suggested test path: 1850 -> 1900 -> 1950 -> 2000 MHz."
        echo "For daily use, prefer throttle around 82-85°C and recovery around 76-78°C."
        echo
        read -r -p "GPU max MHz [1900]: " gpu_mhz
        gpu_mhz="${gpu_mhz:-1900}"
        read -r -p "Throttle temperature °C [85]: " temp
        temp="${temp:-85}"
        read -r -p "Recovery temperature °C [78]: " rec
        rec="${rec:-78}"
        if ! [[ "$gpu_mhz" =~ ^[0-9]+$ && "$temp" =~ ^[0-9]+$ && "$rec" =~ ^[0-9]+$ ]]; then
          warn "Invalid values."
          pause
          continue
        fi
        write_gpu_config "GPU-Test-${gpu_mhz}MHz" "$gpu_mhz" "$temp" "$rec" "not touched"
        restart_gpu_governor_if_available
        echo
        echo "Recommended monitoring command:"
        echo "  watch -n 1 'cat /sys/class/drm/card*/device/pp_dpm_sclk 2>/dev/null; sensors | grep -Ei \"amdgpu|edge|junction|PPT|Tctl|VRM|Pump|fan\"'"
        pause
        ;;
      [Ee]) edit_gpu_config; pause ;;
      [Ss]) gpu_service_menu ;;
      [Mm]) monitoring_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

custom_oc_documented_menu() {
  banner
  title "Custom CPU/GPU OC — documentation"
  cat <<'EOF_CUSTOM_OC'
Recommended method:

  CPU:
    - Use CPU testing first.
    - Do not use -k while searching for a limit.
    - A good test produces Final Result at the requested frequency with no throttling.
    - If the final result falls back to a lower MHz, do not install it.

  GPU:
    - The governor applies a max clock and safe-points.
    - It does not prove stability by itself.
    - Test in a real game/benchmark and watch GPU clocks, temps and power.

  40 CU:
    - Enable live first with bc250-cu-live-manager.
    - Save at boot only after stability testing.

Observed on this machine during tuning:

  CPU daily candidate:       3650 MHz / VID 1160 / 90°C target
  CPU performance candidate: 3700 MHz / VID 1180 / 95°C target
  CPU failed/throttled area: 3775+ MHz with current cooling

  GPU test path:             1850 -> 1900 -> 1950 -> 2000 MHz
  GPU daily temps:           throttle 82-85°C, recovery 76-78°C
EOF_CUSTOM_OC
  echo
  if confirm "Open CPU testing menu now?"; then
    cpu_test_menu
  elif confirm "Open GPU testing menu now?"; then
    gpu_test_menu
  fi
}

performance_profiles_menu() {
  while true; do
    banner
    title "Performance testing menu"
    echo -e "${DIM}Current state:${RESET}"
    active_profile_line | sed 's/^/  /'
    echo

    section "Safe workflow"
    echo "This menu intentionally avoids one-click OC presets."
    echo "Test CPU and GPU separately, validate temperatures, then apply only known-good settings."
    echo
    menu_item "1" "CPU tests"      "Run bc250-detect, review result, optionally install at boot"
    menu_item "2" "GPU tests"      "Set GPU governor test config, then validate in game/benchmark"
    menu_item "3" "Custom guide"   "Documented manual OC workflow and known-good starting points"
    echo

    section "Tools"
    menu_item "4" "CPU status"     "Show CPU OC service and overclock.conf files"
    menu_item "5" "GPU service"    "Start/stop/restart cyan-skillfish-governor-smu"
    menu_item "6" "Monitoring"     "Open sensors, GPU sysfs, amdgpu_top if available"
    menu_item "0" "Back to Main Menu"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) cpu_test_menu ;;
      2) gpu_test_menu ;;
      3) custom_oc_documented_menu; pause ;;
      4) print_cpu_config_summary; pause ;;
      5) gpu_service_menu ;;
      6) monitoring_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Swap / zswap
# ------------------------------------------------------------------------------

normalize_size_gib() {
  local raw="${1:-16G}"
  raw="${raw// /}"
  raw="${raw^^}"

  if [[ "$raw" =~ ^([0-9]+)G$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+)GB$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+)GI$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+)GIB$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$raw" =~ ^([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    die "Invalid size: ${raw}. Expected examples: 16G, 32G, 48G."
  fi
}

calc_zswap_percent_for_target() {
  local target_gib="$1"
  local mem_kib mem_gib percent

  mem_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_gib="$(( (mem_kib + 1048575) / 1048576 ))"
  [[ "$mem_gib" -gt 0 ]] || mem_gib=1

  percent="$(( (target_gib * 100 + mem_gib - 1) / mem_gib ))"

  # zswap is RAM-backed. Above 50% can starve games and the desktop.
  if [[ "$percent" -gt 50 ]]; then
    percent=50
  fi
  if [[ "$percent" -lt 10 ]]; then
    percent=10
  fi

  echo "$percent"
}


configure_swap_zswap() {
  local size="${1:-32G}"
  local zswap_target="${2:-auto}"
  local apply_kernel_args="${3:-yes}"

  title "Enable Swap / ZSWAP"

  local size_gib zswap_percent
  size_gib="$(normalize_size_gib "$size")"
  size="${size_gib}G"

  if [[ "$zswap_target" == "auto" || -z "$zswap_target" ]]; then
    zswap_percent="25"
  else
    local zswap_target_gib
    zswap_target_gib="$(normalize_size_gib "$zswap_target")"
    zswap_percent="$(calc_zswap_percent_for_target "$zswap_target_gib")"
  fi

  echo "Requested configuration:"
  echo "  Swapfile:              ${size}"
  echo "  zswap.max_pool_percent ${zswap_percent}% of physical RAM"
  echo "  kernel args:           ${apply_kernel_args}"
  echo
  warn "zswap is not a 32G file. It is a compressed RAM cache."
  warn "The real backing storage is the ${size} swapfile."
  echo

  confirm "Create/recreate ${SWAPFILE} and apply swap settings?" || return 0

  swapoff "$SWAPFILE" >/dev/null 2>&1 || true
  rm -f "$SWAPFILE" >/dev/null 2>&1 || true

  if [[ -d /var/swap ]]; then
    btrfs subvolume delete /var/swap >/dev/null 2>&1 || rm -rf /var/swap
  fi

  if findmnt -no FSTYPE /var 2>/dev/null | grep -q '^btrfs$' || findmnt -no FSTYPE / 2>/dev/null | grep -q '^btrfs$'; then
    btrfs subvolume create /var/swap || mkdir -p /var/swap

    if ! btrfs filesystem mkswapfile --size "$size" "$SWAPFILE"; then
      warn "btrfs filesystem mkswapfile failed; using fallback allocation."
      truncate -s 0 "$SWAPFILE"
      chattr +C "$SWAPFILE" 2>/dev/null || true
      fallocate -l "$size" "$SWAPFILE"
      chmod 600 "$SWAPFILE"
      mkswap "$SWAPFILE"
    fi
  else
    mkdir -p /var/swap
    truncate -s 0 "$SWAPFILE"
    fallocate -l "$size" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
  fi

  chmod 600 "$SWAPFILE"

  if command_exists semanage; then
    semanage fcontext -a -t var_t '/var/swap(/.*)?' 2>/dev/null || true
    semanage fcontext -a -t swapfile_t "$SWAPFILE" 2>/dev/null || true
  fi
  restorecon -Rv /var/swap >/dev/null 2>&1 || true

  sed -i '\# /var/swap/swapfile #d; /\/var\/swap\/swapfile/d' /etc/fstab
  echo "$SWAPFILE none swap defaults,nofail 0 0" >> /etc/fstab

  echo 'vm.swappiness = 180' > /etc/sysctl.d/99-bc250-swappiness.conf
  # NexGen compatibility: keep zram-generator disabled even before kernel args are applied.
  : > /etc/systemd/zram-generator.conf
  sysctl -q -w vm.swappiness=180 || true
  swapon "$SWAPFILE"

  if [[ "$apply_kernel_args" == "yes" ]]; then
    apply_zswap_kargs_batched "$zswap_percent"
    rpm-ostree initramfs --enable --arg=--add-drivers --arg=lz4 || warn "initramfs lz4 option was not applied automatically."
  else
    info "Skipping zswap kernel args here; they will be applied by the parent workflow."
  fi

  ok "Swap/ZSWAP configured. Reboot required for all kernel args to take effect."
  echo
  swapon --show || true
}

swap_menu() {
  while true; do
    banner
    title "Enable Swap / ZSWAP"
    menu_item "1" "Recommended" "32G Btrfs swapfile, swappiness=180, zswap=25%"
    menu_item "2" "Legacy"      "16G Btrfs swapfile, swappiness=180, zswap=25%"
    menu_item "3" "Advanced"    "Custom swapfile size and zswap target"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) configure_swap_zswap "32G" "auto"; pause ;;
      2) configure_swap_zswap "16G" "auto"; pause ;;
      3)
        local size ztarget
        read -r -p "Swapfile size [32G]: " size
        echo
        warn "The zswap target is converted to a percentage of physical RAM and capped at 50%."
        read -r -p "Indicative zswap target [auto]: " ztarget
        configure_swap_zswap "${size:-32G}" "${ztarget:-auto}"
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Kernel args
# ------------------------------------------------------------------------------


kernel_args_menu() {
  while true; do
    banner
    title "Kernel Arguments / Boot Display"
    menu_item "1" "Boot logo"       "Restore Bazzite/Plymouth: remove loglevel=0, add quiet splash rhgb"
    menu_item "2" "Hide Warning"     "Legacy: set loglevel=0, may hide the Bazzite logo"
    menu_item "3" "Disable Mitigations" "Add mitigations=off"
    menu_item "4" "ZRAM -> ZSWAP"    "Disable ZRAM, enable ZSWAP with lz4"
    menu_item "5" "Show Current"     "Display active configured kernel arguments"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1)
        apply_boot_logo_kargs_batched
        warn "Reboot required. Suggested command: systemctl reboot"
        pause
        ;;
      2)
        warn "This can make boot almost black and hide the Bazzite logo."
        confirm "Apply legacy loglevel=0 anyway?" || continue
        apply_boot_noise_kargs_batched
        warn "Reboot required."
        pause
        ;;
      3)
        confirm "mitigations=off can reduce CPU security protections. Continue?" || continue
        karg_append_if_missing "mitigations=off"
        warn "Reboot required."
        pause
        ;;
      4)
        apply_zswap_kargs_batched "25"
        warn "Reboot required."
        pause
        ;;
      5)
        rpm-ostree kargs || true
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# CPU governor
# ------------------------------------------------------------------------------

install_cpu_governor_deps() {
  title "CPU Governor Dependencies"

  # Correction importante:
  # Fedora/Bazzite package name is "pipx", not "python3-pipx".
  rpm_ostree_install_required git pipx || return 1

  # stress est utile pour bc250-detect. Si le paquet n'est pas disponible sur une
  # On some variants the package may be missing; do not block the whole toolkit.
  rpm_ostree_install_optional stress

  warn "If rpm-ostree staged a new deployment, reboot before running pipx/bc250_smu_oc steps."
}

install_cpu_governor() {
  title "CPU Governor"

  if ! command_exists git || ! command_exists pipx; then
    warn "git and/or pipx are missing on the current deployment."
    warn "I will request the correct Bazzite/Fedora packages now: git pipx"
    echo
    install_cpu_governor_deps || return 0
    echo
    warn "Important: with rpm-ostree, new host packages usually become available after reboot."
    warn "After reboot, run this script again and choose:"
    echo "  [ 3] Additional Tools -> [ 1] CPU Governor -> [ 2] Install/Update"
    return 0
  fi

  if [[ -d "$CPU_REPO_DIR/.git" ]]; then
    git -C "$CPU_REPO_DIR" pull --ff-only || true
  else
    rm -rf "$CPU_REPO_DIR"
    git clone "$CPU_REPO" "$CPU_REPO_DIR"
  fi

  pipx install --force "$CPU_REPO_DIR"

  mkdir -p /usr/local/bin
  for bin in bc250-detect bc250-apply; do
    local target=""
    if [[ -x "/var/roothome/.local/bin/$bin" ]]; then
      target="/var/roothome/.local/bin/$bin"
    elif [[ -x "/root/.local/bin/$bin" ]]; then
      target="/root/.local/bin/$bin"
    fi

    if [[ -n "$target" ]]; then
      cat > "/usr/local/bin/$bin" <<EOF_CPU_WRAPPER
#!/usr/bin/env bash
exec sudo "$target" "\$@"
EOF_CPU_WRAPPER
      chmod 755 "/usr/local/bin/$bin"
      chown root:root "/usr/local/bin/$bin" 2>/dev/null || true
      ok "Installed wrapper /usr/local/bin/$bin -> $target"
    else
      warn "pipx binary not found for $bin. Check: /var/roothome/.local/bin and /root/.local/bin"
    fi
  done

  ok "bc250_smu_oc installed via root pipx."
}

find_cpu_config() {
  local candidate
  for candidate in \
    "$PWD/overclock.conf" \
    "$CPU_REPO_DIR/overclock.conf" \
    "$REAL_HOME/bc250_smu_oc/overclock.conf" \
    "/var/home/$REAL_USER/bc250_smu_oc/overclock.conf"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

apply_existing_cpu_config() {
  title "Apply Existing CPU Config"

  if ! command_exists bc250-apply; then
    warn "bc250-apply not found. Install CPU Governor first."
    return 0
  fi

  local conf
  conf="$(find_cpu_config || true)"

  if [[ -z "$conf" ]]; then
    warn "No overclock.conf found."
    warn "Run bc250-detect first or place overclock.conf in the current directory."
    return 0
  fi

  info "Config found: $conf"
  cat "$conf" || true
  echo

  confirm "Install this CPU config as bc250-smu-oc system service?" || return 0
  bc250-apply --install "$conf"
  systemctl enable bc250-smu-oc.service || true
  ok "CPU config installed."
}

run_cpu_detect_interactive() {
  title "CPU Detect"

  if ! command_exists bc250-detect; then
    warn "bc250-detect not found. Install CPU Governor first."
    return 0
  fi

  local freq vid temp
  read -r -p "CPU target frequency MHz [3500]: " freq
  read -r -p "VID mV [1106]: " vid
  read -r -p "Max temp °C [90]: " temp

  freq="${freq:-3500}"
  vid="${vid:-1106}"
  temp="${temp:-90}"

  if ! [[ "$freq" =~ ^[0-9]+$ && "$vid" =~ ^[0-9]+$ && "$temp" =~ ^[0-9]+$ ]]; then
    warn "Invalid values."
    return 0
  fi

  mkdir -p "$CPU_REPO_DIR"
  cd "$CPU_REPO_DIR"

  warn "This test can throttle, crash, or reset unstable settings."
  confirm "Run bc250-detect now?" || return 0

  bc250-detect --frequency "$freq" --vid "$vid" --temp "$temp" || warn "bc250-detect reported failure or throttling."

  if [[ -f overclock.conf ]]; then
    echo
    cat overclock.conf
    echo
    if confirm "Install this overclock.conf at boot?"; then
      bc250-apply --install overclock.conf
      systemctl enable bc250-smu-oc.service || true
      ok "CPU service installed."
    fi
  fi
}

cpu_governor_menu() {
  while true; do
    banner
    title "CPU Governor"
    menu_item "1" "Dependencies"    "Layer git, pipx and optional stress with rpm-ostree"
    menu_item "2" "Install/Update"   "Install bc250_smu_oc with pipx"
    menu_item "3" "Apply Config"     "Apply existing overclock.conf"
    menu_item "4" "Detect"           "Run bc250-detect interactively"
    menu_item "5" "Service Status"   "Show bc250-smu-oc systemd status"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) install_cpu_governor_deps; pause ;;
      2) install_cpu_governor; pause ;;
      3) apply_existing_cpu_config; pause ;;
      4) run_cpu_detect_interactive; pause ;;
      5) systemctl status bc250-smu-oc.service --no-pager || true; pause ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

setup_cpu_governor_quick() {
  title "CPU Governor"
  install_cpu_governor_deps || return 0

  if command_exists pipx && command_exists git; then
    install_cpu_governor || true
  else
    warn "pipx/git will be available after reboot if rpm-ostree created a new deployment."
  fi
}

# ------------------------------------------------------------------------------
# Services / additional tools
# ------------------------------------------------------------------------------

gpu_service_menu() {
  while true; do
    banner
    title "GPU Governor Service"
    menu_item "1" "Start"        "Start cyan-skillfish-governor-smu now"
    menu_item "2" "Stop"         "Stop cyan-skillfish-governor-smu now"
    menu_item "3" "Enable"       "Enable and start at boot"
    menu_item "4" "Disable"      "Disable and stop"
    menu_item "5" "Restart"      "Restart service"
    menu_item "6" "Live Journal" "journalctl -u cyan-skillfish-governor-smu -f"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) systemctl start cyan-skillfish-governor-smu.service ;;
      2) systemctl stop cyan-skillfish-governor-smu.service ;;
      3) systemctl enable --now cyan-skillfish-governor-smu.service ;;
      4) systemctl disable --now cyan-skillfish-governor-smu.service ;;
      5) systemctl restart cyan-skillfish-governor-smu.service ;;
      6) journalctl -u cyan-skillfish-governor-smu.service -f ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause; continue ;;
    esac

    systemctl status cyan-skillfish-governor-smu.service --no-pager || true
    pause
  done
}

terminal_launcher_command() {
  if command_exists konsole; then
    echo "konsole"
  elif command_exists kgx; then
    echo "kgx"
  elif command_exists gnome-terminal; then
    echo "gnome-terminal"
  elif command_exists xterm; then
    echo "xterm"
  elif command_exists kitty; then
    echo "kitty"
  elif command_exists alacritty; then
    echo "alacritty"
  elif command_exists foot; then
    echo "foot"
  else
    echo ""
  fi
}




run_terminal_as_user() {
  local title="$1"
  local command_body="$2"
  local hold="${3:-auto}"

  local uid xdg_runtime dbus_addr term
  uid="$(id -u "$REAL_USER" 2>/dev/null || echo 1000)"
  xdg_runtime="/run/user/${uid}"
  dbus_addr="unix:path=${xdg_runtime}/bus"
  term="$(terminal_launcher_command)"

  if [[ -z "$term" ]]; then
    warn "No supported terminal emulator found."
    echo
    echo "Command to run manually:"
    echo "$command_body"
    return 1
  fi

  local cmd_script launcher_script log_file
  cmd_script="$(mktemp "/tmp/bc250-monitor-cmd-${REAL_USER}-XXXXXX.sh")"
  launcher_script="$(mktemp "/tmp/bc250-monitor-launch-${REAL_USER}-XXXXXX.sh")"
  log_file="/tmp/bc250-monitor-${REAL_USER}.log"

  cat > "$cmd_script" <<EOF_CMD_HEADER
#!/usr/bin/env bash
set +e
export HOME="${REAL_HOME}"
export PATH="$(toolkit_user_path)"
clear 2>/dev/null || true
EOF_CMD_HEADER

  {
    printf 'printf "\\033]0;%s\\007"\n' "$title"
    printf 'echo "=== %s ==="\n' "$title"
    printf 'echo "Started: $(date)"\n'
    printf 'echo\n'
    printf '%s\n' "$command_body"
    printf '\n'
    printf 'rc=$?\n'
    printf 'echo\n'
    printf 'echo "Command exited with code: $rc"\n'
    printf 'echo "Finished: $(date)"\n'
    printf 'echo\n'
    printf 'if [[ "%s" == "1" || "%s" == "auto" || "$rc" -ne 0 ]]; then\n' "$hold" "$hold"
    printf '  read -r -p "Press Enter to close..." _\n'
    printf 'fi\n'
    printf 'exit "$rc"\n'
  } >> "$cmd_script"

  chmod +x "$cmd_script"
  chown "$REAL_USER":"$REAL_USER" "$cmd_script" 2>/dev/null || true

  cat > "$launcher_script" <<EOF_LAUNCHER
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}"
export XDG_RUNTIME_DIR="${xdg_runtime}"
export DBUS_SESSION_BUS_ADDRESS="${dbus_addr}"
export HOME="${REAL_HOME}"
export PATH="$(toolkit_user_path)"
cd "${REAL_HOME}" 2>/dev/null || true

{
  echo "[$(date)] Launching: ${title}"
  echo "Terminal: ${term}"
  echo "Command script: ${cmd_script}"
  echo
} >> "${log_file}" 2>&1

case "${term}" in
  konsole)
    exec konsole --nofork --title "${title}" -e bash "${cmd_script}"
    ;;
  kgx)
    exec kgx --title "${title}" -- bash "${cmd_script}"
    ;;
  gnome-terminal)
    exec gnome-terminal --title="${title}" -- bash "${cmd_script}"
    ;;
  xterm)
    exec xterm -hold -T "${title}" -e bash "${cmd_script}"
    ;;
  kitty)
    exec kitty --title "${title}" bash "${cmd_script}"
    ;;
  alacritty)
    exec alacritty --title "${title}" -e bash "${cmd_script}"
    ;;
  foot)
    exec foot --title "${title}" bash "${cmd_script}"
    ;;
esac
EOF_LAUNCHER

  chmod +x "$launcher_script"
  chown "$REAL_USER":"$REAL_USER" "$launcher_script" 2>/dev/null || true

  (
    nohup setsid sudo -u "$REAL_USER" "$launcher_script" >>"$log_file" 2>&1 &
    sleep 60
    rm -f "$launcher_script"
    sleep 600
    rm -f "$cmd_script"
  ) >/dev/null 2>&1 &

  disown 2>/dev/null || true
  ok "Opened detached terminal window: ${title}"
  echo -e "${DIM}Debug log: ${log_file}${RESET}"
}




launch_amdgpu_top() {
  local user_path root_path box quoted_path

  user_path="$(command_path_as_user amdgpu_top || true)"
  if [[ -n "$user_path" ]]; then
    quoted_path="$(shell_quote "$user_path")"
    run_terminal_as_user "BC250 - amdgpu_top" "exec ${quoted_path}" "auto"
    return 0
  fi

  if command_exists amdgpu_top; then
    root_path="$(command -v amdgpu_top)"
    quoted_path="$(shell_quote "$root_path")"
    run_terminal_as_user "BC250 - amdgpu_top" "exec ${quoted_path}" "auto"
    return 0
  fi

  box="$(first_existing_distrobox_for_amdgpu_top || true)"
  if [[ -n "$box" ]]; then
    run_terminal_as_user "BC250 - amdgpu_top (${box})" "exec distrobox-enter -n '${box}' -- amdgpu_top" "auto"
    return 0
  fi

  warn "amdgpu_top not found on host, user PATH, or known Distrobox containers."
  echo
  echo "Expected Distrobox command, based on your setup:"
  echo "  distrobox-enter -n amdtools -- amdgpu_top"
  echo
  if confirm "Install amdgpu_top in Distrobox now?"; then
    install_amdgpu_top_distrobox
  fi
}


launch_amdgpu_top_distrobox_manual() {
  local box
  read -r -p "Distrobox name [amdtools]: " box
  box="${box:-amdtools}"

  if ! command_exists_as_user distrobox; then
    warn "distrobox is not available for user ${REAL_USER}."
    if confirm "Request distrobox installation on the Bazzite host with rpm-ostree?"; then
      rpm_ostree_install_required distrobox || true
      warn "If rpm-ostree staged a deployment, reboot before retrying."
    fi
    return 0
  fi

  if sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "distrobox-enter -n '$box' -- bash -lc 'command -v amdgpu_top >/dev/null 2>&1'" >/dev/null 2>&1; then
    run_terminal_as_user "BC250 - amdgpu_top (${box})" "exec distrobox-enter -n '${box}' -- amdgpu_top" "auto"
  else
    warn "amdgpu_top is not installed in Distrobox '${box}', or the container does not exist."
    if confirm "Install amdgpu_top in Distrobox '${box}' now?"; then
      # Pre-fill the default name through a non-interactive helper.
      install_amdgpu_top_distrobox_named "$box"
    fi
  fi
}




install_amdgpu_top_distrobox_named() {
  local box="${1:-amdtools}"
  local image="${2:-registry.fedoraproject.org/fedora:43}"

  if ! command_exists_as_user distrobox; then
    warn "distrobox is not available for user ${REAL_USER}."
    return 0
  fi

  local install_body
  install_body=$(cat <<EOF_INSTALL
set -e
box="${box}"
image="${image}"

echo "=== BC250 amdgpu_top Distrobox installer ==="
echo "Container: \${box}"
echo "Image:     \${image}"
echo

if ! distrobox-list 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", \$2); print \$2}' | grep -qx "\${box}"; then
  echo "Creating Distrobox \${box}..."
  distrobox-create -n "\${box}" -i "\${image}" --yes
else
  echo "Distrobox \${box} already exists."
fi

echo
echo "Installing dependencies and amdgpu_top inside \${box}..."
distrobox-enter -n "\${box}" -- bash -lc '
set -e
if command -v dnf5 >/dev/null 2>&1; then
  sudo dnf5 -y install git rust cargo clang llvm-devel libdrm-devel pkgconf-pkg-config make gcc gcc-c++ pciutils-devel
else
  sudo dnf -y install git rust cargo clang llvm-devel libdrm-devel pkgconf-pkg-config make gcc gcc-c++ pciutils-devel
fi

echo
echo "Installing amdgpu_top with cargo..."
cargo install amdgpu_top --locked || cargo install amdgpu_top

echo
echo "Installed binary:"
command -v amdgpu_top || true
amdgpu_top --version || true
'

echo
echo "Done."
echo "You can launch it with:"
echo "  distrobox-enter -n \${box} -- amdgpu_top"
echo
read -r -p "Press Enter to close..." _
EOF_INSTALL
)

  run_terminal_as_user "BC250 - install amdgpu_top (${box})" "$install_body" "1"
}

install_amdgpu_top_distrobox() {
  local box image
  read -r -p "Distrobox name [amdtools]: " box
  box="${box:-amdtools}"
  read -r -p "Fedora image [registry.fedoraproject.org/fedora:43]: " image
  image="${image:-registry.fedoraproject.org/fedora:43}"

  if ! command_exists_as_user distrobox; then
    warn "distrobox is not available for user ${REAL_USER}."
    echo
    if confirm "Request distrobox installation on the Bazzite host with rpm-ostree?"; then
      rpm_ostree_install_required distrobox || true
      warn "If rpm-ostree staged a deployment, reboot before retrying this installer."
    fi
    return 0
  fi

  title "Install amdgpu_top in Distrobox"
  echo "This will run in a detached terminal window:"
  echo "  container: ${box}"
  echo "  image:     ${image}"
  echo
  echo "It will:"
  echo "  - create the Distrobox if it does not exist"
  echo "  - install Fedora build dependencies"
  echo "  - install amdgpu_top with cargo"
  echo
  confirm "Launch installation now?" || return 0

  local install_body
  install_body=$(cat <<EOF_INSTALL
set -e
box="${box}"
image="${image}"

echo "=== BC250 amdgpu_top Distrobox installer ==="
echo "Container: \${box}"
echo "Image:     \${image}"
echo

if ! command -v distrobox >/dev/null 2>&1; then
  echo "ERROR: distrobox command not found for this user."
  read -r -p "Press Enter to close..." _
  exit 1
fi

if ! distrobox-list 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", \$2); print \$2}' | grep -qx "\${box}"; then
  echo "Creating Distrobox \${box}..."
  distrobox-create -n "\${box}" -i "\${image}" --yes
else
  echo "Distrobox \${box} already exists."
fi

echo
echo "Installing dependencies and amdgpu_top inside \${box}..."
distrobox-enter -n "\${box}" -- bash -lc '
set -e
if command -v dnf5 >/dev/null 2>&1; then
  sudo dnf5 -y install git rust cargo clang llvm-devel libdrm-devel pkgconf-pkg-config make gcc gcc-c++ pciutils-devel
else
  sudo dnf -y install git rust cargo clang llvm-devel libdrm-devel pkgconf-pkg-config make gcc gcc-c++ pciutils-devel
fi

echo
echo "Installing amdgpu_top with cargo..."
cargo install amdgpu_top --locked || cargo install amdgpu_top

echo
echo "Installed binary:"
command -v amdgpu_top || true
amdgpu_top --version || true
'

echo
echo "Done."
echo "You can launch it with:"
echo "  distrobox-enter -n \${box} -- amdgpu_top"
echo
read -r -p "Press Enter to close..." _
EOF_INSTALL
)

  run_terminal_as_user "BC250 - install amdgpu_top (${box})" "$install_body" "1"
}

ensure_or_install_amdgpu_top_distrobox() {
  local box
  box="$(first_existing_distrobox_for_amdgpu_top || true)"
  if [[ -n "$box" ]]; then
    run_terminal_as_user "BC250 - amdgpu_top (${box})" "exec distrobox-enter -n '${box}' -- amdgpu_top" "auto"
    return 0
  fi

  warn "amdgpu_top was not found in known Distrobox containers."
  echo
  if confirm "Install amdgpu_top in a Distrobox now?"; then
    install_amdgpu_top_distrobox
  fi
}

launch_sensors_watch() {
  if command_exists sensors; then
    run_terminal_as_user "BC250 - sensors watch" "watch -n 1 'sensors | grep -Ei \"edge|junction|mem|temp|fan|power|Tctl|Tdie\" || sensors'" "auto"
  else
    warn "sensors command not found. Install lm_sensors or use another monitoring source."
  fi
}

launch_gpu_governor_journal() {
  run_terminal_as_user "BC250 - GPU governor journal" "journalctl -u cyan-skillfish-governor-smu.service -f" "auto"
}

launch_cpu_governor_journal() {
  run_terminal_as_user "BC250 - CPU governor journal" "journalctl -u bc250-smu-oc.service -f" "auto"
}


launch_swap_zswap_watch() {
  run_terminal_as_user "BC250 - swap zswap watch" 'watch -n 1 '"'"'echo === free ===; free -h; echo; echo === swapon ===; swapon --show; echo; echo === zswap ===; for f in enabled max_pool_percent compressor zpool; do printf "%s=" "$f"; cat /sys/module/zswap/parameters/$f 2>/dev/null || echo unavailable; done'"'"'' "auto"
}

launch_services_status() {
  run_terminal_as_user "BC250 - services status" "systemctl status cyan-skillfish-governor-smu.service bc250-smu-oc.service --no-pager" "1"
}


launch_gpu_sysfs_watch() {
  run_terminal_as_user "BC250 - AMD GPU sysfs" 'watch -n 1 '"'"'for f in /sys/class/drm/card*/device/gpu_busy_percent /sys/class/drm/card*/device/mem_busy_percent /sys/class/drm/card*/device/pp_dpm_sclk /sys/class/drm/card*/device/pp_dpm_mclk /sys/class/drm/card*/device/pp_power_profile_mode; do [ -r "$f" ] && echo === "$f" === && cat "$f" && echo; done'"'"'' "auto"
}

launch_btop_or_top() {
  if command_exists btop; then
    run_terminal_as_user "BC250 - btop" "btop" "auto"
  elif command_exists htop; then
    run_terminal_as_user "BC250 - htop" "htop" "auto"
  else
    run_terminal_as_user "BC250 - top" "top" "auto"
  fi
}

print_monitoring_commands() {
  title "Monitoring Commands"
  cat <<'EOF_MON'
Useful commands:

  amdgpu_top

  distrobox-enter -n amdtools -- amdgpu_top

  # Installer amdgpu_top dans amdtools:
  # distrobox-create -n amdtools -i registry.fedoraproject.org/fedora:43 --yes
  # distrobox-enter -n amdtools -- bash -lc 'sudo dnf -y install git rust cargo clang llvm-devel libdrm-devel pkgconf-pkg-config make gcc gcc-c++ pciutils-devel && cargo install amdgpu_top --locked || cargo install amdgpu_top'

  watch -n 1 'sensors | grep -Ei "edge|junction|mem|temp|fan|power|Tctl|Tdie"'

  journalctl -u cyan-skillfish-governor-smu.service -f

  journalctl -u bc250-smu-oc.service -f

  systemctl status cyan-skillfish-governor-smu.service bc250-smu-oc.service --no-pager

  watch -n 1 'free -h; swapon --show; cat /sys/module/zswap/parameters/enabled; cat /sys/module/zswap/parameters/max_pool_percent; cat /sys/module/zswap/parameters/compressor'

  watch -n 1 'for f in /sys/class/drm/card*/device/{gpu_busy_percent,mem_busy_percent,pp_dpm_sclk,pp_dpm_mclk,pp_power_profile_mode}; do [ -r "$f" ] && echo === "$f" === && cat "$f" && echo; done'
EOF_MON
}




monitoring_menu() {
  while true; do
    banner
    title "Monitoring"
    echo -e "${DIM}Terminal launcher detected: $(terminal_launcher_command || true)${RESET}"
    echo -e "${DIM}Windows are detached; if a tool fails, the window stays open with the error.${RESET}"
    echo

    menu_item "1" "amdgpu_top"       "Auto-detect exact path or Distrobox; install if absent"
    menu_item "2" "amdgpu_top DBX"   "Force launch from Distrobox, default: amdtools"
    menu_item "3" "Install amdgpu"   "Install amdgpu_top in Distrobox"
    menu_item "4" "Sensors"         "Open temperature/power watch in a new window"
    menu_item "5" "GPU Journal"     "Follow cyan-skillfish-governor-smu logs"
    menu_item "6" "CPU Journal"     "Follow bc250-smu-oc logs"
    menu_item "7" "Swap/ZSWAP"      "Watch free, swapon and zswap parameters"
    menu_item "8" "Services Status" "Open CPU/GPU service status window"
    menu_item "9" "AMD GPU Sysfs"   "Watch raw AMD sysfs counters"
    menu_item "B" "btop/htop/top"   "Open system monitor"
    menu_item "L" "Launcher Log"    "Show /tmp/bc250-monitor-${REAL_USER}.log"
    menu_item "A" "Open All"        "Open main monitoring windows"
    menu_item "P" "Print Commands"  "Print manual commands"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) launch_amdgpu_top; sleep 0.5 ;;
      2) launch_amdgpu_top_distrobox_manual; sleep 0.5 ;;
      3) install_amdgpu_top_distrobox; sleep 0.5 ;;
      4) launch_sensors_watch; sleep 0.5 ;;
      5) launch_gpu_governor_journal; sleep 0.5 ;;
      6) launch_cpu_governor_journal; sleep 0.5 ;;
      7) launch_swap_zswap_watch; sleep 0.5 ;;
      8) launch_services_status; sleep 0.5 ;;
      9) launch_gpu_sysfs_watch; sleep 0.5 ;;
      [Bb]) launch_btop_or_top; sleep 0.5 ;;
      [Ll])
        title "Monitoring Launcher Log"
        cat "/tmp/bc250-monitor-${REAL_USER}.log" 2>/dev/null || warn "No launcher log yet."
        pause
        ;;
      [Aa])
        launch_amdgpu_top || true
        launch_sensors_watch || true
        launch_gpu_governor_journal || true
        launch_swap_zswap_watch || true
        ok "Main monitoring windows requested."
        sleep 0.8
        ;;
      [Pp]) print_monitoring_commands; pause ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

additional_tools_menu() {
  while true; do
    banner
    title "Additional Tools"
    menu_item "1" "CPU Governor"  "bc250-smu-oc CPU overclock tools"
    menu_item "2" "GPU Service"   "Start/stop/enable GPU governor"
    menu_item "3" "Kernel Args"   "rpm-ostree kargs tools"
    menu_item "4" "Edit GPU Config" "Open cyan-skillfish-governor-smu config"
    menu_item "5" "Monitoring"    "Open monitoring tools in new terminal windows"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) cpu_governor_menu ;;
      2) gpu_service_menu ;;
      3) kernel_args_menu ;;
      4) edit_gpu_config; pause ;;
      5) monitoring_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Initial setup / revert
# ------------------------------------------------------------------------------



# ------------------------------------------------------------------------------
# BC-250 40 CU unlock helper
# ------------------------------------------------------------------------------

CU_UNLOCK_REPO_URL="https://github.com/duggasco/bc250-40cu-unlock.git"
CU_UNLOCK_DIR="/opt/bc250-40cu-unlock"
ACPI_FIX_REPO="https://github.com/bc250-collective/bc250-acpi-fix.git"
ACPI_FIX_DIR="/opt/bc250-acpi-fix"
NCT6687_REPO="https://github.com/Fred78290/nct6687d.git"
NCT6687_DIR="/opt/nct6687d"

cu_unlock_status() {
  title "Compute Units Unlock Status"
  echo "This checks whether the 40 CU unlock appears active after boot."
  echo

  echo "Kernel: $(uname -r)"
  echo

  echo "Modprobe config:"
  if [[ -f /etc/modprobe.d/bc250-40cu.conf ]]; then
    cat /etc/modprobe.d/bc250-40cu.conf
  else
    warn "/etc/modprobe.d/bc250-40cu.conf not found."
  fi

  echo
  echo "Current kernel cmdline:"
  cat /proc/cmdline || true

  echo
  echo "dmesg active_cu_number:"
  dmesg | grep -i 'active_cu_number' | tail -20 || warn "No active_cu_number line found in dmesg."

  echo
  echo "dmesg bc250-40cu:"
  dmesg | grep -i 'bc250-40cu' | tail -20 || warn "No bc250-40cu line found in dmesg."

  echo
  echo "RADV / Vulkan CU count:"
  if command_exists_as_user vulkaninfo; then
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc 'RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep -i num_cu || true'
  elif command_exists vulkaninfo; then
    RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep -i num_cu || true
  else
    warn "vulkaninfo not found."
  fi

  echo
  echo "Expected when fully unlocked:"
  echo "  active_cu_number 40"
  echo "  num_cu = 40"
}

cu_unlock_dependencies() {
  title "Compute Units Unlock Dependencies"
  warn "This is experimental on Bazzite because it builds/replaces the amdgpu kernel module."
  echo

  rpm_ostree_install_required git gcc make zstd || true

  # Best effort: the exact kernel-devel package name depends on the deployed Bazzite kernel.
  # Do not fail the whole workflow if it is already available or provided differently.
  if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
    ok "Kernel build directory found: /lib/modules/$(uname -r)/build"
  else
    warn "Kernel build directory not found: /lib/modules/$(uname -r)/build"
    warn "Trying common Fedora/Bazzite kernel-devel packages."
    rpm_ostree_install_optional "kernel-devel-$(uname -r)" || true
    rpm_ostree_install_optional "kernel-devel" || true
    warn "If rpm-ostree staged packages, reboot before building the 40 CU module."
  fi
}

cu_unlock_clone_or_update() {
  title "Compute Units Unlock Repository"

  if [[ -d "$CU_UNLOCK_DIR/.git" ]]; then
    info "Updating existing repository: $CU_UNLOCK_DIR"
    git -C "$CU_UNLOCK_DIR" pull --ff-only || warn "Update failed. Keeping existing checkout."
  else
    info "Cloning repository to: $CU_UNLOCK_DIR"
    rm -rf "$CU_UNLOCK_DIR"
    git clone "$CU_UNLOCK_REPO_URL" "$CU_UNLOCK_DIR"
  fi

  chown -R "$REAL_USER":"$REAL_USER" "$CU_UNLOCK_DIR" 2>/dev/null || true
  ok "Repository ready: $CU_UNLOCK_DIR"
}

cu_unlock_show_quickstart() {
  title "Compute Units Unlock Quick Start"
  cat <<'EOF_CU_HELP'
Official project used by this helper:
  https://github.com/duggasco/bc250-40cu-unlock

Important:
  - The patch is off by default.
  - It is enabled by modprobe option:
      options amdgpu bc250_cc_write_mode=3
  - It is not a firmware flash.
  - Rebooting without the config returns the board to normal behavior.
  - Some boards may need selective CU masking if unlocked CUs are unstable.

Manual commands from the project:

  git clone https://github.com/duggasco/bc250-40cu-unlock.git
  cd bc250-40cu-unlock
  sudo ./scripts/bc250-enable-40cu.sh build
  sudo ./scripts/bc250-enable-40cu.sh enable

Verification after reboot:

  dmesg | grep active_cu_number
  dmesg | grep bc250-40cu
  RADV_DEBUG=info vulkaninfo --summary 2>&1 | grep num_cu

Recommended thermal approach:
  Start with a conservative GPU profile before heavy testing.
  For 40 CU, avoid jumping directly to high clocks until stability is confirmed.
EOF_CU_HELP
}


cu_unlock_run_script() {
  local action="$1"

  if [[ ! -x "$CU_UNLOCK_DIR/scripts/bc250-enable-40cu.sh" ]]; then
    warn "Unlock script not found."
    cu_unlock_clone_or_update || return 1
  fi

  if [[ ! -x "$CU_UNLOCK_DIR/scripts/bc250-enable-40cu.sh" ]]; then
    warn "Still missing: $CU_UNLOCK_DIR/scripts/bc250-enable-40cu.sh"
    return 1
  fi

  case "$action" in
    build)
      warn "This will build a replacement amdgpu kernel module for the current kernel."
      if ! find /usr/src "/lib/modules/$(uname -r)/build" -path '*drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c' 2>/dev/null | grep -q .; then
        warn "Bazzite/Fedora source precheck failed: gfx_v10_0.c was not found."
        warn "The upstream script may try Debian/Ubuntu apt source logic and fail."
        warn "Do not run Enable 40 CU unless the build actually succeeds."
        echo
        echo "Diagnostic commands:"
        echo "  uname -r"
        echo "  rpm -q --qf 'kernel-core source RPM: %{SOURCERPM}\\n' kernel-core"
        echo "  find /usr/src /lib/modules/\\$(uname -r)/build -path '*drivers/gpu/drm/amd/amdgpu/gfx_v10_0.c'"
        echo
      fi
      ;;
    enable)
      warn "This will enable the 40 CU unlock and may reboot automatically."
      warn "Make sure the build completed successfully before enabling."
      warn "Make sure your cooling and GPU profile are conservative before testing."
      ;;
    disable)
      warn "This should disable the 40 CU modprobe config and may reboot."
      ;;
    restore)
      warn "This should restore the original amdgpu module and may reboot."
      ;;
    *)
      warn "Unknown action: $action"
      return 1
      ;;
  esac

  confirm "Run '${action}' now?" || return 0

  (
    cd "$CU_UNLOCK_DIR"
    sudo ./scripts/bc250-enable-40cu.sh "$action"
  )
}

cu_unlock_health_quick() {
  title "Compute Units Quick Verify"
  if [[ ! -x "$CU_UNLOCK_DIR/scripts/bc250-compute-verify.sh" ]]; then
    warn "Quick verify script not found."
    cu_unlock_clone_or_update || return 1
  fi

  if [[ -x "$CU_UNLOCK_DIR/scripts/bc250-compute-verify.sh" ]]; then
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "cd '$CU_UNLOCK_DIR' && ./scripts/bc250-compute-verify.sh"
  else
    warn "Still missing: $CU_UNLOCK_DIR/scripts/bc250-compute-verify.sh"
  fi
}

cu_unlock_harvest_map() {
  title "Compute Units Harvest Map"
  if [[ ! -x "$CU_UNLOCK_DIR/scripts/cu_map.sh" ]]; then
    warn "CU map script not found."
    cu_unlock_clone_or_update || return 1
  fi

  if [[ -x "$CU_UNLOCK_DIR/scripts/cu_map.sh" ]]; then
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc "cd '$CU_UNLOCK_DIR' && ./scripts/cu_map.sh"
  else
    warn "Still missing: $CU_UNLOCK_DIR/scripts/cu_map.sh"
  fi
}

cu_unlock_menu() {
  while true; do
    banner
    title "Compute Units Unlock"
    warn "Experimental: builds/replaces the amdgpu kernel module."
    warn "Not included in Run All. Use only if you accept possible boot/graphics issues."
    echo

    menu_item "1" "Status / Verify"   "Check dmesg, modprobe config and RADV num_cu"
    menu_item "2" "Quick Start"       "Print commands and warnings"
    menu_item "3" "Dependencies"      "Install build dependencies best-effort"
    menu_item "4" "Clone / Update"    "Clone or update bc250-40cu-unlock in /opt"
    menu_item "5" "Build module"      "Run bc250-enable-40cu.sh build"
    menu_item "6" "Enable 40 CU"      "Run bc250-enable-40cu.sh enable"
    menu_item "7" "Quick Verify"      "Run bc250-compute-verify.sh if available"
    menu_item "8" "Harvest Map"       "Run cu_map.sh if available"
    menu_item "9" "Disable unlock"    "Run bc250-enable-40cu.sh disable"
    menu_item "R" "Restore module"    "Run bc250-enable-40cu.sh restore"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) cu_unlock_status; pause ;;
      2) cu_unlock_show_quickstart; pause ;;
      3) cu_unlock_dependencies; pause ;;
      4) cu_unlock_clone_or_update; pause ;;
      5) cu_unlock_dependencies; cu_unlock_clone_or_update; cu_unlock_run_script "build"; pause ;;
      6) cu_unlock_clone_or_update; cu_unlock_run_script "enable"; pause ;;
      7) cu_unlock_health_quick; pause ;;
      8) cu_unlock_harvest_map; pause ;;
      9) cu_unlock_clone_or_update; cu_unlock_run_script "disable"; pause ;;
      [Rr]) cu_unlock_clone_or_update; cu_unlock_run_script "restore"; pause ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}



# ------------------------------------------------------------------------------
# BC-250 live 40 CU manager using UMR — primary method on Bazzite
# ------------------------------------------------------------------------------

cu_live_manager_installed() {
  [[ -x "$CU_LIVE_MANAGER_LOCAL" || -x "$CU_LIVE_MANAGER_BIN" ]]
}

cu_live_manager_path() {
  if [[ -x "$CU_LIVE_MANAGER_BIN" ]]; then
    echo "$CU_LIVE_MANAGER_BIN"
  elif [[ -x "$CU_LIVE_MANAGER_LOCAL" ]]; then
    echo "$CU_LIVE_MANAGER_LOCAL"
  else
    echo ""
  fi
}

cu_live_install_umr() {
  title "40 CU Live Manager — UMR"
  if command_exists umr; then
    ok "umr already installed: $(command -v umr)"
    umr --version 2>/dev/null || true
    return 0
  fi

  warn "umr is required for live CU/WGP routing."
  warn "On Bazzite/Fedora Atomic this is layered with rpm-ostree and normally needs a reboot."
  confirm "Layer umr now?" || return 0
  rpm_ostree_install_required umr || true
  warn "If rpm-ostree staged a new deployment, reboot, then return to this menu."
}

cu_live_install_manager() {
  title "40 CU Live Manager — Install / Update"
  mkdir -p "$CU_LIVE_MANAGER_WORKDIR"

  if ! command_exists curl && ! command_exists wget; then
    warn "curl/wget missing. Requesting curl."
    rpm_ostree_install_required curl || true
    warn "Reboot if rpm-ostree staged curl, then retry."
    return 0
  fi

  echo "Source: $CU_LIVE_MANAGER_URL"
  warn "This installs the upstream bc250-cu-live-manager script as the main 40 CU path."
  warn "It does not build or replace the amdgpu kernel module."
  echo
  confirm "Download/update bc250-cu-live-manager now?" || return 0

  info "Downloading bc250-cu-live-manager"
  if command_exists curl; then
    curl -fL "$CU_LIVE_MANAGER_URL" -o "$CU_LIVE_MANAGER_LOCAL"
  else
    wget -O "$CU_LIVE_MANAGER_LOCAL" "$CU_LIVE_MANAGER_URL"
  fi

  chmod 755 "$CU_LIVE_MANAGER_LOCAL"
  chown root:root "$CU_LIVE_MANAGER_LOCAL" 2>/dev/null || true
  install -m 0755 -o root -g root "$CU_LIVE_MANAGER_LOCAL" "$CU_LIVE_MANAGER_BIN"

  ok "Installed local copy: $CU_LIVE_MANAGER_LOCAL"
  ok "Installed command:    $CU_LIVE_MANAGER_BIN"
  echo
  "$CU_LIVE_MANAGER_BIN" --help 2>/dev/null | head -80 || true
}

cu_live_ensure_ready() {
  local mgr
  mgr="$(cu_live_manager_path)"

  if [[ -z "$mgr" ]]; then
    warn "bc250-cu-live-manager is not installed yet."
    if confirm "Install/update it now?"; then
      cu_live_install_manager || true
    fi
  fi

  mgr="$(cu_live_manager_path)"
  [[ -n "$mgr" ]] || return 1

  if ! command_exists umr; then
    warn "umr is not installed/visible yet."
    if confirm "Layer umr now?"; then
      cu_live_install_umr || true
    fi
    return 1
  fi

  return 0
}

cu_live_run() {
  local action="${1:-}"
  local mgr

  cu_live_ensure_ready || return 1
  mgr="$(cu_live_manager_path)"

  case "$action" in
    "") "$mgr" ;;
    *) "$mgr" "$action" ;;
  esac
}

cu_live_status() {
  title "40 CU Live Manager — Status"
  echo "Kernel driver declaration from dmesg:"
  dmesg | grep -i 'active_cu_number' | tail -10 || true
  echo
  echo "Manager: $(cu_live_manager_path || true)"
  echo "umr:     $(command -v umr 2>/dev/null || echo absent)"
  echo

  if cu_live_manager_installed && command_exists umr; then
    cu_live_run status || true
  else
    warn "Live manager or umr is not ready yet."
  fi

  echo
  warn "Important: with live UMR routing, dmesg may still show active_cu_number 24."
  warn "Use the manager dashboard: 'CUs active & routed: 40/40' is the useful live indicator."
}

cu_live_interactive_ui() {
  title "40 CU Live Manager — Interactive UI"
  warn "Recommended first test: use [f] Enable all CUs in the manager, then monitor temps/stability."
  cu_live_run "" || true
}

cu_live_enable_all_once() {
  title "40 CU Live — Enable all CUs until reboot"
  warn "This writes live GPU registers through UMR. It can freeze the GPU if unstable."
  warn "It is temporary until reboot unless you save the table and install the boot service."
  warn "Close games and keep a remote/TTY fallback if possible."
  echo
  confirm "Apply all CUs live now?" || return 0
  cu_live_run enable || warn "Live enable failed. Try the interactive UI."
  echo
  cu_live_run status || true
}

cu_live_save_boot_table() {
  title "40 CU Live — Save current table for boot"
  warn "Only do this after the live 40 CU test is stable."
  warn "This saves the CURRENT live routing table, then installs/enables the systemd service."
  echo
  confirm "Save current live table and install boot service?" || return 0
  cu_live_run write-service-table || return 1
  cu_live_run install-service || return 1
  systemctl status "$CU_LIVE_MANAGER_SERVICE" --no-pager || true
}

cu_live_apply_saved_service_now() {
  title "40 CU Live — Apply saved boot table now"
  warn "This applies the saved service table immediately, if one exists."
  confirm "Apply saved service table now?" || return 0
  cu_live_run apply-service || true
  cu_live_run status || true
}

cu_live_restore_stock_once() {
  title "40 CU Live — Restore stock dispatch until reboot"
  warn "This restores stock dispatch live. It does not necessarily remove the boot service."
  confirm "Restore stock dispatch now?" || return 0
  cu_live_run stock-dispatch || cu_live_run disable || warn "Stock restore failed. Try the interactive UI."
  echo
  cu_live_run status || true
}

cu_live_uninstall_service() {
  title "40 CU Live — Uninstall boot service"
  warn "This removes persistence at boot. Live registers may remain changed until reboot or stock-dispatch."
  confirm "Disable and remove bc250-cu-live-manager boot service?" || return 0
  cu_live_run uninstall-service || true
  systemctl daemon-reload || true
  ok "Boot service removal requested."
}

cu_live_print_workflow() {
  title "40 CU Live Manager — Recommended Workflow"
  cat <<EOF_CU_LIVE_WORKFLOW
Recommended order for your BC250 on Bazzite:

  1. Install UMR
       menu [2]
       reboot if rpm-ostree asks for it

  2. Install / Update bc250-cu-live-manager
       menu [3]

  3. Check status
       menu [1]
       current dmesg may still show 24 CU before live routing

  4. Test live only
       menu [5]
       this enables all CUs until reboot only

  5. Verify with the live dashboard
       menu [1]
       target: CUs active & routed = 40/40

  6. Stress test / play / monitor temps
       keep GPU clocks conservative first

  7. Only if stable: save at boot
       menu [6]
       writes current table + installs systemd boot service

  8. Rollback options
       menu [7] stock live
       menu [8] uninstall boot service
       or simply reboot if no boot service was saved

This replaces the old kernel-module unlock path. The old amdgpu module build is not used by default.
EOF_CU_LIVE_WORKFLOW
}

cu_unlock_menu() {
  while true; do
    banner
    title "Compute Units / 40 CU Unlock"
    echo "Integrated method: bc250-cu-live-manager with UMR."
    echo "No amdgpu module build, no gfx_v10_0.c source required."
    echo
    warn "Always test live before making it persistent at boot."
    echo
    menu_item "W" "Workflow"        "Recommended order and rollback"
    menu_item "1" "Status"          "dmesg + dashboard live manager"
    menu_item "2" "Install UMR"     "Layer umr with rpm-ostree if missing"
    menu_item "3" "Install Manager" "Download/update bc250-cu-live-manager"
    menu_item "4" "Interactive UI"  "Run the manager TUI manually"
    menu_item "5" "40 CU live"      "Enable all CUs until reboot"
    menu_item "6" "Save boot"       "Save current table + install boot service"
    menu_item "7" "Stock live"      "Restore stock dispatch until reboot"
    menu_item "8" "Uninstall boot"  "Remove boot restore service"
    menu_item "9" "Apply saved"     "Apply saved service table now"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      [Ww]) cu_live_print_workflow; pause ;;
      1) cu_live_status; pause ;;
      2) cu_live_install_umr; pause ;;
      3) cu_live_install_manager; pause ;;
      4) cu_live_interactive_ui; pause ;;
      5) cu_live_enable_all_once; pause ;;
      6) cu_live_save_boot_table; pause ;;
      7) cu_live_restore_stock_once; pause ;;
      8) cu_live_uninstall_service; pause ;;
      9) cu_live_apply_saved_service_now; pause ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Bazzite BC250 practical setup helpers
# ------------------------------------------------------------------------------

rpm_ostree_install_base_packages_once() {
  title "Base Bazzite Packages"
  warn "Optimized path: one rpm-ostree transaction for host packages."
  warn "If packages are staged, reboot before tools like pipx become available."
  echo

  disable_conflicting_gpu_governors
  enable_filippor_copr

  rpm-ostree cleanup -m 2>/dev/null || true
  rpm-ostree refresh-md 2>/dev/null || true

  rpm_ostree_install_required \
    git pipx stress gcc make zstd cyan-skillfish-governor-smu || return 1

  ok "Base package layer request completed."
  warn "Reboot is recommended/required before continuing with pipx, services or module builds."
}

disable_sleep_modes() {
  title "Disable Sleep / Hibernation"

  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

  mkdir -p /etc/systemd/logind.conf.d
  cat > /etc/systemd/logind.conf.d/disable-sleep.conf <<'EOF_SLEEP'
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=poweroff
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
EOF_SLEEP

  systemctl restart systemd-logind || true

  ok "System sleep/hibernate targets masked."
  ok "logind sleep actions disabled."
  warn "KDE/Steam display power saving may still need GUI adjustment."
}

enable_sleep_modes() {
  title "Re-enable Sleep / Hibernation"
  systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
  rm -f /etc/systemd/logind.conf.d/disable-sleep.conf
  systemctl restart systemd-logind || true
  ok "Sleep/hibernate targets unmasked and logind override removed."
}

install_acpi_fix() {
  title "BC250 ACPI Fix"

  if ! command_exists git; then
    warn "git is not available on this deployment."
    warn "Run Base Packages or CPU Governor first, reboot, then retry."
    rpm_ostree_install_required git || true
    return 0
  fi

  if [[ -d "$ACPI_FIX_DIR/.git" ]]; then
    info "Updating existing repository: $ACPI_FIX_DIR"
    git -C "$ACPI_FIX_DIR" pull --ff-only || warn "Update failed. Keeping existing checkout."
  else
    info "Cloning repository to: $ACPI_FIX_DIR"
    rm -rf "$ACPI_FIX_DIR"
    git clone "$ACPI_FIX_REPO" "$ACPI_FIX_DIR"
  fi

  if ! find "$ACPI_FIX_DIR" -maxdepth 2 -name '*.aml' | grep -q .; then
    warn "No .aml files found in $ACPI_FIX_DIR"
    return 1
  fi

  rm -rf /tmp/bc250-acpi-tables
  mkdir -p /tmp/bc250-acpi-tables/kernel/firmware/acpi
  find "$ACPI_FIX_DIR" -maxdepth 2 -name '*.aml' -exec cp -v '{}' /tmp/bc250-acpi-tables/kernel/firmware/acpi/ \;

  (
    cd /tmp/bc250-acpi-tables
    find kernel | cpio -H newc --create > SSDT_ACPI.cpio
  )

  install -m 0644 /tmp/bc250-acpi-tables/SSDT_ACPI.cpio /boot/SSDT_ACPI.cpio

  if ! grep -q 'GRUB_EARLY_INITRD_LINUX_CUSTOM="../../SSDT_ACPI.cpio"' /etc/default/grub 2>/dev/null; then
    echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="../../SSDT_ACPI.cpio"' >> /etc/default/grub
  fi

  if command_exists ujust; then
    ujust regenerate-grub
  else
    warn "ujust not found. Please regenerate GRUB manually."
  fi

  ok "ACPI fix installed to /boot/SSDT_ACPI.cpio and referenced in /etc/default/grub."
  warn "Reboot required, then verify cpufreq frequencies."
}

verify_acpi_fix() {
  title "BC250 ACPI Fix Status"

  if [[ -f /boot/SSDT_ACPI.cpio ]]; then
    ls -l /boot/SSDT_ACPI.cpio
  else
    warn "/boot/SSDT_ACPI.cpio not found."
  fi

  echo
  grep -R "SSDT_ACPI" /etc/default/grub /boot/loader/entries 2>/dev/null || warn "No SSDT_ACPI reference found."

  echo
  if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    echo "cpufreq directory:"
    ls /sys/devices/system/cpu/cpu0/cpufreq/ 2>/dev/null || true
    echo
    echo -n "governor: "
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"
    echo -n "frequencies: "
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo "unknown"
  else
    warn "cpufreq directory not found. Reboot after ACPI install, or ACPI did not apply."
  fi
}

install_nct6687_sensors() {
  title "NCT6687 Sensors"

  if ! command_exists git || ! command_exists make || ! command_exists gcc; then
    warn "git/make/gcc missing. Requesting host packages."
    rpm_ostree_install_required git gcc make || true
    warn "Reboot if rpm-ostree staged packages, then retry this step."
    return 0
  fi

  if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
    warn "Kernel build dir missing: /lib/modules/$(uname -r)/build"
    warn "Install matching kernel-devel or update/reboot first."
    return 1
  fi

  if [[ -d "$NCT6687_DIR/.git" ]]; then
    info "Updating existing repository: $NCT6687_DIR"
    git -C "$NCT6687_DIR" pull --ff-only || warn "Update failed. Keeping existing checkout."
  else
    info "Cloning repository to: $NCT6687_DIR"
    rm -rf "$NCT6687_DIR"
    git clone "$NCT6687_REPO" "$NCT6687_DIR"
  fi

  chown -R "$REAL_USER":"$REAL_USER" "$NCT6687_DIR" 2>/dev/null || true

  (
    cd "$NCT6687_DIR"
    make clean >/dev/null 2>&1 || true
    make
  )

  local built="$NCT6687_DIR/$(uname -r)/nct6687.ko"
  if [[ ! -f "$built" ]]; then
    warn "Built module not found: $built"
    return 1
  fi

  mkdir -p "/var/lib/bc250/modules/$(uname -r)"
  install -m 0644 "$built" "/var/lib/bc250/modules/$(uname -r)/nct6687.ko"
  chcon -t modules_object_t "/var/lib/bc250/modules/$(uname -r)/nct6687.ko" 2>/dev/null || true

  cat > /usr/local/sbin/bc250-load-nct6687 <<'EOF_NCT_LOADER'
#!/usr/bin/env bash
set -euo pipefail

MODULE_NAME="nct6687"
KERNEL="$(uname -r)"
MODULE_PATH="/var/lib/bc250/modules/${KERNEL}/nct6687.ko"

if lsmod | grep -q "^${MODULE_NAME} "; then
  echo "${MODULE_NAME} already loaded"
  exit 0
fi

if [[ ! -f "$MODULE_PATH" ]]; then
  echo "Module not found: $MODULE_PATH" >&2
  exit 1
fi

/usr/sbin/insmod "$MODULE_PATH"
EOF_NCT_LOADER
  chmod +x /usr/local/sbin/bc250-load-nct6687

  cat > /etc/systemd/system/bc250-nct6687.service <<'EOF_NCT_SERVICE'
[Unit]
Description=Load NCT6687 hwmon module for BC250
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bc250-load-nct6687
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_NCT_SERVICE

  systemctl daemon-reload
  systemctl reset-failed bc250-nct6687.service >/dev/null 2>&1 || true
  systemctl enable --now bc250-nct6687.service || warn "Service could not load module now. Check status below."
  systemctl status bc250-nct6687.service --no-pager || true

  ok "NCT6687 sensor service installed."
  echo
  sensors 2>/dev/null | grep -Ei "Tctl|edge|PPT|CPU:|VRM|Pump|Fan" || true
}

verify_nct6687_sensors() {
  title "NCT6687 Sensors Status"
  systemctl status bc250-nct6687.service --no-pager || true
  echo
  lsmod | grep nct6687 || warn "nct6687 module not loaded."
  echo
  if command_exists sensors; then
    sensors 2>/dev/null | grep -Ei "Tctl|edge|PPT|CPU:|VRM|Pump|Fan" || true
  else
    warn "sensors command not found."
  fi
}

run_all_base_optimized() {
  title "Run All — Bazzite Optimized Base"
  warn "This optimized sequence avoids several separate rpm-ostree package transactions."
  warn "It does not include mitigations=off, ACPI fix, NCT sensors or 40 CU unlock."
  echo

  rpm_ostree_install_base_packages_once || true

  if command_exists git && command_exists pipx; then
    install_cpu_governor || true
  else
    warn "git/pipx not visible yet. This is normal if rpm-ostree just staged packages."
    warn "Reboot, then run CPU Governor again."
  fi

  write_gpu_config "Strong" 1850 80 75
  configure_swap_zswap "32G" "auto" "no"
  apply_run_all_kargs_batched "25"
  rpm-ostree initramfs --enable --arg=--add-drivers --arg=lz4 || warn "initramfs lz4 option was not applied automatically."

  disable_sleep_modes || true

  warn "Reboot recommended/required after Run All."
}


initial_setup_menu() {
  while true; do
    banner
    title "Initial Setup — recommended order"
    echo "Menu ordered for a fresh Bazzite install."
    echo "For the full guided path, use the main menu: [W] Workflow."
    echo

    section "System base — do this first"
    menu_item "1" "Run All Base"        "Packages, GPU governor, swap/zswap, sleep off — reboot after"
    menu_item "2" "Boot Logo"           "quiet splash rhgb, removes loglevel=0 — reboot after"
    menu_item "3" "ACPI Fix"            "BC250 cpufreq/P-States — reboot after install"
    menu_item "4" "NCT6687 Sensors"     "Sondes VRM/fans/pump"
    echo
    section "OC tools — after the base setup"
    menu_item "5" "CPU Governor"        "bc250-smu-oc CPU overclock service"
    menu_item "6" "GPU Governor"        "cyan-skillfish GPU governor service"
    menu_item "7" "Enable Swap"         "32G Btrfs swapfile, swappiness=180"
    menu_item "8" "ZRAM -> ZSWAP"       "Disable ZRAM, enable ZSWAP w/ lz4 — reboot after"
    echo
    section "Options"
    menu_item "9" "Disable Sleep"       "Mask sleep/suspend/hibernate and logind idle actions"
    menu_item "M" "Disable Mitigations" "Add mitigations=off — optional"
    menu_item "C" "Compute Units Unlock" "40 CU live manager menu — after CPU/GPU/sensors"
    menu_item "R" "Reboot now"          "systemctl reboot"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1)
        run_all_base_optimized
        offer_reboot_now "Run All Base changed packages/kernel args. Reboot is recommended before continuing."
        pause
        ;;
      2)
        apply_boot_logo_kargs_batched
        offer_reboot_now "Boot Logo changed kernel args. Reboot is required to see the result."
        pause
        ;;
      3)
        verify_acpi_fix
        echo
        if confirm "Install/update ACPI fix now?"; then
          install_acpi_fix
          offer_reboot_now "ACPI Fix installed/updated. Reboot is required to load the ACPI override."
        fi
        pause
        ;;
      4)
        verify_nct6687_sensors
        echo
        if confirm "Build/install NCT6687 sensors now?"; then
          install_nct6687_sensors
        fi
        pause
        ;;
      5) setup_cpu_governor_quick; pause ;;
      6) install_gpu_governor; write_gpu_config "Strong" 1850 80 75; restart_gpu_governor_if_available; pause ;;
      7) configure_swap_zswap "32G" "auto" "yes"; offer_reboot_now "Swap/ZSWAP changed kernel args. Reboot is recommended."; pause ;;
      8)
        apply_zswap_kargs_batched "25"
        offer_reboot_now "ZSWAP changed kernel args. Reboot is required."
        pause
        ;;
      9)
        disable_sleep_modes
        pause
        ;;
      [Mm])
        confirm "mitigations=off can reduce CPU security protections. Continue?" || continue
        karg_append_if_missing "mitigations=off"
        offer_reboot_now "mitigations=off was added. Reboot is required."
        pause
        ;;
      [Cc]) cu_unlock_menu ;;
      [Rr]) reboot_now_menu ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

revert_menu() {
  while true; do
    banner
    title "Revert Menu"
    menu_item "1" "Stock GPU Profile" "Write stock 1500MHz GPU profile"
    menu_item "2" "Disable GPU Gov"   "Disable and stop cyan-skillfish-governor-smu"
    menu_item "3" "Disable CPU Gov"   "Disable and stop bc250-smu-oc"
    menu_item "4" "Remove Swapfile"   "swapoff and remove /var/swap/swapfile entry"
    menu_item "5" "Remove ZSWAP Kargs" "Delete zswap/systemd.zram kargs"
    menu_item "6" "Remove Boot Tweaks" "Delete loglevel and mitigations kargs"
    menu_item "7" "Re-enable Sleep" "Unmask sleep/suspend/hibernate and remove logind override"
    menu_item "0" "Back"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      1) write_gpu_config "Stock" 1500 80 75; restart_gpu_governor_if_available; pause ;;
      2) systemctl disable --now cyan-skillfish-governor-smu.service || true; ok "GPU governor disabled."; pause ;;
      3) systemctl disable --now bc250-smu-oc.service || true; ok "CPU governor disabled."; pause ;;
      4)
        confirm "Remove ${SWAPFILE} and its fstab entry?" || continue
        swapoff "$SWAPFILE" >/dev/null 2>&1 || true
        sed -i '\# /var/swap/swapfile #d; /\/var\/swap\/swapfile/d' /etc/fstab
        rm -f "$SWAPFILE"
        ok "Swapfile removed."
        pause
        ;;
      5)
        karg_delete_key "zswap.enabled"
        karg_delete_key "zswap.max_pool_percent"
        karg_delete_key "zswap.compressor"
        karg_delete_key "systemd.zram"
        rm -f /etc/systemd/zram-generator.conf
        warn "Reboot required."
        pause
        ;;
      6)
        karg_delete_key "loglevel"
        karg_delete_key "mitigations"
        warn "Reboot required."
        pause
        ;;
      7)
        enable_sleep_modes
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}


# ------------------------------------------------------------------------------
# Path detection / GitHub-friendly diagnostics
# ------------------------------------------------------------------------------

path_detection_screen() {
  banner
  title "Path Detection"
  echo "This screen is useful before opening GitHub issues or publishing setup notes."
  echo

  section "User paths"
  echo "Real user:       ${REAL_USER}"
  echo "Home:            ${REAL_HOME}"
  echo "Downloads:       ${USER_DOWNLOADS_DIR}"
  echo "Toolkit home:    ${CANONICAL_HOME_SCRIPT}"
  echo "Toolkit alt:     ${CANONICAL_HOME_SCRIPT_ALT}"
  echo

  section "Root / tool paths"
  echo "Root home from passwd: $(getent passwd root | cut -d: -f6 2>/dev/null || echo /root)"
  echo "bc250-detect:    $(command -v bc250-detect 2>/dev/null || echo absent)"
  echo "bc250-apply:     $(command -v bc250-apply 2>/dev/null || echo absent)"
  echo "umr:             $(command -v umr 2>/dev/null || echo absent)"
  echo "GPU config:      ${GPU_CONFIG}"
  echo "CPU repo dir:    ${CPU_REPO_DIR}"
  echo "40 CU manager:   $(cu_live_manager_path 2>/dev/null || true)"
  echo

  section "System paths"
  echo "Kernel:          $(uname -r)"
  echo "Kernel build:    /lib/modules/$(uname -r)/build"
  ls -ld "/lib/modules/$(uname -r)/build" 2>/dev/null || true
  echo

  pause
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------


status_screen() {
  banner
  title "Status"

  section "System"
  if [[ -f /etc/os-release ]]; then
    grep -E '^(NAME|VERSION|VARIANT|ID)=' /etc/os-release || true
  fi
  echo
  rpm-ostree status --booted || true
  echo

  section "Performance Profile"
  echo "Toolkit state: $(active_profile_line)"
  echo
  echo "GPU governor config:"
  print_gpu_config_summary
  echo
  echo "CPU governor config:"
  print_cpu_config_summary
  echo

  section "Services"
  local svc
  for svc in \
    cyan-skillfish-governor-smu.service \
    bc250-smu-oc.service \
    bc250-nct6687.service \
    cyan-skillfish-governor.service \
    cyan-skillfish-governor-tt.service \
    oberon-governor.service; do
    printf "  %-42s " "$svc"
    systemctl is-active "$svc" 2>/dev/null || true
  done
  echo

  section "Swap / ZSWAP"
  free -h || true
  echo
  swapon --show || true
  if ! swapon --show | grep -q "$SWAPFILE"; then
    warn "Swapfile is not active. Run Initial Setup -> Enable Swap or Run All Base."
  fi
  if [[ -f "$SWAPFILE" ]]; then
    echo
    ls -lh "$SWAPFILE" || true
  fi
  echo
  if [[ -r /sys/module/zswap/parameters/enabled ]]; then
    echo "zswap.enabled=$(cat /sys/module/zswap/parameters/enabled)"
    echo "zswap.max_pool_percent=$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo unknown)"
    echo "zswap.compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo unknown)"
  else
    warn "zswap sysfs parameters not readable."
  fi
  echo

  section "Kernel Arguments"
  rpm-ostree kargs || true
  echo

  section "Sensors"
  if command_exists sensors; then
    sensors 2>/dev/null | grep -Ei 'Tctl|edge|PPT|CPU:|VRM|Pump|Fan|junction|mem|temp|power' || true
  else
    warn "sensors command not found."
  fi

  pause
}


script_self_path() {
  readlink -f "$0" 2>/dev/null || echo "$0"
}

script_sha256() {
  local file="$1"
  if command_exists sha256sum && [[ -f "$file" ]]; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo "sha256-unavailable"
  fi
}

extract_script_version() {
  local file="$1"
  grep -m1 '^VERSION=' "$file" 2>/dev/null | sed -E 's/^VERSION="([^"]+)".*/\1/' || true
}

version_scan_screen() {
  banner
  title "Toolkit Version Scan"

  local current_path current_sha
  current_path="$(script_self_path)"
  current_sha="$(script_sha256 "$current_path")"

  echo "Running file:"
  echo "  ${current_path}"
  echo "Running version:"
  echo "  ${VERSION}"
  echo "Running SHA256:"
  echo "  ${current_sha}"
  echo

  section "Copies found in ${REAL_HOME}"
  local found=0
  while IFS= read -r file; do
    found=1
    local ver sha marker
    ver="$(extract_script_version "$file")"
    sha="$(script_sha256 "$file")"

    marker=""
    if [[ "$sha" == "$current_sha" ]]; then
      marker="MATCH"
    else
      marker="DIFFERENT"
    fi

    printf "%s\n" "---- ${file}"
    printf "  version: %s\n" "${ver:-unknown}"
    printf "  sha256 : %s\n" "$sha"
    printf "  status : %s\n" "$marker"
  done < <(find "$REAL_HOME" -maxdepth 5 -type f -iname "bc250-toolkit*.sh" 2>/dev/null | sort)

  if [[ "$found" -eq 0 ]]; then
    warn "No bc250-toolkit*.sh file found in ${REAL_HOME}."
  fi

  echo
  warn "If ./bc250-toolkit.sh launches an older version, the file in the current directory is stale."
  pause
}


first_boot_preflight() {
  banner
  title "First Boot / BC250 Preflight"
  echo "Run this right after a fresh Bazzite installation on a BC250 board."
  echo "It does not change anything; it only checks whether the system is ready."
  echo

  section "1. System / Bazzite image"
  if [[ -f /etc/os-release ]]; then
    grep -E '^(NAME|VERSION|VARIANT|ID)=' /etc/os-release || true
  fi
  echo
  rpm-ostree status --booted 2>/dev/null | sed 's/^/  /' || true
  echo

  section "2. Kernel"
  local k
  k="$(uname -r)"
  echo "  Active kernel: ${k}"
  if [[ "$k" =~ ^6\.15\.[0-6] ]] || [[ "$k" =~ ^6\.17\.(8|9|10) ]]; then
    warn "This kernel is in a range known to be problematic on some BC250 setups: ${k}"
    warn "Update Bazzite or boot another deployment before heavy optimization."
  else
    ok "Kernel is outside the known problematic BC250 ranges checked by this toolkit."
  fi
  echo

  section "3. Mesa / RADV"
  rpm -q mesa-vulkan-drivers mesa-dri-drivers 2>/dev/null | sed 's/^/  /' || warn "Mesa packages were not found through rpm -q."
  if command_exists_as_user vulkaninfo; then
    sudo -u "$REAL_USER" env HOME="$REAL_HOME" PATH="$(toolkit_user_path)" bash -lc 'vulkaninfo --summary 2>/dev/null | sed -n "/GPU id/,+6p" | head -20' | sed 's/^/  /' || true
  elif command_exists vulkaninfo; then
    vulkaninfo --summary 2>/dev/null | sed -n '/GPU id/,+6p' | head -20 | sed 's/^/  /' || true
  else
    warn "vulkaninfo is missing. Install vulkan-tools if you want a precise RADV check."
  fi
  echo

  section "4. BIOS / VRAM reminder"
  if command_exists dmidecode; then
    dmidecode -s bios-version 2>/dev/null | sed 's/^/  BIOS version: /' || true
    dmidecode -s bios-release-date 2>/dev/null | sed 's/^/  BIOS date: /' || true
  else
    warn "dmidecode is missing. BIOS info cannot be shown."
  fi
  warn "Recommended baseline: BIOS P3.00 and Dynamic VRAM 512MB for most BC250 gaming setups."
  echo "  Check BIOS VRAM if RADV/Vulkan or performance looks wrong."
  echo

  section "5. Boot parameters"
  rpm-ostree kargs 2>/dev/null | sed 's/^/  /' || true
  if rpm-ostree kargs 2>/dev/null | grep -qw nomodeset; then
    warn "nomodeset is present. Remove it after installation, otherwise the GPU will not work correctly."
  else
    ok "nomodeset is absent."
  fi
  if rpm-ostree kargs 2>/dev/null | grep -qw loglevel=0; then
    warn "loglevel=0 is present. It can hide the Bazzite/Plymouth logo. Use Boot Logo to remove it."
  fi
  echo

  section "6. ACPI / CPU cpufreq"
  if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    echo -n "  governor: "
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown
    echo -n "  frequencies: "
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo unknown
    if cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null | grep -q '3200000'; then
      ok "BC250 P-States are visible."
    else
      warn "Expected P-States are not visible. Run Initial Setup -> ACPI Fix, then reboot."
    fi
  else
    warn "cpufreq is missing. Run Initial Setup -> ACPI Fix, then reboot."
  fi
  echo

  section "7. GPU governor"
  if systemctl is-active cyan-skillfish-governor-smu.service >/dev/null 2>&1; then
    ok "cyan-skillfish-governor-smu.service is active."
  else
    warn "GPU governor is not active. Run Initial Setup -> GPU Governor, or Additional Tools -> GPU Service."
  fi
  print_gpu_config_summary || true
  echo

  section "8. Sensors / cooling"
  if systemctl is-active bc250-nct6687.service >/dev/null 2>&1; then
    ok "bc250-nct6687.service is active."
  else
    warn "NCT6687 sensor service is inactive or missing. Run Initial Setup -> NCT6687 Sensors."
  fi
  if command_exists sensors; then
    sensors 2>/dev/null | grep -Ei 'Tctl|edge|PPT|CPU:|VRM|Pump|Fan|junction|mem|temp|power' | sed 's/^/  /' || true
  else
    warn "sensors command is missing."
  fi
  echo

  section "9. Compute Units"
  dmesg | grep -i 'active_cu_number' | tail -5 | sed 's/^/  /' || warn "active_cu_number was not found in dmesg."
  echo "  24 CU = stock state. 40 CU should be tested live first, then made persistent only if stable."
  echo

  section "10. Swap / ZSWAP"
  swapon --show | sed 's/^/  /' || true
  if swapon --show | grep -q "$SWAPFILE"; then
    ok "Toolkit swapfile is active."
  else
    warn "Toolkit swapfile is missing or inactive. Run Initial Setup -> Enable Swap, or Run All Base."
  fi
  if [[ -r /sys/module/zswap/parameters/enabled ]]; then
    echo "  zswap.enabled=$(cat /sys/module/zswap/parameters/enabled)"
    echo "  zswap.max_pool_percent=$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo unknown)"
    echo "  zswap.compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo unknown)"
  fi
  echo

  section "Recommended order"
  cat <<'EOF_PREFLIGHT_ORDER'
  0) Guided Workflow from the main menu
  1) Run All Base, then reboot if rpm-ostree staged a deployment
  2) Boot Logo, then reboot to confirm the logo is back
  3) ACPI Fix, then reboot if installed/updated
  4) NCT6687 Sensors, then check cooling before any OC
  5) CPU tests first; install at boot only after a clean result
  6) GPU tests by small steps; validate in game/benchmark
  7) 40 CU Live Manager: UMR -> manager -> live -> tests -> save boot only if stable
  8) Monitoring and Status before any aggressive persistence
EOF_PREFLIGHT_ORDER
  pause
}

offer_reboot_now() {
  local reason="${1:-Reboot recommended.}"
  echo
  warn "$reason"
  if confirm "Reboot now with systemctl reboot?"; then
    systemctl reboot
  else
    warn "Reboot skipped. Reboot before the next step if rpm-ostree, kargs, or ACPI changed."
  fi
}

reboot_now_menu() {
  title "Reboot"
  warn "The machine will reboot with systemctl reboot."
  confirm "Reboot now?" || return 0
  systemctl reboot
}

workflow_step_0_preflight() {
  first_boot_preflight
}

workflow_step_1_base() {
  title "Workflow 1/10 — Run All Base"
  cat <<'EOF_STEP'
Goal:
  - install base host packages with rpm-ostree
  - install/prepare the GPU governor
  - create swap/zswap
  - disable sleep/hibernate

A reboot is usually required if rpm-ostree stages a new deployment.
EOF_STEP
  echo
  confirm "Run All Base now?" || return 0
  run_all_base_optimized
  offer_reboot_now "Run All Base finished. Reboot is recommended before continuing."
}

workflow_step_2_boot_logo() {
  title "Workflow 2/10 — Bazzite Boot Logo"
  cat <<'EOF_STEP'
Goal:
  - keep the graphical Bazzite/Plymouth boot
  - add quiet + splash + rhgb
  - remove loglevel=0, which can hide the logo
EOF_STEP
  echo
  confirm "Apply Boot Logo kernel arguments now?" || return 0
  apply_boot_logo_kargs_batched
  offer_reboot_now "Boot Logo kargs changed. Reboot is required to see the result."
}

workflow_step_3_acpi() {
  title "Workflow 3/10 — ACPI Fix"
  verify_acpi_fix
  echo
  cat <<'EOF_STEP'
Goal:
  - enable BC250 CPU P-States/C-States
  - make expected cpufreq values visible, including 3200000

A reboot is required after installing or updating the ACPI fix.
EOF_STEP
  echo
  confirm "Install/update ACPI Fix now?" || return 0
  install_acpi_fix
  offer_reboot_now "ACPI Fix installed/updated. Reboot is required to load SSDT_ACPI.cpio."
}

workflow_step_4_sensors() {
  title "Workflow 4/10 — NCT6687 Sensors"
  verify_nct6687_sensors
  echo
  cat <<'EOF_STEP'
Goal:
  - expose VRM / Tctl / GPU temperatures
  - expose pump/fan RPM values
  - prepare monitoring before CPU/GPU overclocking
EOF_STEP
  echo
  confirm "Build/install NCT6687 sensors now?" || return 0
  install_nct6687_sensors
}

workflow_step_5_cpu_tools() {
  title "Workflow 5/10 — CPU tools"
  cat <<'EOF_STEP'
Goal:
  - install bc250_smu_oc through pipx
  - provide bc250-detect and bc250-apply

This step installs tools only. Do not install a CPU OC at boot until a test result is clean.
EOF_STEP
  echo
  confirm "Install/update CPU tools now?" || return 0
  setup_cpu_governor_quick
}

workflow_step_6_cpu_tests() {
  title "Workflow 6/10 — CPU tests"
  cat <<'EOF_STEP'
Measured reference from this BC250 session:
  - Daily candidate: 3650 MHz / 1160 mV / 90°C target
  - Expected detected result: around 3650 MHz @ 1137 mV
  - Performance test: 3700 MHz / 1180 mV / 95°C target

Observed throttling on this machine:
  - 3775 MHz
  - 3800 MHz
  - 4000 MHz target is not realistic without better cooling

Use the CPU test menu. Install at boot only after a clean result.
EOF_STEP
  echo
  cpu_test_menu
}

workflow_step_7_gpu_tests() {
  title "Workflow 7/10 — GPU tests"
  cat <<'EOF_STEP'
Recommended GPU test path:
  1) 1850 MHz baseline
  2) 1900 MHz
  3) 1950 MHz
  4) 2000 MHz

Daily temperature suggestion:
  - throttle 82-85°C
  - recovery 76-78°C

Use higher limits only for short tests. Validate each step in game/benchmark with monitoring.
EOF_STEP
  echo
  gpu_test_menu
}

workflow_step_8_40cu() {
  title "Workflow 8/10 — 40 CU Live Manager"
  cat <<'EOF_STEP'
Recommended 40 CU order:
  1) Install UMR
  2) Reboot if rpm-ostree requires it
  3) Install bc250-cu-live-manager
  4) Status
  5) 40 CU live only
  6) Stress/game test
  7) Save boot only if stable

This method does not compile or replace amdgpu and does not need gfx_v10_0.c.
EOF_STEP
  echo
  cu_unlock_menu
}

workflow_step_9_monitoring() {
  title "Workflow 9/10 — Monitoring"
  cat <<'EOF_STEP'
Open monitoring before heavy tests:
  - sensors watch
  - amdgpu_top
  - GPU governor journal
  - CPU governor journal if the CPU service is active
EOF_STEP
  echo
  monitoring_menu
}

workflow_step_10_status() {
  status_screen
}

recommended_workflow_menu() {
  while true; do
    banner
    title "Guided Workflow — recommended BC250 order"
    echo "This menu is ordered for a fresh Bazzite installation on a BC250 board."
    echo "Steps that change rpm-ostree, kernel args, or ACPI offer a systemctl reboot."
    echo

    section "Phase 0 — preflight before changes"
    menu_item "0" "First Boot Check" "Check kernel/Mesa/BIOS/kargs/ACPI/CU/swap"
    echo

    section "Phase 1 — base system with required reboots"
    menu_item "1" "Run All Base" "Packages + swap/zswap + governor + sleep off -> reboot"
    menu_item "2" "Boot Logo" "quiet+splash+rhgb, remove loglevel=0 -> reboot"
    menu_item "3" "ACPI Fix" "BC250 P-States/cpufreq -> reboot"
    menu_item "4" "NCT6687 Sensors" "VRM/fans/pump/Tctl monitoring"
    echo

    section "Phase 2 — test-first overclocking"
    menu_item "5" "CPU Tools" "Install bc250_smu_oc / bc250-detect"
    menu_item "6" "CPU Tests" "Run tests first; install at boot only after validation"
    menu_item "7" "GPU Tests" "1850 -> 1900 -> 1950 -> 2000 MHz"
    echo

    section "Phase 3 — 40 CU and validation"
    menu_item "8" "40 CU Live" "UMR + bc250-cu-live-manager, live first"
    menu_item "9" "Monitoring" "Sensors, amdgpu_top, journals"
    menu_item "S" "Status" "Full system summary"
    menu_item "R" "Reboot now" "systemctl reboot"
    menu_item "B" "Back" "Return to main menu"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      0) workflow_step_0_preflight ;;
      1) workflow_step_1_base; pause ;;
      2) workflow_step_2_boot_logo; pause ;;
      3) workflow_step_3_acpi; pause ;;
      4) workflow_step_4_sensors; pause ;;
      5) workflow_step_5_cpu_tools; pause ;;
      6) workflow_step_6_cpu_tests ;;
      7) workflow_step_7_gpu_tests ;;
      8) workflow_step_8_40cu ;;
      9) workflow_step_9_monitoring ;;
      [Ss]) workflow_step_10_status ;;
      [Rr]) reboot_now_menu ;;
      [Bb]) return 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main_menu() {
  require_bazzite_atomic

  while true; do
    banner

    section "Start here"
    menu_item "F" "First Boot Check"    "BC250 docs preflight before modifications"
    menu_item "W" "Guided Workflow"     "Complete order with reboots when required"
    echo

    section "Performance"
    menu_item "1" "Performance Profiles" "CPU & GPU performance profiles"
    echo

    section "Setup"
    menu_item "2" "Initial Setup"       "System configuration tasks"
    menu_item "3" "Additional Tools"    "Additional system utilities"
    menu_item "4" "Revert Menu"         "Undo previously applied settings"
    echo

    section "System"
    menu_item "S" "Status"              "Current system summary"
    menu_item "V" "Version Scan"        "Find old toolkit copies in your home"
    menu_item "P" "Path Detection"     "Show detected localized paths and tool locations"
    menu_item "0" "Exit"
    heavy_line
    read -r -p "Enter selection: " choice

    case "$choice" in
      [Ff]) first_boot_preflight ;;
      [Ww]) recommended_workflow_menu ;;
      1) performance_profiles_menu ;;
      2) initial_setup_menu ;;
      3) additional_tools_menu ;;
      4) revert_menu ;;
      [Ss]) status_screen ;;
      [Vv]) version_scan_screen ;;
      [Pp]) path_detection_screen ;;
      0) exit 0 ;;
      *) warn "Invalid selection."; pause ;;
    esac
  done
}

main_menu
