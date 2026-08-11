#!/usr/bin/env bash
#
# Move a Raspberry Pi 5 + Hailo-10H from the Raspberry Pi archive's HailoRT
# 5.1.1 to Hailo's own 5.3.0 debs.
#
# ONLY FOR A HAILO-10H. 4.x is the Hailo-8 stack, 5.x is the Hailo-10H stack.
# They are not a version ladder — they are two products, and running this on a
# Hailo-8 breaks it in ways that take hours to unpick. The script checks the
# device and refuses; do not talk yourself past that check.
#
# WHY THIS EXISTS
#
#   Every VLM HEF is compiled with SDK 5.3.0, and Hailo publishes no VLM below
#   it. The vision models load on 5.1.1 anyway — the low-level path does not
#   check the SDK version — but the GenAI wrapper validates it up front and
#   rejects with HAILO_INVALID_OPERATION(6), naming neither the version nor the
#   file. So `qwen2` captioning cannot work on the archive's 5.1.1 and there is
#   nothing to downgrade to. Upgrading the runtime is the only route.
#
#   Detection and classification already work at 5.1.1 and gain nothing here.
#   If you do not want captioning, do not run this.
#
# WHAT YOU ARE TRADING AWAY
#
#   1. apt stops managing this. The Pi archive ships `h10-hailort`; Hailo ships
#      `hailort`. They cannot coexist, so this removes the former. Afterwards
#      apt sees `hailort` with an archive candidate of 4.23.0 — a HAILO-8
#      runtime — sitting BELOW what you installed. One stray `apt upgrade`
#      reinstates it and reproduces the exact failure this fixes. The script
#      holds the packages; do not unhold them casually.
#
#   2. The PCIe driver stops being DKMS-from-apt and may become a module built
#      from an unmerged pull request. Every kernel upgrade, you rebuild it. A
#      kernel bump that silently fails to rebuild looks like dead hardware.
#
# YOU SUPPLY THE PACKAGES
#
#   Hailo's Developer Zone requires a login, so this script cannot fetch them.
#   Download into one directory, default ~/hailo-5.3.0:
#
#       hailort_5.3.0_arm64.deb
#       hailort-pcie-driver_5.3.0_all.deb
#       hailort-5.3.0-cp313-cp313-linux_aarch64.whl   <- match your python
#
#   The python bindings are NOT in the runtime deb. Without them you end up
#   with a working accelerator no python can talk to — which is the shape of
#   failure this script exists to prevent, so it checks before removing
#   anything.
#
# ROLLBACK
#
#   rollback-hailort.sh, next to this file. It only works if this script ran
#   first, because this is what caches the 5.1.1 debs. Do not skip the backup.
#
# USAGE
#
#       ./scripts/upgrade-hailort.sh --debs ~/hailo-5.3.0
#       ./scripts/upgrade-hailort.sh --dry-run
#       ./scripts/upgrade-hailort.sh --yes
#
set -euo pipefail

VERSION="5.3.0"
DEB_DIR="${HOME}/hailo-${VERSION}"
BACKUP_DIR="${HOME}/hailo-rollback"
DRIVER_SRC="${HOME}/hailort-drivers"
COMPOSE_DIR="${PWD}"
ASSUME_YES=0
DRY_RUN=0
FORCE_ARCH=0

# Packages the Raspberry Pi archive installs, which Hailo's debs replace.
RPI_PKGS=(hailo-h10-all h10-hailort h10-hailort-pcie-driver python3-h10-hailort hailo-gen-ai-model-zoo)
# What we hold afterwards so apt cannot walk us back to the 4.23 Hailo-8 runtime.
HOLD_PKGS=(hailort hailort-pcie-driver)

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
    --debs)          DEB_DIR="$2"; shift 2 ;;
    --backup)        BACKUP_DIR="$2"; shift 2 ;;
    --compose-dir)   COMPOSE_DIR="$2"; shift 2 ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --i-know-this-is-not-a-hailo10h) FORCE_ARCH=1; shift ;;
    -h|--help)       sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 0. Pre-flight
#
# Everything checkable is checked BEFORE anything is removed. A half-upgraded
# box with no runtime and no driver is the worst resting state there is, and it
# is entirely avoidable: the debs either exist now or they do not.
# ---------------------------------------------------------------------------
log "Pre-flight"

[[ $EUID -ne 0 ]] || die "run as your normal user, not root — this uses sudo where it needs to, and \$HOME must be yours"
command -v sudo >/dev/null || die "sudo not found"
[[ "$(uname -m)" == "aarch64" ]] || die "expected aarch64, found $(uname -m)"

KERNEL="$(uname -r)"
info "kernel            ${KERNEL}"
info "python3           $(/usr/bin/python3 -V 2>&1)"

if command -v hailortcli >/dev/null; then
  info "current runtime   $(hailortcli --version 2>/dev/null | head -1)"
else
  warn "hailortcli not found — is HailoRT installed at all?"
fi

# --- the guard that matters -------------------------------------------------
#
# Ask the device, not the user. A Hailo-8 put on the 5.x line presents as
# HAILO_STREAM_NOT_ACTIVATED(72) and HAILO_STREAM_ABORT(63) mid-inference,
# which reads as an application bug, and unpicking it takes an evening. There
# is no reason to run this script on one: captioning is Hailo-10H only.
IDENT="$(sudo hailortcli fw-control identify 2>/dev/null || true)"
DEVICE_ARCH="$(printf '%s' "$IDENT" | grep -iE 'Device Architecture' | head -1 | awk -F: '{gsub(/ /,"",$2); print $2}')"

if [[ -n "$DEVICE_ARCH" ]]; then
  info "device            ${DEVICE_ARCH}"
  case "$DEVICE_ARCH" in
    *HAILO10H*|*HAILO15H*) ;;
    *)
      if [[ $FORCE_ARCH -eq 0 ]]; then
        die "this device reports ${DEVICE_ARCH}, not HAILO10H.

  HailoRT 4.x is the Hailo-8 stack and 5.x is the Hailo-10H stack. They are
  two products, not two versions. Installing 5.3.0 here will break a working
  accelerator, and captioning — the only reason to run this — needs a
  Hailo-10H regardless.

  Nothing has been changed."
      fi
      warn "device is ${DEVICE_ARCH} and you overrode the check. This is a bad idea."
      confirm "Really continue on a ${DEVICE_ARCH}?"
      ;;
  esac
else
  warn "could not read the device architecture from 'hailortcli fw-control identify'."
  warn "That is itself worth fixing before an upgrade — see docs/hailo.md."
  confirm "Continue without confirming this is a Hailo-10H?"
fi

# Developer Zone filenames drift between releases, and making someone rename
# files to satisfy a script is a good way to have them rename the wrong one.
# Match on shape, then report what was actually found.
find_deb() {
  local label="$1" pattern="$2" matches
  shopt -s nullglob
  # shellcheck disable=SC2206
  matches=("${DEB_DIR}"/${pattern})
  shopt -u nullglob

  [[ ${#matches[@]} -gt 0 ]] || die "no ${label} deb matching '${pattern}' in ${DEB_DIR} — download it from the Hailo Developer Zone first"
  [[ ${#matches[@]} -eq 1 ]] || die "${#matches[@]} files match '${pattern}' in ${DEB_DIR}; leave exactly one"

  printf '%s' "${matches[0]}"
}

RUNTIME_DEB="$(find_deb runtime "hailort_*${VERSION}*arm64.deb")"
DRIVER_DEB="$(find_deb driver "hailort-pcie-driver*${VERSION}*.deb")"
info "runtime deb       $(basename "${RUNTIME_DEB}")"
info "driver deb        $(basename "${DRIVER_DEB}")"

shopt -s nullglob
EXTRA_DEBS=()
for d in "${DEB_DIR}"/*.deb; do
  [[ "$d" == "${RUNTIME_DEB}" || "$d" == "${DRIVER_DEB}" ]] && continue
  EXTRA_DEBS+=("$d")
done
shopt -u nullglob
[[ ${#EXTRA_DEBS[@]} -gt 0 ]] && info "also installing    ${#EXTRA_DEBS[@]} additional deb(s)"

# The bindings are compiled for one CPython minor version. In a Docker setup
# this matters twice: once for the host, and once because the compose overlay
# mounts them into the container's interpreter, which is Python 3.13.
PY_MINOR="$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PY_TAG="cp$(/usr/bin/python3 -c 'import sys; print("%d%d" % sys.version_info[:2])')"
info "python tag        ${PY_TAG} (python ${PY_MINOR})"

# Phase 2 removes python3-h10-hailort, and the runtime deb does NOT put the
# bindings back — hailort_5.3.0_arm64.deb ships libhailort and hailortcli only.
# Without a bindings artefact here the end state is a working device no python
# can talk to. Checked before anything is removed.
shopt -s nullglob
BINDINGS=("${DEB_DIR}"/python3-hailort*.deb "${DEB_DIR}"/*"${PY_TAG}"*.whl)
OTHER_WHEELS=("${DEB_DIR}"/*.whl)
shopt -u nullglob

if [[ ${#BINDINGS[@]} -eq 0 ]]; then
  warn "no python bindings for ${PY_TAG} in ${DEB_DIR}."
  if [[ ${#OTHER_WHEELS[@]} -gt 0 ]]; then
    warn "  found $(basename "${OTHER_WHEELS[0]}") — that is the wrong python build."
  fi
  warn "hailo_platform will be MISSING after this runs, every classifier will fail"
  warn "at import, and the container mount will have nothing to mount."
  confirm "Continue anyway?"
else
  info "bindings          $(basename "${BINDINGS[0]}")"
fi

if [[ -d /usr/share/hailo-ollama/models/blob ]]; then
  warn "hailo-ollama has $(du -sh /usr/share/hailo-ollama/models/blob 2>/dev/null | cut -f1) of models in"
  warn "  /usr/share/hailo-ollama/models/blob — a model-zoo removal is known to DELETE"
  warn "  that directory. Copy it out if you care about it."
fi

info ""
info "Photog's own HEFs are not at risk — they are on a host directory and are"
info "re-fetchable with scripts/download-models.sh."

confirm "Proceed?"

# ---------------------------------------------------------------------------
# 0b. Stop the stack
#
# A container holding /dev/hailo0 across a module swap is asking for a device
# that cannot be released and a modprobe -r that will not complete.
# ---------------------------------------------------------------------------
if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] && command -v docker >/dev/null 2>&1; then
  log "Stopping Photog while the driver changes underneath it"
  run docker compose -f "${COMPOSE_DIR}/docker-compose.yml" down
  info "volumes and photos are untouched by 'down'"
else
  warn "no docker-compose.yml in ${COMPOSE_DIR} — stop anything using /dev/hailo0 yourself"
  warn "  fuser -v /dev/hailo0"
  confirm "Nothing is holding the device?"
fi

# ---------------------------------------------------------------------------
# 1. Backup
#
# apt download, not just a package list: the archive is under no obligation to
# keep serving 5.1.1, and a rollback that depends on a remote still having the
# version you need is not a rollback.
# ---------------------------------------------------------------------------
log "Backing up the current packages to ${BACKUP_DIR}"

run mkdir -p "${BACKUP_DIR}"
if [[ $DRY_RUN -eq 0 ]]; then
  dpkg -l | grep -i hailo > "${BACKUP_DIR}/packages-before.txt" || true
  { echo "kernel: ${KERNEL}"; hailortcli --version 2>/dev/null || true; } > "${BACKUP_DIR}/state-before.txt"
  ( cd "${BACKUP_DIR}" && apt-get download "${RPI_PKGS[@]}" ) \
    || warn "apt download did not fetch every package — check ${BACKUP_DIR} before continuing"
fi
info "wrote packages-before.txt, state-before.txt and the .deb cache"

confirm "Backup looks right? Removing packages next — this is the point of no easy return."

# ---------------------------------------------------------------------------
# 2. Remove the Raspberry Pi archive packages
#
# h10-hailort declares Conflicts/Replaces on hailort but not Provides, so
# letting apt resolve this itself is how people end up with the 4.23 Hailo-8
# runtime installed and the H10 packages auto-removed. Explicit removal first,
# explicit install second, no resolver involved.
# ---------------------------------------------------------------------------
log "Removing Raspberry Pi archive HailoRT packages"

for pkg in "${RPI_PKGS[@]}"; do
  if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    info "removing ${pkg}"
    run sudo apt-get remove -y "$pkg"
  else
    info "not installed: ${pkg}"
  fi
done

# ---------------------------------------------------------------------------
# 3. Install Hailo's 5.3.0 debs
# ---------------------------------------------------------------------------
log "Installing HailoRT ${VERSION}"

# The driver deb's postinst builds the kernel module, and on 6.15+ it fails —
# that is the whole reason phase 4 exists. So dpkg is EXPECTED to return
# non-zero here, and `set -e` aborting on it would strand the box exactly
# between "old packages removed" and "new driver built", the one state this
# script is written to avoid.
if ! run sudo dpkg --install --auto-deconfigure \
  "${DRIVER_DEB}" "${RUNTIME_DEB}" ${EXTRA_DEBS[@]+"${EXTRA_DEBS[@]}"}; then
  warn "dpkg reported errors — expected if the driver postinst could not build the module"
  warn "see /var/log/hailort-pcie-driver.deb.log; phase 4 is the remedy"
fi

if [[ $DRY_RUN -eq 0 ]] && ! dpkg -l hailort 2>/dev/null | grep -q '^ii'; then
  die "the hailort runtime did not configure. This is not the expected driver-build failure — read the dpkg output above, then run rollback-hailort.sh"
fi

# Deliberately NOT `apt-get install -f -y` here: with the driver package
# half-configured, apt's idea of "fix" can be to remove it, taking the 5.3.0
# firmware with it. Phase 4 settles the package instead.
run sudo ldconfig

# ---------------------------------------------------------------------------
# 3b. The python bindings
#
# --no-deps is load-bearing: pip would otherwise drag in its own numpy over the
# system one hailo_platform was compiled against, and the result is an ABI error
# at import that reads like a broken install rather than a numpy conflict.
# ---------------------------------------------------------------------------
if [[ ${#BINDINGS[@]} -gt 0 && "${BINDINGS[0]}" == *.whl ]]; then
  log "Installing the python bindings wheel"
  info "$(basename "${BINDINGS[0]}")"
  run sudo /usr/bin/python3 -m pip install --break-system-packages --no-deps "${BINDINGS[0]}"
fi

# ---------------------------------------------------------------------------
# 4. Build the PCIe driver
#
# The driver shipped in the deb does not build on recent kernels. We try the
# clean build first and only fall back to the PR, so this stops doing anything
# the day upstream catches up.
# ---------------------------------------------------------------------------
log "Building the hailo1x_pci driver"

run sudo apt-get install -y build-essential dkms git "linux-headers-${KERNEL}"

if [[ $DRY_RUN -eq 0 ]]; then
  # Patch the source the deb already shipped and let its own postinst finish.
  # That leaves the module DKMS-managed, so kernel upgrades rebuild it without
  # a human — which the PR route does not.
  #
  # The deb lays down TWO source trees: the DKMS one (hailo1x_pci-<version>)
  # and a plain build tree (hailort-pcie-driver). The postinst tries DKMS first
  # and falls back to the other, so patching only one leaves the fallback to
  # fail on the same line.
  shopt -s nullglob
  DRIVER_TREES=(/usr/src/hailo1x_pci-*/ /usr/src/hailort-pcie-driver*/)
  shopt -u nullglob

  # del_timer/del_timer_sync were renamed timer_delete/timer_delete_sync in
  # kernels >= 6.15 and the old names are GONE, not deprecated — the build fails
  # with "implicit declaration of function". Both are replaced: fixing only the
  # one the compiler reached first means hitting the other on the next pass. \b
  # means neither substitution can corrupt the other.
  if [[ ${#DRIVER_TREES[@]} -gt 0 ]]; then
    TIMER_FILES="$(sudo grep -rl 'del_timer_sync\|\bdel_timer\b' "${DRIVER_TREES[@]}" 2>/dev/null || true)"
    if [[ -n "${TIMER_FILES}" ]]; then
      info "patching del_timer* -> timer_delete* for kernel ${KERNEL}"
      # shellcheck disable=SC2086
      sudo sed -i 's/\bdel_timer_sync\b/timer_delete_sync/g; s/\bdel_timer\b/timer_delete/g' ${TIMER_FILES}
    fi
  fi

  sudo dpkg --configure hailort-pcie-driver 2>&1 | tail -5 || true

  # `modinfo` finding a module of the right name is NOT evidence the new one was
  # installed, and gating on it here is a bug that cost a real evening: the
  # archive's 5.1.1 module was still on disk, modinfo succeeded, the fallback
  # build route was skipped, the OLD module was loaded, a device node appeared,
  # and verification passed. The upgrade "worked" and the driver was the wrong
  # one — which surfaced only after a reboot, as hardware that had vanished.
  #
  # DKMS is the honest source. `added` means the source is registered and was
  # never built; only `installed` means there is a .ko on disk for this kernel.
  DKMS_STATE="$(dkms status 2>/dev/null | grep -i hailo | head -1)"
  info "dkms: ${DKMS_STATE:-nothing registered}"

  if [[ "$DKMS_STATE" == *installed* ]]; then
    info "the shipped driver built after patching — skipping the PR route"
    # The pre-upgrade module is still resident — that is why the device kept
    # working through all of this — and will keep serving until unloaded.
    sudo modprobe -r hailo1x_pci hailo1x 2>/dev/null || true
    sudo depmod -a
    sudo modprobe -v hailo1x_pci 2>/dev/null || sudo modprobe -v hailo1x || true

    # Check the version of what is actually loaded now. A module of the right
    # name is not evidence it is the one just built.
    LOADED_VER="$(modinfo -F version hailo1x_pci 2>/dev/null || modinfo -F version hailo1x 2>/dev/null || echo unknown)"
    info "loaded driver version ${LOADED_VER}"
    if [[ "${LOADED_VER}" != "${VERSION}"* ]]; then
      # Fatal, not a warning. Carrying on here is how the wrong driver survives
      # to the end of the script wearing a green tick.
      die "expected driver ${VERSION}, loaded ${LOADED_VER}.

  The old module is probably still winning. Check:
      dkms status ; uname -r
      find /lib/modules/\$(uname -r) -iname '*hailo*'

  Nothing is broken — the packages are in place and the build is the only
  step left. Do NOT roll back for this."
    fi
    SKIP_PR=1
  else
    warn "dkms reports '${DKMS_STATE:-nothing}', not 'installed' — the module was not built"
  fi
fi

if [[ $DRY_RUN -eq 0 && "${SKIP_PR:-0}" != "1" ]]; then
  warn "the shipped driver source did not build — falling back to hailort-drivers PR #52"
  if [[ -d "${DRIVER_SRC}/.git" ]]; then
    info "reusing ${DRIVER_SRC}"
  else
    git clone https://github.com/hailo-ai/hailort-drivers.git "${DRIVER_SRC}"
  fi

  cd "${DRIVER_SRC}"
  git fetch origin pull/52/head:pr-52 --force
  git checkout pr-52
  cd "${DRIVER_SRC}/linux/pcie"

  make clean >/dev/null 2>&1 || true

  if ! sudo make install_dkms; then
    warn "build failed — retrying with the del_timer_sync rename for kernels >= 6.15"
    grep -rl 'del_timer_sync' . | xargs -r sed -i 's/\bdel_timer_sync\b/timer_delete_sync/g'
    sudo make install_dkms || die "driver build failed even after the timer rename — see the output above, then run rollback-hailort.sh"
  fi

  sudo modprobe -r hailo1x_pci 2>/dev/null || true
  sudo depmod -a
  sudo modprobe -v hailo1x_pci
  cd "${COMPOSE_DIR}"
elif [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] clone hailort-drivers, checkout pr-52, make install_dkms, modprobe hailo1x_pci"
fi

# ---------------------------------------------------------------------------
# 5. Pin
# ---------------------------------------------------------------------------
log "Holding the hailo packages"

run sudo apt-mark hold "${HOLD_PKGS[@]}"
info "held: ${HOLD_PKGS[*]}"
warn "the kernel is NOT held. After any kernel upgrade, rebuild the driver:"
warn "  cd ${DRIVER_SRC}/linux/pcie && sudo make install_dkms && sudo modprobe hailo1x_pci"

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
log "Verifying"

if [[ $DRY_RUN -eq 1 ]]; then
  info "[dry-run] would run: modinfo hailo1x_pci, hailortcli fw-control identify, import hailo_platform"
  exit 0
fi

FAILED=0

modinfo hailo1x_pci 2>/dev/null | grep -E '^(version|filename)' || { warn "modinfo hailo1x_pci found nothing"; FAILED=1; }
hailortcli --version || FAILED=1

# The device node is checked on its own, because "missing" here almost always
# means "needs a reboot" rather than "the upgrade failed" — and a rollback is
# the wrong response to a reboot. Swapping a PCIe driver under a live kernel
# does not re-run the bus probe: the old module was resident throughout, which
# is why /dev/hailo0 kept working right up until it was unloaded.
if ! ls -l /dev/hailo[0-9]* /dev/h1x-[0-9]* 2>/dev/null; then
  echo
  warn "NO /dev/hailo0 — this is expected at this point. REBOOT, then re-check."
  info ""
  info "    sudo reboot"
  info ""
  info "After the reboot:"
  info ""
  info "    ls -l /dev/hailo0 /dev/h1x-0     # the name varies by driver"
  info "    sudo hailortcli fw-control identify"
  info ""
  info "Still missing? Work down this list — dmesg is the one that answers it:"
  info ""
  info "    lspci -nn | grep -i hailo          # is the card on the bus at all"
  info "    lsmod | grep -i hailo              # is a module loaded, and which"
  info "    sudo dmesg | grep -i hailo | tail -30"
  info "    modinfo hailo1x_pci | head -3; uname -r; dkms status"
  info "    ls -l /usr/lib/firmware/hailo/"
  info ""
  info "  'probe ... failed with error -2' or a firmware complaint -> the firmware"
  info "  went missing when the old packages were removed. Reinstall the deb that"
  info "  owns it — NOT the archive's hailofw, which is Hailo-8 firmware:"
  info "      dpkg -L hailort | grep -i firmware"
  info "      sudo dpkg -i ${DEB_DIR}/$(basename "${RUNTIME_DEB}")"
  info ""
  info "  'sysfs: cannot create duplicate filename /class/hailo_chardev' -> a stale"
  info "  legacy hailo_pci module is winning the probe. Delete it and depmod:"
  info "      sudo rm -f /lib/modules/\$(uname -r)/{updates/dkms,extra,kernel/drivers/misc}/hailo_pci.ko*"
  info "      sudo depmod -a && sudo reboot"
  info ""
  info "  module built for a different kernel (dkms status disagrees with uname -r):"
  info "      cd ${DRIVER_SRC}/linux/pcie && sudo make install_dkms"
  info ""
  info "Your photos are not down meanwhile — the base stack needs no accelerator:"
  info "      cd ${COMPOSE_DIR} && docker compose up -d"
  info ""
  warn "Do NOT roll back for this. A missing node after a driver swap is not a"
  warn "failed upgrade, and rolling back re-does all of it in reverse."
  exit 2
fi

sudo hailortcli fw-control identify || { warn "fw-control identify failed"; FAILED=1; }

if /usr/bin/python3 -c "import hailo_platform; print('hailo_platform', hailo_platform.__version__)"; then
  # The check that actually matters for captioning. libhailort can be 5.3.0
  # while the bindings are not, and only this import distinguishes them.
  /usr/bin/python3 -c "from hailo_platform.genai import VLM; print('genai VLM available')" \
    || { warn "hailo_platform.genai missing — captioning will still fail"; FAILED=1; }
else
  warn "python3 cannot import hailo_platform — wrong python build of the bindings?"
  FAILED=1
fi

if [[ $FAILED -ne 0 ]]; then
  die "verification failed. rollback-hailort.sh --backup ${BACKUP_DIR} will put the old packages back."
fi

log "HailoRT ${VERSION} is installed and the device responds"

# ---------------------------------------------------------------------------
# 7. The Docker-specific part people forget
# ---------------------------------------------------------------------------
warn "YOUR .env IS NOW STALE."
info ""
info "The compose overlay mounts libhailort by its exact versioned soname, which"
info "is what keeps the container in lockstep with the driver. That name has just"
info "changed. Left alone, Docker will create a DIRECTORY where the library"
info "should be and the container will fail at import."
info ""
info "  cd ${COMPOSE_DIR}"
info "  # delete the old HAILO_GID / HAILO_PYTHON_PACKAGE / HAILORT_* lines from .env"
info "  ./scripts/hailo-detect.sh --append"
info ""
info "Then re-fetch the models against the new runtime and start up:"
info ""
info "  ./scripts/download-models.sh"
info "  docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d"
info ""
info "Enable qwen2 at /classifier. If it does not come up, read its load_error."
info ""
info "Rollback stays available at ${BACKUP_DIR} for as long as you keep it."
