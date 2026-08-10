#!/usr/bin/env bash
#
# Work out what docker-compose.hailo.yml needs from this host, and print the
# .env lines to paste. Run it ON THE HOST with the accelerator, not in a
# container.
#
#   ./scripts/hailo-detect.sh              # report
#   ./scripts/hailo-detect.sh --append     # report, then append to ./.env
#
# It checks the four things that have to line up, in the order they fail:
#
#   1. the device node exists and is reachable        -> HAILO_GID
#   2. python can import hailo_platform               -> HAILO_PYTHON_PACKAGE
#   3. the library those bindings link against        -> HAILORT_LIB / _SONAME
#   4. the host's CPython minor matches the image's
#
# (4) is the one people miss. The bindings are a compiled extension built for
# one CPython minor version, and this overlay runs them inside the container's
# interpreter. Raspberry Pi OS Trixie and the PhoTog image are both on Python
# 3.13; Bookworm is on 3.11 and will not work this way. See docs/hailo.md.

set -uo pipefail

APPEND=0
[[ "${1:-}" == "--append" ]] && APPEND=1

PY="${PHOTOG_PYTHON:-/usr/bin/python3}"
IMAGE="tehsnappysoftware/photog:${PHOTOG_TAG:-0.1.0}"

ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
bad()  { printf '\033[1;31mfail\033[0m  %s\n' "$*"; FAILED=1; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }

FAILED=0
DEVICE_ARCH_HINT=""
HAILO_GID=""
HAILO_DEVICE=""
HAILO_PYTHON_PACKAGE=""
HAILORT_LIB=""
HAILORT_SONAME=""

# The char device is NOT always /dev/hailo0. Each driver generation names it
# differently, and the container has to bind-mount the one that exists:
#
#   hailo_pci    (HailoRT 4.x, Hailo-8, `hailo-all`)          /dev/hailo0
#   hailo1x_pci  (HailoRT 5.1.1, RPi archive `hailo-h10-all`) /dev/hailo0
#   hailo1x      (HailoRT 5.3.0, Hailo's own debs)            /dev/h1x-0
#
# Confirmed on a Pi 5 + Hailo-10H after a 5.1.1 -> 5.3.0 upgrade: the node moved
# and the old path simply stopped existing, which Docker reports as
# "error gathering device information ... no such file or directory".
# The patterns are expanded at the point of use, inside a nullglob region --
# NOT stored in an array here. Array assignment globs immediately, and with
# nullglob off an unmatched pattern survives as its own literal string, so a box
# with no device would "find" three files named `/dev/hailo[0-9]*`. Quoted
# expansion later does not re-glob, so turning nullglob on afterwards fixes
# nothing. This is documentation; the live copy is in the search below.
DEVICE_GLOBS_DOC='/dev/hailo[0-9]* /dev/h1x-[0-9]* /dev/hailo_chardev[0-9]*'

echo
echo "PhoTog — Hailo host detection"
echo "-----------------------------"

# --- 1. the device ---------------------------------------------------------

shopt -s nullglob
FOUND_DEVICES=(/dev/hailo[0-9]* /dev/h1x-[0-9]* /dev/hailo_chardev[0-9]*)
shopt -u nullglob

if [[ ${#FOUND_DEVICES[@]} -gt 0 ]]; then
  HAILO_DEVICE="${FOUND_DEVICES[0]}"
  ok "device node ${HAILO_DEVICE}"
  [[ ${#FOUND_DEVICES[@]} -gt 1 ]] && warn "more than one node found (${FOUND_DEVICES[*]}); using the first"

  HAILO_GID="$(stat -c '%g' "$HAILO_DEVICE" 2>/dev/null || echo '')"
  gname="$(stat -c '%G' "$HAILO_DEVICE" 2>/dev/null || echo '?')"
  if [[ -n "$HAILO_GID" ]]; then
    ok "owned by group ${gname} (gid ${HAILO_GID})"
  else
    bad "could not stat ${HAILO_DEVICE}"
  fi
else
  bad "no Hailo device node — nothing in a container can create one"
  info "Looked for: ${DEVICE_GLOBS_DOC}"
  info ""
  info "Not installed yet?"
  info "  Hailo-8  / AI HAT+   : sudo apt install hailo-all      && sudo reboot"
  info "  Hailo-10H / AI HAT+ 2: sudo apt install hailo-h10-all  && sudo reboot"
  info ""
  info "Installed but no node — the driver did not bind. In this order:"
  info "  lspci -nn | grep -i hailo        # card on the bus at all"
  info "  lsmod | grep -i hailo            # module loaded"
  info "  dkms status                      # 'installed', not 'added'"
  info "  sudo dmesg | grep -i hailo       # names the node it created, if any"
  info ""
  info "'added' rather than 'installed' means the DKMS build never ran:"
  info "  sudo dkms build -m <module> -v <version> && sudo dkms install -m <module> -v <version>"
  info "  sudo depmod -a && sudo modprobe -v <module>"
fi

if command -v hailortcli >/dev/null 2>&1; then
  ver="$(hailortcli --version 2>/dev/null | head -1)"
  ok "hailortcli: ${ver}"
  ident="$(hailortcli fw-control identify 2>&1 | grep -iE 'Device Architecture|Board Name' | head -2)"
  # Which chip, for the captioning advice at the end: qwen2 needs a Hailo-10H,
  # so a Hailo-8 owner has to be told about the CPU path or they get nothing.
  case "$ident" in
    *HAILO10H*|*HAILO15H*) DEVICE_ARCH_HINT="hailo10" ;;
    *HAILO8*)              DEVICE_ARCH_HINT="hailo8" ;;
  esac
  if [[ -n "$ident" ]]; then
    while IFS= read -r l; do ok "${l#"${l%%[![:space:]]*}"}"; done <<< "$ident"
  else
    warn "hailortcli fw-control identify returned nothing — driver or firmware trouble"
    info "check: dmesg | grep -i hailo   and   sudo apt install --reinstall hailofw"
  fi
else
  warn "hailortcli not on PATH — cannot confirm the runtime version"
fi

for mod in hailo_pci hailo1x_pci hailo1x; do
  if modinfo "$mod" >/dev/null 2>&1; then
    mver="$(modinfo "$mod" 2>/dev/null | awk '/^version:/{print $2; exit}')"
    ok "kernel module ${mod} version ${mver:-unknown}"
  fi
done

# 'added' means the source is registered but was never built or installed —
# no .ko on disk, modinfo finds nothing, dmesg stays silent. It looks exactly
# like broken hardware and is one command from fixed.
if command -v dkms >/dev/null 2>&1; then
  while read -r line; do
    case "$line" in
      *installed*) ok "dkms: ${line}" ;;
      *)           bad "dkms: ${line}"
                   info "not 'installed' — the module was never built. See above." ;;
    esac
  done < <(dkms status 2>/dev/null | grep -i hailo)
fi

# --- 2. the python bindings ------------------------------------------------

echo
if [[ ! -x "$PY" ]]; then
  bad "${PY} is not executable — set PHOTOG_PYTHON to your system interpreter"
else
  pyver="$("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
  ok "host interpreter ${PY} is Python ${pyver:-?}"
  # Deliberately not bare `python3`: an asdf or pyenv shim wins PATH on plenty
  # of Pis and has neither hailo_platform nor cv2. That cost an evening once.
  if [[ "$(command -v python3 2>/dev/null)" != "$PY" ]]; then
    warn "bare 'python3' resolves to $(command -v python3 2>/dev/null || echo none), not ${PY}"
  fi

  pkg="$("$PY" - <<'PYEOF' 2>/dev/null
import os
try:
    import hailo_platform
except Exception as e:
    raise SystemExit(f"IMPORTERROR {e}")
print(os.path.dirname(os.path.abspath(hailo_platform.__file__)))
PYEOF
)"
  if [[ -n "$pkg" && "$pkg" != IMPORTERROR* && -d "$pkg" ]]; then
    HAILO_PYTHON_PACKAGE="$pkg"
    ok "hailo_platform at ${pkg}"
  else
    bad "${PY} cannot import hailo_platform"
    [[ -n "$pkg" ]] && info "${pkg#IMPORTERROR }"
    info "Hailo-8:   sudo apt install python3-hailort"
    info "Hailo-10H: sudo apt install python3-h10-hailort   (or Hailo's own wheel for 5.3.0+)"
    info "Do not pip-install numpy alongside it — hailo_platform is compiled"
    info "against the system numpy and a shadowing copy is an ABI mismatch."
  fi
fi

# --- 3. libhailort ---------------------------------------------------------

echo
soname=""
if [[ -n "$HAILO_PYTHON_PACKAGE" ]]; then
  ext="$(find "$HAILO_PYTHON_PACKAGE" -name '_pyhailort*.so' -print -quit 2>/dev/null)"
  if [[ -n "$ext" ]] && command -v readelf >/dev/null 2>&1; then
    soname="$(readelf -d "$ext" 2>/dev/null | awk -F'[][]' '/NEEDED.*libhailort/{print $2; exit}')"
    [[ -n "$soname" ]] && ok "bindings link against ${soname}"
  fi
fi

if [[ -z "$soname" ]]; then
  # Fall back to whatever ldconfig knows about, preferring a versioned soname
  # over the bare development symlink.
  soname="$(ldconfig -p 2>/dev/null | awk '{print $1}' | grep -E '^libhailort\.so\.[0-9]' | head -1)"
  [[ -n "$soname" ]] && warn "guessed soname ${soname} from ldconfig (readelf unavailable)"
fi

if [[ -n "$soname" ]]; then
  HAILORT_SONAME="$soname"
  lib="$(ldconfig -p 2>/dev/null | awk -v s="$soname" '$1 == s {print $NF; exit}')"
  if [[ -z "$lib" ]]; then
    lib="$(find /usr/lib /lib -maxdepth 3 -name "$soname" -print -quit 2>/dev/null)"
  fi
  if [[ -n "$lib" && -e "$lib" ]]; then
    # Resolve symlinks: a bind mount of a dangling link inside the container is
    # a file that exists and cannot be opened.
    HAILORT_LIB="$(readlink -f "$lib")"
    ok "libhailort at ${HAILORT_LIB}"
  else
    bad "cannot find ${soname} on this host"
  fi
else
  bad "no libhailort found — is the hailort package installed?"
fi

# --- 4. the python ABI match ----------------------------------------------

echo
cpyver=""
if docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null 2>&1; then
  cpyver="$(docker run --rm --entrypoint /usr/bin/python3 "$IMAGE" \
              -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
fi

if [[ -z "$cpyver" ]]; then
  warn "could not ask ${IMAGE} for its Python version (image not pulled?)"
  info "check by hand: docker run --rm --entrypoint /usr/bin/python3 ${IMAGE} -V"
elif [[ -n "${pyver:-}" && "$cpyver" == "$pyver" ]]; then
  ok "host Python ${pyver} matches the image's ${cpyver}"
else
  bad "host Python ${pyver:-?} does NOT match the image's ${cpyver}"
  info "The bindings are a compiled extension for one CPython minor version."
  info "Mounting 3.11 bindings into a 3.13 interpreter fails at import."
  info "Raspberry Pi OS Trixie is on 3.13; Bookworm is on 3.11."
  info "See docs/hailo.md for what to do instead."
fi

# --- output ----------------------------------------------------------------

echo
if [[ -z "$HAILO_GID$HAILO_PYTHON_PACKAGE$HAILORT_LIB" ]]; then
  echo "Nothing usable found. Fix the failures above and run this again."
  exit 1
fi

block="$(cat <<ENVEOF
# --- Hailo, detected by scripts/hailo-detect.sh on $(date -u '+%Y-%m-%d %H:%M UTC') ---
HAILO_DEVICE=${HAILO_DEVICE}
HAILO_GID=${HAILO_GID}
HAILO_PYTHON_PACKAGE=${HAILO_PYTHON_PACKAGE}
HAILORT_LIB=${HAILORT_LIB}
HAILORT_SONAME=${HAILORT_SONAME}
# Set this to a directory on this host holding your .hef files:
#PHOTOG_MODELS_PATH=${HOME}/photog/models
ENVEOF
)"

echo "Add to .env:"
echo
echo "$block" | sed 's/^/    /'
echo

# COMPOSE_FILE is deliberately NOT part of the appended block: it is one line
# that must not appear twice, and only the operator knows whether captioning is
# wanted. Advice, not automation.
if [[ -f .env ]] && grep -qE '^COMPOSE_FILE=.*docker-compose\.hailo\.yml' .env; then
  ok "COMPOSE_FILE in .env already includes the hailo overlay"
else
  echo "Also set COMPOSE_FILE in .env, so no -f flags are needed:"
  echo
  echo "    COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml"
  echo
  if [[ "$DEVICE_ARCH_HINT" == "hailo8" ]]; then
    echo "  This looks like a Hailo-8. qwen2 captioning needs a Hailo-10H, so for"
    echo "  captions add the CPU path and set PHOTOG_PYTHON_TAG:"
    echo
    echo "    COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml:docker-compose.moondream.yml"
    echo
  fi
fi

if [[ "$APPEND" == "1" ]]; then
  if [[ ! -f .env ]]; then
    echo "no .env in $(pwd) — run this from your PhoTog directory" >&2
    exit 1
  fi
  if grep -qE '^(HAILO_GID|HAILO_DEVICE)=' .env; then
    echo "'.env' already has HAILO_GID — not appending. Edit it by hand." >&2
    exit 1
  fi
  printf '\n%s\n' "$block" >> .env
  echo "appended to $(pwd)/.env"
fi

[[ "$FAILED" == "1" ]] && exit 1
exit 0
