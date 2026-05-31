#!/usr/bin/env bash
# rebuild-tun-from-mainline.sh — repair broken vendor tun.ko on Firefly /
# Rockchip / Radxa aarch64 SDK images (kernel build/.config inconsistency
# making the shipped tun.ko unloadable). Rebuilds tun.ko from upstream
# Linux source matching the booted kernel; optionally flips tailscaled
# out of --tun=userspace-networking. Idempotent install + clean uninstall.
# Tested on Firefly RK3588 (EC-R3588SPC) Ubuntu 22.04 / kernel 6.1.84.

set -euo pipefail

SCRIPT_NAME="rebuild-tun-from-mainline"
PATCH_VERSION="1.2.0"
REQUIRED_ARCH="aarch64"

KVER=$(uname -r)
KARCH=$(uname -m)
KBASE=$(printf '%s' "$KVER" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
KMM=$(printf '%s' "${KBASE:-}" | cut -d. -f1-2)

MAINLINE_TUN_URL_TEMPLATE="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/net/tun.c?h=v%s"

TUN_KO_LIVE="/lib/modules/${KVER}/kernel/drivers/net/tun.ko"
TUN_KO_BACKUP="${TUN_KO_LIVE}.bak.${SCRIPT_NAME}"
TAILSCALED_DEFAULTS="/etc/default/tailscaled"
TAILSCALED_DEFAULTS_BACKUP="${TAILSCALED_DEFAULTS}.bak.${SCRIPT_NAME}"
MODLOAD_CONF="/etc/modules-load.d/${SCRIPT_NAME}.conf"
MARKER_DIR="/var/lib/${SCRIPT_NAME}"
MARKER="${MARKER_DIR}/installed"
BUILD_DIR="/tmp/${SCRIPT_NAME}-build"
BUILD_LOG="${BUILD_DIR}/build.log"

BUILD_DEPS=(gcc make flex bison libelf-dev libssl-dev bc cpio)

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_RED= C_GREEN= C_YELLOW= C_CYAN= C_DIM= C_BOLD= C_RESET=
fi

# All user-facing log helpers write to stderr so that $(...) capture
# of a function's printf '%s' "$value" return remains uncontaminated.
info() { printf '%s%s%s %s\n' "$C_CYAN" "==>" "$C_RESET" "$*" >&2; }
ok()   { printf '%s%s%s %s\n' "$C_GREEN" "[ok]"  "$C_RESET" "$*" >&2; }
warn() { printf '%s%s%s %s\n' "$C_YELLOW" "[!] " "$C_RESET" "$*" >&2; }
err()  { printf '%s%s%s %s\n' "$C_RED" "[err]" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} v${PATCH_VERSION}

Repairs broken vendor-shipped tun.ko on Firefly / Rockchip aarch64 SDK
images by rebuilding it from upstream Linux source matching the booted
kernel, and (optionally) flipping tailscaled out of userspace-networking.

Auto-detects the running kernel (currently: ${KVER:-unknown} / ${KARCH:-unknown}).
Works on any stable kernel that has a matching ${C_BOLD}vX.Y.Z${C_RESET} tag on kernel.org.

${C_BOLD}Usage:${C_RESET}
  ${0##*/}                     interactive (install or uninstall by state)
  ${0##*/} -y | --yes          silent install (idempotent — no-op if installed)
  ${0##*/} --uninstall         interactive uninstall
  ${0##*/} --uninstall -y      silent uninstall
  ${0##*/} --check             detect state only, no changes
  ${0##*/} -h | --help         show this help

${C_BOLD}Exit codes:${C_RESET}
  0   success / nothing to do
  1   precondition failed (wrong device, missing files)
  2   install or uninstall failed (system rolled back where possible)
  3   user declined an interactive prompt
EOF
}

MODE=auto            # auto | uninstall | check
ASSUME_YES=0

while (( $# )); do
  case "$1" in
    -y|--yes)      ASSUME_YES=1 ;;
    --uninstall)   MODE=uninstall ;;
    --check)       MODE=check ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root (try: sudo $0 $*)"
}

is_supported_env() {
  [[ "$KARCH" == "$REQUIRED_ARCH" ]] || return 1
  [[ -n "$KBASE" ]]                  || return 1
  [[ -r /proc/version ]]             || return 1
  grep -qiE "rk3[0-9]{3}|rockchip|firefly|radxa" /proc/version || return 1
  return 0
}

# Echoes one of: unsupported | broken | patched | not-affected
detect_state() {
  is_supported_env || { echo "unsupported"; return; }
  [[ -f $MARKER ]]   && { echo "patched";     return; }

  # tun already loaded → fine
  if lsmod 2>/dev/null | awk '{print $1}' | grep -qx tun; then
    echo "not-affected"; return
  fi
  # try a real modprobe (no error noise)
  if modprobe tun 2>/dev/null; then
    echo "not-affected"; return
  fi
  echo "broken"
}

read_marker_field() {
  local field=$1
  [[ -f $MARKER ]] || return 1
  awk -F= -v f="$field" '$1==f { sub(/^[^=]+=/,""); print; exit }' "$MARKER"
}

show_marker() {
  [[ -f $MARKER ]] || return
  printf '%s' "$C_DIM"
  sed 's/^/    /' "$MARKER"
  printf '%s' "$C_RESET"
}

confirm() {
  local prompt=$1 ans
  printf "%s [y/N] " "$prompt"
  read -r ans || ans=
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

# Returns the source tree path linked from /lib/modules/${KVER}/build
# (only succeeds if the symlink points to an existing directory)
find_headers_dir() {
  local symlink="/lib/modules/${KVER}/build"
  [[ -L "$symlink" ]] || return 1
  local target
  target=$(readlink -f "$symlink") || return 1
  [[ -d "$target" ]] || return 1
  printf '%s' "$target"
}

# Scans /boot for a headers .deb whose name suggests it matches the kernel
# Patterns tried, most-specific to least-specific.
find_headers_deb() {
  local patterns=(
    "/boot/linux-headers-${KMM}-${REQUIRED_ARCH/aarch64/arm64}_*.deb"
    "/boot/linux-headers-${KMM}_*.deb"
    "/boot/linux-headers-${KMM}*.deb"
    "/boot/linux-headers-${KBASE}*.deb"
    "/boot/linux-headers-*${KMM}*.deb"
    "/boot/linux-headers*.deb"
  )
  local pat match
  for pat in "${patterns[@]}"; do
    for match in $(compgen -G "$pat" 2>/dev/null); do
      [[ -f "$match" ]] && { printf '%s' "$match"; return 0; }
    done
  done
  return 1
}

ensure_headers() {
  if find_headers_dir >/dev/null; then return 0; fi
  local deb
  if deb=$(find_headers_deb); then
    info "installing kernel headers package: $deb"
    dpkg -i "$deb" >>"$BUILD_LOG" 2>&1 \
      || die "dpkg -i $deb failed (see $BUILD_LOG)"
    find_headers_dir >/dev/null \
      || die "headers installed but /lib/modules/${KVER}/build still missing"
    return 0
  fi
  die "no kernel headers found. tried:
    /lib/modules/${KVER}/build (symlink to source tree)
    /boot/linux-headers-${KMM}*.deb (vendor headers package)
on Firefly / Rockchip SDK images, the headers .deb is usually shipped at /boot/.
if your image doesn't include it, fetch the matching package from the vendor."
}

ensure_build_deps() {
  local missing=() p
  for p in "${BUILD_DEPS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  (( ${#missing[@]} == 0 )) && return 0
  info "installing build deps: ${missing[*]}..."
  apt-get update >>"$BUILD_LOG" 2>&1 || true
  apt-get install -y "${missing[@]}" >>"$BUILD_LOG" 2>&1 \
    || die "apt-get install failed for: ${missing[*]} (see $BUILD_LOG)"
}

# Probes whether vX.Y.Z exists on kernel.org stable; if not, the source
# fetch will fail outright with a more user-friendly message.
probe_mainline_tag() {
  local url
  printf -v url "$MAINLINE_TUN_URL_TEMPLATE" "$KBASE"
  if command -v curl >/dev/null 2>&1; then
    curl -fsI "$url" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget --spider -q "$url"
  else
    die "neither curl nor wget is installed"
  fi
}

download_tun_c() {
  local dest=$1 url
  printf -v url "$MAINLINE_TUN_URL_TEMPLATE" "$KBASE"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSLo "$dest" "$url" || die "download failed (curl): $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url" || die "download failed (wget): $url"
  else
    die "neither curl nor wget is installed"
  fi
  [[ -s "$dest" ]] || die "downloaded tun.c is empty"
  head -1 "$dest" | grep -q "SPDX-License-Identifier" \
    || die "downloaded file doesn't look like upstream tun.c"
}

inject_config_tun() {
  local headers_dir=$1
  local autoconf_h="$headers_dir/include/generated/autoconf.h"
  local auto_conf="$headers_dir/include/config/auto.conf"
  [[ -f "$autoconf_h" ]] || die "missing $autoconf_h (headers tree is incomplete)"
  [[ -f "$auto_conf"  ]] || die "missing $auto_conf (headers tree is incomplete)"
  grep -q "^#define CONFIG_TUN_MODULE" "$autoconf_h" \
    || echo "#define CONFIG_TUN_MODULE 1" >> "$autoconf_h"
  grep -q "^CONFIG_TUN=" "$auto_conf" \
    || echo "CONFIG_TUN=m" >> "$auto_conf"
}

build_tun_ko() {
  local headers_dir=$1
  info "building tun.ko (this takes ~30-60 s)..."
  ( cd "$headers_dir" && make -s M=drivers/net tun.ko ) >>"$BUILD_LOG" 2>&1 \
    || die "build failed; see $BUILD_LOG"
  [[ -f "$headers_dir/drivers/net/tun.ko" ]] \
    || die "build claimed success but no tun.ko produced"
}

install_tun_ko() {
  local headers_dir=$1
  if [[ ! -f $TUN_KO_BACKUP ]]; then
    if [[ -f $TUN_KO_LIVE ]]; then
      cp -a "$TUN_KO_LIVE" "$TUN_KO_BACKUP" \
        || die "failed to back up $TUN_KO_LIVE"
    fi
  fi
  install -D -m 0644 "$headers_dir/drivers/net/tun.ko" "$TUN_KO_LIVE" \
    || die "failed to install new tun.ko"
  depmod -a
  if ! modprobe tun 2>/dev/null; then
    err "modprobe tun failed after install; rolling back"
    if [[ -f $TUN_KO_BACKUP ]]; then
      cp -a "$TUN_KO_BACKUP" "$TUN_KO_LIVE"
      rm -f "$TUN_KO_BACKUP"
    else
      rm -f "$TUN_KO_LIVE"
    fi
    depmod -a
    die "rollback complete; original state restored"
  fi
  echo "tun" > "$MODLOAD_CONF"
}

maybe_flip_tailscaled() {
  local patched=no
  if [[ -f $TAILSCALED_DEFAULTS ]] \
     && grep -q -- "--tun=userspace-networking" "$TAILSCALED_DEFAULTS"; then
    info "switching tailscaled from userspace-networking to kernel-tun mode..."
    [[ -f $TAILSCALED_DEFAULTS_BACKUP ]] \
      || cp -a "$TAILSCALED_DEFAULTS" "$TAILSCALED_DEFAULTS_BACKUP"
    sed -i -E 's|(^FLAGS=.*)--tun=userspace-networking[[:space:]]*|\1|' \
      "$TAILSCALED_DEFAULTS"
    sed -i -E 's|^(FLAGS=)"[[:space:]]+"|\1""|' "$TAILSCALED_DEFAULTS"
    if systemctl is-active tailscaled >/dev/null 2>&1; then
      systemctl restart tailscaled \
        || warn "tailscaled restart failed; tun module is installed regardless"
    fi
    patched=yes
  fi
  printf '%s' "$patched"
}

write_marker() {
  local patched_tailscaled=$1
  mkdir -p "$MARKER_DIR"
  cat > "$MARKER" <<EOF
patch_version=${PATCH_VERSION}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kernel=${KVER}
kernel_base=${KBASE}
arch=${KARCH}
backup_tun=${TUN_KO_BACKUP}
backup_tailscaled_defaults=${TAILSCALED_DEFAULTS_BACKUP}
patched_tailscaled=${patched_tailscaled}
modload_conf=${MODLOAD_CONF}
EOF
}

show_post_install_state() {
  info "post-install state:"
  lsmod | awk '$1=="tun" { printf "    lsmod: %s\n", $0 }'
  if ip link show tailscale0 >/dev/null 2>&1; then
    printf "    tailscale0: %s\n" "$(ip -br a show tailscale0 | awk '{$1=$1};1')"
  fi
}

do_install() {
  require_root
  mkdir -p "$BUILD_DIR"
  : > "$BUILD_LOG"

  info "target: kernel ${KVER} (base v${KBASE}) on ${KARCH}"

  info "checking upstream kernel.org has tag v${KBASE}..."
  probe_mainline_tag \
    || die "no v${KBASE} tag on kernel.org/stable. either the kernel is too old/new,
or the version string is non-standard. expected uname -r to start with X.Y.Z
matching a stable release tag."

  info "preparing build environment"
  ensure_headers
  ensure_build_deps

  local headers_dir
  headers_dir=$(find_headers_dir) || die "headers dir disappeared between checks"

  info "downloading upstream drivers/net/tun.c (v${KBASE})"
  download_tun_c "$BUILD_DIR/tun.c"

  cp "$BUILD_DIR/tun.c" "$headers_dir/drivers/net/tun.c"
  inject_config_tun "$headers_dir"

  build_tun_ko "$headers_dir"
  install_tun_ko "$headers_dir"

  local patched_tailscaled
  patched_tailscaled=$(maybe_flip_tailscaled)

  write_marker "$patched_tailscaled"

  ok "install complete (patch v${PATCH_VERSION}, kernel ${KVER})"
  show_post_install_state
}

do_uninstall() {
  require_root
  [[ -f $MARKER ]] || die "this patch is not installed (no marker at $MARKER)"

  local backup_tun backup_tsd patched_tsd modload_conf marker_kver
  backup_tun=$(read_marker_field backup_tun || true)
  backup_tsd=$(read_marker_field backup_tailscaled_defaults || true)
  patched_tsd=$(read_marker_field patched_tailscaled || true)
  modload_conf=$(read_marker_field modload_conf || true)
  marker_kver=$(read_marker_field kernel || true)

  if [[ -n "$marker_kver" && "$marker_kver" != "$KVER" ]]; then
    warn "marker was written for kernel '$marker_kver' but you booted '$KVER'."
    warn "uninstall will still proceed using paths recorded in the marker."
  fi

  info "rolling back patch"

  # 1. restore tailscaled defaults first so the restart re-applies userspace mode
  if [[ "$patched_tsd" == "yes" && -n "$backup_tsd" && -f "$backup_tsd" ]]; then
    info "restoring $TAILSCALED_DEFAULTS"
    cp -a "$backup_tsd" "$TAILSCALED_DEFAULTS"
  fi

  # 2. remove boot-time load entry
  if [[ -n "$modload_conf" && -f "$modload_conf" ]]; then
    rm -f "$modload_conf"
  fi

  # 3. restore original (broken) tun.ko if backed up
  if [[ -n "$backup_tun" && -f "$backup_tun" ]]; then
    info "restoring tun.ko from $backup_tun"
    cp -a "$backup_tun" "$TUN_KO_LIVE"
    depmod -a
  else
    warn "tun.ko backup missing — leaving rebuilt module in place"
  fi

  # 4. unload current tun module (best effort)
  if lsmod 2>/dev/null | awk '{print $1}' | grep -qx tun; then
    rmmod tun 2>/dev/null \
      || warn "couldn't unload tun module (in use); reboot to fully revert"
  fi

  # 5. restart tailscaled so it picks up userspace-networking again
  if [[ "$patched_tsd" == "yes" ]] && systemctl is-active tailscaled >/dev/null 2>&1; then
    systemctl restart tailscaled || warn "tailscaled restart failed"
  fi

  # 6. remove backups and marker
  [[ -n "$backup_tun" && -f "$backup_tun" ]] && rm -f "$backup_tun"
  [[ -n "$backup_tsd" && -f "$backup_tsd" ]] && rm -f "$backup_tsd"
  rm -f "$MARKER"
  rmdir "$MARKER_DIR" 2>/dev/null || true

  ok "uninstall complete; system restored to pre-patch state"
}

STATE=$(detect_state)

case "$MODE" in
  check)
    printf "state:        %s\n" "$STATE"
    printf "kernel:       %s\n" "${KVER:-?}"
    printf "kernel_base:  %s\n" "${KBASE:-?}"
    printf "arch:         %s\n" "${KARCH:-?}"
    if is_supported_env; then
      local_hdir=$(find_headers_dir 2>/dev/null || true)
      if [[ -n "${local_hdir:-}" ]]; then
        printf "headers_dir:  %s\n" "$local_hdir"
      else
        local_deb=$(find_headers_deb 2>/dev/null || true)
        if [[ -n "${local_deb:-}" ]]; then
          printf "headers_deb:  %s  ${C_DIM}(not yet installed)${C_RESET}\n" "$local_deb"
        else
          printf "headers_dir:  ${C_YELLOW}NOT FOUND${C_RESET} (won't be able to build)\n"
        fi
      fi
    fi
    case "$STATE" in
      patched)      printf 'marker:\n'; show_marker ;;
      unsupported)  printf "reason:       not a Firefly/Rockchip aarch64 system with parseable uname -r\n" ;;
    esac
    exit 0
    ;;

  uninstall)
    case "$STATE" in
      unsupported)   warn "this device isn't a supported target; nothing to do"; exit 0 ;;
      not-affected)  warn "tun module works on this system but no marker exists; nothing to uninstall"; exit 0 ;;
      broken)        warn "patch is not installed (tun is broken); nothing to uninstall"; exit 0 ;;
      patched)
        if (( ASSUME_YES )); then
          do_uninstall
        else
          info "the patch is currently installed:"
          show_marker
          echo
          confirm "Uninstall now?" || { info "declined"; exit 3; }
          do_uninstall
        fi
        ;;
    esac
    ;;

  auto)
    case "$STATE" in
      unsupported)
        info "not a supported target (need Firefly/Rockchip aarch64 with parseable kernel version)"
        exit 0
        ;;
      not-affected)
        info "tun module loads successfully — your system is not affected"
        exit 0
        ;;
      patched)
        if (( ASSUME_YES )); then
          info "patch already installed (v$(read_marker_field patch_version)) — nothing to do"
          exit 0
        fi
        info "the patch is currently installed:"
        show_marker
        echo
        confirm "Uninstall this patch?" || { info "declined"; exit 3; }
        do_uninstall
        ;;
      broken)
        if (( ASSUME_YES )); then
          do_install
          exit 0
        fi
        info "tun module is broken on this system (likely a vendor build inconsistency)"
        echo
        confirm "Install the patch now?" || { info "declined"; exit 3; }
        do_install
        ;;
    esac
    ;;
esac
