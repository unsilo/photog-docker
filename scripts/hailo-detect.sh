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
# interpreter. Raspberry Pi OS Trixie and the Photog image are both on Python
# 3.13; Bookworm is on 3.11 and will not work this way. See docs/hailo.md.

set -uo pipefail

APPEND=0
[[ "${1:-}" == "--append" ]] && APPEND=1

PY="${PHOTOG_PYTHON:-/usr/bin/python3}"
IMAGE="tehsnappysoftware/photog:${PHOTOG_TAG:-0.1.4}"

ok()   { printf '\033[1;32m  ok\033[0m  %s\n' "$*"; }
bad()  { printf '\033[1;31mfail\033[0m  %s\n' "$*"; FAILED=1; }
warn() { printf '\033[1;33mwarn\033[0m  %s\n' "$*"; }
info() { printf '      %s\n' "$*"; }

# sort -V puts the lower version first; if $1 sorts first and differs, $1 < $2.
version_lt() {
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

# The floor for qwen2 captioning. Not a preference — Hailo publishes no VLM HEF
# below this, so there is nothing to load on an older runtime. Same constant as
# download-models.sh enforces.
CAPTION_MIN_VERSION="5.3.0"

FAILED=0
HAILORT_VERSION=""
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
echo "Photog — Hailo host detection"
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
  # Kept as a bare x.y.z for the captioning check at the end. The banner text
  # around it has changed between releases; the number has not.
  HAILORT_VERSION="$(printf '%s' "$ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
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
    info "check: sudo dmesg | grep -i hailo"
    info ""
    info "A firmware complaint or 'probe ... failed with error -2' means the"
    info "firmware is missing. Reinstall the package that OWNS it, which differs"
    info "by card — 'dpkg -L <pkg> | grep -i firmware' tells you which:"
    info "  Hailo-8   : sudo apt install --reinstall hailofw"
    info "  Hailo-10H : sudo apt install --reinstall hailo-h10-all"
    info ""
    info "hailofw is HAILO-8 firmware. On a Hailo-10H box it is not merely wrong,"
    info "the package does not exist — 'Unable to locate package hailofw' there"
    info "means you are on the 5.x stack, not that your install is broken."
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

# --- what COMPOSE_FILE should be -------------------------------------------
#
# Derived, not asked. The rules are the README's hardware table, and there is
# exactly one right answer per machine:
#
#   Hailo-10H   hailo overlay           the card captions; nothing else needed
#   Hailo-8     hailo + python overlay  the card cannot caption, moondream can
#   no card     base only               everything works, the AI is just slow
#
# The Hailo-8 default assumes descriptions are wanted, because the alternative
# is a machine that silently cannot produce any and an operator with no reason
# to suspect a compose overlay. Dropping the overlay is one edit and is printed
# below; discovering you needed it is not.
HAILO_USABLE=0
[[ -n "$HAILO_GID$HAILO_PYTHON_PACKAGE$HAILORT_LIB" ]] && HAILO_USABLE=1

if [[ $HAILO_USABLE -eq 1 && "$DEVICE_ARCH_HINT" == "hailo8" ]]; then
  COMPOSE_TARGET="docker-compose.yml:docker-compose.hailo.yml:docker-compose.python.yml"
elif [[ $HAILO_USABLE -eq 1 ]]; then
  COMPOSE_TARGET="docker-compose.yml:docker-compose.hailo.yml"
else
  COMPOSE_TARGET="docker-compose.yml"
fi

# Replace in place rather than append. COMPOSE_FILE is a scalar — a second line
# does not merge with the first, it silently wins — and install.sh always wrote
# one, so appending would leave every .env with two. ENVIRON carries the value
# into awk so nothing in it needs escaping.
set_env_var() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)" || return 1
  if grep -qE "^${key}=" .env 2>/dev/null; then
    KEY="$key" VALUE="$value" awk '
      $0 ~ "^" ENVIRON["KEY"] "=" {
        if (!seen) { print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; seen = 1 }
        next
      }
      { print }
    ' .env > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    cat .env > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  # Truncate-and-write rather than mv, so .env keeps its mode 600 and owner.
  cat "$tmp" > .env || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

# --- output ----------------------------------------------------------------

echo
if [[ $HAILO_USABLE -eq 0 ]]; then
  echo "No usable Hailo accelerator found."
  echo
  echo "That is not necessarily wrong — everything in Photog works without one."
  echo "Classification runs in software, and it is slow but correct."
  if [[ "$APPEND" == "1" ]] && [[ -f .env ]]; then
    if set_env_var COMPOSE_FILE "$COMPOSE_TARGET"; then
      echo
      ok "set COMPOSE_FILE=${COMPOSE_TARGET} in .env"
    fi
  else
    echo
    echo "The matching .env line, which is also the installer's default:"
    echo
    echo "    COMPOSE_FILE=${COMPOSE_TARGET}"
  fi
  echo
  echo "  ---------------------------------------------------------------"
  echo "  WANT IMAGE DESCRIPTIONS? One more line and no hardware."
  echo
  echo "  Moondream is a 0.5B model that runs on the CPU. On a Pi it takes"
  echo "  the better part of a minute per photo, which is fine for a library"
  echo "  chewed through overnight and painful if you are watching it:"
  echo
  echo "    COMPOSE_FILE=docker-compose.yml:docker-compose.python.yml"
  echo
  echo "  That one line is all it takes: the overlay selects the -python image,"
  echo "  which is the only one carrying Moondream's Python environment. Then"
  echo "  enable 'moondream' at /classifier."
  echo "  ---------------------------------------------------------------"
  echo
  echo "If you DO have a card, fix the failures above and run this again."
  exit 1
fi

# install.sh writes PHOTOG_MODELS_PATH, so mentioning it again is noise in the
# common case — and a second commented copy in .env is worse than noise, since
# whoever uncomments the wrong one gets a models directory that is not the one
# the installer created. Only offer it when it is genuinely absent.
models_hint=""
if [[ ! -f .env ]] || ! grep -qE '^PHOTOG_MODELS_PATH=' .env; then
  models_hint="
# Not set anywhere yet, and the hailo overlay requires it. A host directory to
# hold your .hef files — scripts/download-models.sh fills it:
#PHOTOG_MODELS_PATH=${HOME}/photog-data/models"
fi

block="$(cat <<ENVEOF
# --- Hailo, detected by scripts/hailo-detect.sh on $(date -u '+%Y-%m-%d %H:%M UTC') ---
HAILO_DEVICE=${HAILO_DEVICE}
HAILO_GID=${HAILO_GID}
HAILO_PYTHON_PACKAGE=${HAILO_PYTHON_PACKAGE}
HAILORT_LIB=${HAILORT_LIB}
HAILORT_SONAME=${HAILORT_SONAME}${models_hint}
ENVEOF
)"

# --- write, then describe what was written ---------------------------------
#
# The write happens first so the heading can be true. Printing "Add to .env"
# and then appending underneath it left the reader with an instruction that had
# already been carried out.
WROTE_BLOCK=0
WROTE_COMPOSE=0
BLOCK_SKIPPED=""

if [[ "$APPEND" == "1" ]]; then
  if [[ ! -f .env ]]; then
    echo "no .env in $(pwd) — run this from your Photog directory" >&2
    exit 1
  fi

  if grep -qE '^(HAILO_GID|HAILO_DEVICE)=' .env; then
    BLOCK_SKIPPED="yes"
  else
    printf '\n%s\n' "$block" >> .env
    WROTE_BLOCK=1
  fi

  # Set regardless of whether the Hailo block was skipped: it is derived from
  # the hardware, it is idempotent, and a stale COMPOSE_FILE is the single most
  # common reason a correctly-detected card goes unused.
  if set_env_var COMPOSE_FILE "$COMPOSE_TARGET"; then
    WROTE_COMPOSE=1
  else
    warn "could not update COMPOSE_FILE in .env — set it by hand:"
    warn "  COMPOSE_FILE=${COMPOSE_TARGET}"
  fi
fi

if [[ $WROTE_BLOCK -eq 1 ]]; then
  echo "Added to $(pwd)/.env:"
else
  echo "Add to .env:"
fi
echo
echo "$block" | sed 's/^/    /'
echo "    COMPOSE_FILE=${COMPOSE_TARGET}"
echo

if [[ -n "$BLOCK_SKIPPED" ]]; then
  warn ".env already has HAILO_ lines — those were left alone, not overwritten."
  info "COMPOSE_FILE was still set, because it follows from the hardware."
  info ""
  info "If you just changed HailoRT, the old values are now WRONG — the library"
  info "is mounted by its exact versioned soname and that name has moved. Delete"
  info "the HAILO_DEVICE / HAILO_GID / HAILO_PYTHON_PACKAGE / HAILORT_* lines"
  info "from .env and run this again."
  echo
fi

if [[ $WROTE_COMPOSE -eq 1 ]]; then
  ok "COMPOSE_FILE=${COMPOSE_TARGET}"
else
  info "COMPOSE_FILE above is what this machine should run — no -f flags needed."
fi

if [[ "$DEVICE_ARCH_HINT" == "hailo8" ]]; then
  echo
  echo "  ---------------------------------------------------------------"
  echo "  This is a HAILO-8: it accelerates classification but CANNOT write"
  echo "  descriptions. qwen2 needs a Hailo-10H and HailoRT ${CAPTION_MIN_VERSION}, and there"
  echo "  is no HEF, runtime version or setting that changes that."
  echo
  echo "  So COMPOSE_FILE above includes docker-compose.python.yml, which adds"
  echo "  Moondream — a 0.5B model running on the CPU, independent of the card,"
  echo "  which keeps doing detection and classification at full speed. Enable"
  echo "  'moondream' at /classifier, not qwen2."
  echo
  echo "  Descriptions are slow that way: the better part of a minute per photo"
  echo "  on a Pi. If you do not want them, drop the last overlay and use the"
  echo "  smaller image — about 95 MB less to pull:"
  echo
  echo "    COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml"
  echo "  ---------------------------------------------------------------"
fi

# The Hailo-10H trap, checked here because this is the first script that has
# both facts at once: which chip, and which runtime.
#
# `apt install hailo-h10-all` gives you 5.1.1 — the Raspberry Pi archive caps
# every h10- package there — and Hailo publishes no VLM HEF below 5.3.0. That
# combination is silent: detection and classification work perfectly, so the
# box looks healthy right up until someone enables qwen2 months later and gets
# HAILO_INVALID_OPERATION(6), which names neither the version nor the file.
# Saying it now, unprompted, is worth more than any error message later.
if [[ "$DEVICE_ARCH_HINT" == "hailo10" && -n "${HAILORT_VERSION:-}" ]] \
   && version_lt "$HAILORT_VERSION" "$CAPTION_MIN_VERSION"; then
  echo "  ---------------------------------------------------------------"
  echo "  HAILO-10H ON HAILORT ${HAILORT_VERSION} — CAPTIONING WILL NOT WORK YET."
  echo
  echo "  Your card can do image descriptions. This runtime cannot: no VLM"
  echo "  model is published below ${CAPTION_MIN_VERSION}, so there is nothing for qwen2"
  echo "  to load. It fails with HAILO_INVALID_OPERATION(6) and says no more"
  echo "  than that."
  echo
  echo "  'apt install hailo-h10-all' always lands here — the Raspberry Pi"
  echo "  archive caps every h10- package at 5.1.1. This is not a mistake you"
  echo "  made."
  echo
  echo "  Everything else works right now. Detection and classification are"
  echo "  fully accelerated on ${HAILORT_VERSION} and gain nothing from upgrading."
  echo "  Carry on and come back to this when you want descriptions."
  echo
  echo "  When you do: HailoRT ${CAPTION_MIN_VERSION} comes from Hailo's own debs, which"
  echo "  REPLACE the archive's packages rather than upgrading them, and apt"
  echo "  stops managing the result. Read what you give up first:"
  echo
  echo "    ./scripts/upgrade-hailort.sh --dry-run"
  echo "    docs/hailo.md, 'Upgrading to HailoRT ${CAPTION_MIN_VERSION}'"
  echo
  echo "  Until then, skip qwen2 in download-models.sh — it skips it for you —"
  echo "  and leave that classifier disabled."
  echo "  ---------------------------------------------------------------"
  echo
elif [[ "$DEVICE_ARCH_HINT" == "hailo10" && -n "${HAILORT_VERSION:-}" ]]; then
  ok "HailoRT ${HAILORT_VERSION} — new enough for qwen2 captioning (needs ${CAPTION_MIN_VERSION}+)"
fi

if [[ "$APPEND" != "1" ]]; then
  echo
  info "Nothing was written. Re-run with --append to have this done for you."
fi

[[ "$FAILED" == "1" ]] && exit 1
exit 0
