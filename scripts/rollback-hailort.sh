#!/usr/bin/env bash
#
# Undo upgrade-hailort.sh: return a Pi 5 + Hailo-10H from Hailo's HailoRT 5.3.0
# debs to the Raspberry Pi archive's packages.
#
# This only works if upgrade-hailort.sh ran first and its backup directory still
# exists. That directory holds the actual .deb files, not just a list of names —
# the archive is under no obligation to keep serving a version you have stopped
# asking for, and a rollback that needs a remote to cooperate is not a rollback.
#
# What comes back: vision classification, apt managing the packages again, a
# DKMS driver that survives kernel upgrades on its own.
# What goes away: qwen2 captioning, which cannot work below 5.3.0.
#
# USAGE
#
#     ./scripts/rollback-hailort.sh
#     ./scripts/rollback-hailort.sh --backup ~/hailo-rollback
#     ./scripts/rollback-hailort.sh --dry-run
#
set -euo pipefail

BACKUP_DIR="${HOME}/hailo-rollback"
COMPOSE_DIR="${PWD}"
ASSUME_YES=0
DRY_RUN=0

HAILO_PKGS=(hailort hailort-pcie-driver)

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[31m\nERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  read -r -p "    $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "aborted by user"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)      BACKUP_DIR="$2"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown option: $1" ;;
  esac
done

log "Pre-flight"

[[ $EUID -ne 0 ]] || die "run as your normal user, not root"
[[ -d "${BACKUP_DIR}" ]] || die "no backup directory at ${BACKUP_DIR} — pass --backup, or reinstall from the archive by hand: sudo apt install hailo-h10-all"

shopt -s nullglob
DEBS=("${BACKUP_DIR}"/*.deb)
shopt -u nullglob
[[ ${#DEBS[@]} -gt 0 ]] || die "${BACKUP_DIR} contains no .deb files"

info "backup            ${BACKUP_DIR} (${#DEBS[@]} debs)"
[[ -f "${BACKUP_DIR}/state-before.txt" ]] && sed 's/^/    was: /' "${BACKUP_DIR}/state-before.txt"
info "current runtime   $(hailortcli --version 2>/dev/null | head -1 || echo 'not responding')"

confirm "Roll back to the packages in ${BACKUP_DIR}?"

# Nothing may hold /dev/hailo0 while the module is swapped.
if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
  log "Stopping PhoTog"
  run docker compose -f "${COMPOSE_DIR}/docker-compose.yml" down
fi

# ---------------------------------------------------------------------------
# 1. Unhold
# ---------------------------------------------------------------------------
log "Releasing apt holds"
run sudo apt-mark unhold "${HAILO_PKGS[@]}" || true

# ---------------------------------------------------------------------------
# 2. Remove the hand-built driver
#
# The DKMS module has to go before the archive's driver package can own
# hailo1x_pci again. Two modules claiming the same device is the documented
# cause of "sysfs: cannot create duplicate filename '/class/hailo_chardev'",
# which presents as hardware that has stopped existing.
# ---------------------------------------------------------------------------
log "Removing the hand-built DKMS driver"

if [[ $DRY_RUN -eq 0 ]]; then
  sudo modprobe -r hailo1x_pci 2>/dev/null || true

  # `dkms status` prints either "name/version, kernel, arch: installed" (newer)
  # or "name, version, kernel, arch: installed" (older). One expression for
  # both, because guessing which dkms a given Pi OS ships is not worth a bug.
  while read -r mod ver; do
    [[ -n "$mod" && -n "$ver" ]] || continue
    info "dkms remove ${mod}/${ver}"
    sudo dkms remove -m "$mod" -v "$ver" --all || true
  done < <(dkms status 2>/dev/null | grep -i hailo | sed -E 's#^([^/,]+)[/,][[:space:]]*([^,]+),.*#\1 \2#' | sort -u)

  # Whatever DKMS did or did not know about, these are where a stale module
  # hides and keeps winning the probe.
  for d in "/lib/modules/$(uname -r)/updates/dkms" "/lib/modules/$(uname -r)/extra" "/lib/modules/$(uname -r)/kernel/drivers/misc"; do
    sudo rm -f "${d}"/hailo1x_pci.ko* "${d}"/hailo_pci.ko* 2>/dev/null || true
  done
  sudo depmod -a
else
  info "[dry-run] modprobe -r hailo1x_pci; dkms remove hailo*; rm stale .ko; depmod -a"
fi

# ---------------------------------------------------------------------------
# 3. Remove the 5.3.0 packages
# ---------------------------------------------------------------------------
log "Removing HailoRT 5.3.0"

for pkg in "${HAILO_PKGS[@]}"; do
  if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    info "removing ${pkg}"
    run sudo apt-get remove -y "$pkg"
  fi
done

# The 5.3.0 bindings were pip-installed outside dpkg's knowledge, so removing
# the packages leaves them behind to shadow the archive's copy.
if [[ $DRY_RUN -eq 0 ]] && /usr/bin/python3 -m pip show hailort >/dev/null 2>&1; then
  info "removing the pip-installed hailort bindings"
  sudo /usr/bin/python3 -m pip uninstall -y --break-system-packages hailort || true
fi

# ---------------------------------------------------------------------------
# 4. Reinstall the archive packages from the cached debs
#
# dpkg on the cached files rather than `apt install`, so this does not depend on
# the archive still offering that version.
# ---------------------------------------------------------------------------
log "Reinstalling the Raspberry Pi archive packages"

run sudo dpkg --install --auto-deconfigure "${DEBS[@]}"
run sudo apt-get install -f -y
run sudo ldconfig

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
log "Verifying"

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] would run: modinfo hailo1x_pci, hailortcli fw-control identify, import hailo_platform"
  exit 0
fi

FAILED=0
modinfo hailo1x_pci 2>/dev/null | grep -E '^(version|filename)' || { warn "modinfo hailo1x_pci found nothing"; FAILED=1; }
ls -l /dev/hailo[0-9]* /dev/h1x-[0-9]* 2>/dev/null || { warn "no Hailo device node (looked for /dev/hailo[0-9]* and /dev/h1x-[0-9]*)"; FAILED=1; }
hailortcli --version || FAILED=1
sudo hailortcli fw-control identify || { warn "fw-control identify failed"; FAILED=1; }
/usr/bin/python3 -c "import hailo_platform; print('hailo_platform', hailo_platform.__version__)" || FAILED=1

if [[ $FAILED -ne 0 ]]; then
  warn "verification did not fully pass."
  warn "Reboot first — a driver swap without one often looks exactly like this."
  warn "Still failing after a reboot: sudo apt install --reinstall hailo-h10-all"
  warn "No device node and dmesg mentions firmware: reinstall the package owning"
  warn "  /usr/lib/firmware/hailo (dpkg -S). NOT hailofw — that is Hailo-8 firmware."
  exit 1
fi

log "Back on the Raspberry Pi archive HailoRT"
info "Reboot when convenient — the driver was swapped underneath a running kernel."
info ""
warn "YOUR .env IS NOW STALE — the libhailort soname changed back."
info "  cd ${COMPOSE_DIR}"
info "  # delete the old HAILO_GID / HAILO_PYTHON_PACKAGE / HAILORT_* lines from .env"
info "  ./scripts/hailo-detect.sh --append"
info "  docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d"
info ""
info "qwen2 will not work on this runtime and should stay disabled."
info "Vision classifiers are unaffected — their HEFs may be newer builds and the"
info "low-level path loads them regardless of SDK version."
