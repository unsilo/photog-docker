#!/usr/bin/env bash
#
# Fetch the HEF model files Photog's classifiers need, verify them, and put them
# where the container looks.
#
#   ./scripts/download-models.sh                    # auto-detect, all models
#   ./scripts/download-models.sh --vision-only      # skip the 3 GB captioner
#   ./scripts/download-models.sh --skip qwen2-vl    # same thing, by name
#   ./scripts/download-models.sh --only qwen2-vl    # just that one
#   ./scripts/download-models.sh --arch hailo8 --version 5.1.0
#   ./scripts/download-models.sh --dry-run
#   ./scripts/download-models.sh --list             # names, sizes, nothing else
#
# HEFs are not in the image: they are large, and Hailo's Dataflow Compiler and
# model-zoo terms are a licensing question of their own. They are also not
# interchangeable — a build is compiled for one architecture AND one SDK
# version, and getting either wrong produces a failure that names neither.
#
# Two things this does that a plain curl does not:
#
#   1. Verifies the SDK version recorded in the downloaded bytes before
#      installing the file, and refuses a mismatch. A HEF built for a newer
#      HailoRT than you run loads fine on the vision path and is rejected by the
#      GenAI path — so "it downloaded" is not "it will work".
#
#   2. Normalises the filename. Upstream publishes the VLM as
#      Qwen2-VL-2B-Instruct.hef; the classifier row asks for
#      qwen2-vl-2b-instruct.hef. Linux is case-sensitive, and a case-only
#      mismatch resolves silently to a file that is not there.
#
# The VLM is ~3 GB. The vision models are tens of MB.

set -euo pipefail

DEFAULT_VERSION="5.3.0"
VISION_BASE="https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled"
GENAI_BASE="https://dev-public.hailo.ai"

# HailoRT writes `sdk-version: X.Y.Z` into the HEF header. 200KB is well past it
# on every file seen so far.
HEADER_BYTES=200000

VERSION=""
ARCH=""
DEST=""
ONLY=""
SKIP_LIST=""
VISION_ONLY=0
LIST_ONLY=0
FORCE=0
DRY_RUN=0

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m    WARNING: %s\033[0m\n' "$*"; }
die()  { printf '\033[31m\nERROR: %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --arch)    ARCH="$2"; shift 2 ;;
    --dest)    DEST="$2"; shift 2 ;;
    --only)    ONLY="$2"; shift 2 ;;
    # Repeatable and comma-separated both work, because both get typed.
    --skip)    SKIP_LIST="${SKIP_LIST},$(printf '%s' "$2" | tr -d '[:space:]')"; shift 2 ;;
    --vision-only|--no-vlm) VISION_ONLY=1; shift ;;
    --list)    LIST_ONLY=1; shift ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown option: $1" ;;
  esac
done

command -v curl >/dev/null || die "curl is required"

# --- the catalogue ---------------------------------------------------------
#
# local names MUST match the model_repo column of the classifier rows. That is
# what the app looks for; the file's upstream name is irrelevant to it.
#
#   name|source|remote filename|local filename|minimum SDK|size|what it does
MODELS=(
  "resnet_v1_50|vision|resnet_v1_50.hef|resnet_v1_50.hef||~25 MB|scene and subject tags"
  "yolov11m|vision|yolov11m.hef|yolov11m.hef||~40 MB|object detection"
  "qwen2-vl|genai|Qwen2-VL-2B-Instruct.hef|qwen2-vl-2b-instruct.hef|5.3.0|~3 GB|image descriptions (Hailo-10H only)"
)

model_names() {
  local e n
  for e in "${MODELS[@]}"; do n="${e%%|*}"; printf '%s\n' "$n"; done
}

# A name that matches nothing is worse than an error: --skip qwen2 (the real
# name is qwen2-vl) would silently download the 3 GB file the flag was typed to
# avoid. Validate before doing any work.
validate_name() {
  local given="$1" flag="$2"
  model_names | grep -qxF "$given" && return 0
  die "unknown model '${given}' for ${flag}.

  Known models: $(model_names | tr '\n' ' ')

  Nothing has been downloaded."
}

[[ -n "$ONLY" ]] && validate_name "$ONLY" "--only"
if [[ -n "$SKIP_LIST" ]]; then
  IFS=',' read -r -a _skips <<< "${SKIP_LIST#,}"
  for s in "${_skips[@]}"; do [[ -n "$s" ]] && validate_name "$s" "--skip"; done
fi

is_skipped() { [[ ",${SKIP_LIST#,}," == *",$1,"* ]]; }

if [[ $LIST_ONLY -eq 1 ]]; then
  log "Models this script knows about"
  for entry in "${MODELS[@]}"; do
    IFS='|' read -r name _source _remote _local min_ver size note <<< "$entry"
    printf '    %-14s %-8s %s%s\n' "$name" "$size" "$note" \
      "${min_ver:+  [needs SDK ${min_ver}+]}"
  done
  echo
  info "Skip one with --skip <name>, or all captioning with --vision-only."
  exit 0
fi


# --- where the files go ----------------------------------------------------
#
# The compose overlay mounts PHOTOG_MODELS_PATH at /app_cache/models, which is
# where the app looks. Reading it out of .env means this script and the stack
# cannot disagree about the location.

if [[ -z "$DEST" ]]; then
  if [[ -f .env ]] && grep -qE '^PHOTOG_MODELS_PATH=' .env; then
    DEST="$(grep -E '^PHOTOG_MODELS_PATH=' .env | head -1 | cut -d= -f2-)"
    info "destination from .env: ${DEST}"
  else
    DEST="./models"
    warn "PHOTOG_MODELS_PATH is not set in .env; using ${DEST}"
    warn "Set it before starting the stack, or the container will not see these."
  fi
fi

# --- which chip ------------------------------------------------------------
#
# Asking the device beats asking the user. hailo8/ and hailo10h/ are different
# compilations of the same network and a wrong one fails at load with an error
# that does not mention architecture.

if [[ -z "$ARCH" ]]; then
  if command -v hailortcli >/dev/null 2>&1; then
    ident="$(sudo hailortcli fw-control identify 2>/dev/null || hailortcli fw-control identify 2>/dev/null || true)"
    case "$ident" in
      *HAILO10H*) ARCH="hailo10h" ;;
      *HAILO15H*) ARCH="hailo15h" ;;
      *HAILO8L*)  ARCH="hailo8l"  ;;
      *HAILO8*)   ARCH="hailo8"   ;;
    esac
  fi
  if [[ -n "$ARCH" ]]; then
    info "detected architecture: ${ARCH}"
  else
    die "could not detect the accelerator. Pass --arch hailo10h (AI HAT+ 2),
  hailo8 or hailo8l (AI HAT+). If 'hailortcli fw-control identify' does not
  answer, fix that first — see docs/hailo.md."
  fi
fi

# --- which SDK version -----------------------------------------------------
#
# Default to the installed runtime rather than to the newest release. A HEF
# newer than your HailoRT is the failure this whole script exists to prevent.

if [[ -z "$VERSION" ]]; then
  if command -v hailortcli >/dev/null 2>&1; then
    VERSION="$(hailortcli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  fi
  VERSION="${VERSION:-$DEFAULT_VERSION}"
  info "targeting SDK ${VERSION} (from the installed runtime)"
fi

version_lt() {
  # sort -V puts the lower version first; if $1 sorts first and differs, $1 < $2
  [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

hef_sdk_version() {
  head -c "$HEADER_BYTES" "$1" 2>/dev/null \
    | grep -aoE 'sdk-version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' \
    | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
}

[[ $DRY_RUN -eq 0 ]] && mkdir -p "$DEST"

log "Downloading to ${DEST}"
FAILED=0
SKIPPED=0
OMITTED=0

for entry in "${MODELS[@]}"; do
  IFS='|' read -r name source remote local_name min_ver size note <<< "$entry"

  if [[ -n "$ONLY" && "$ONLY" != "$name" ]]; then
    continue
  fi

  if is_skipped "$name"; then
    info "${name}: skipped (--skip ${name})"
    OMITTED=$((OMITTED + 1))
    continue
  fi

  # Keyed on the source column rather than on the model's name, so a second VLM
  # added to the catalogue later is covered by --vision-only without anyone
  # remembering to update this.
  if [[ $VISION_ONLY -eq 1 && "$source" == "genai" ]]; then
    info "${name}: skipped (--vision-only) — ${size}, ${note}"
    OMITTED=$((OMITTED + 1))
    continue
  fi

  # The GenAI floor is not advisory. Hailo publishes no VLM below 5.3.0, so a
  # request under it is unsatisfiable rather than merely likely to fail.
  if [[ -n "$min_ver" ]] && version_lt "$VERSION" "$min_ver"; then
    warn "${name}: needs SDK ${min_ver}+, you are targeting ${VERSION} — skipping"
    warn "  No VLM HEF is published below ${min_ver}. Captioning needs a runtime"
    warn "  upgrade, not a different model: scripts/upgrade-hailort.sh"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  target="${DEST}/${local_name}"

  if [[ -f "$target" && $FORCE -eq 0 ]]; then
    have="$(hef_sdk_version "$target")"
    if [[ "$have" == "$VERSION" ]]; then
      info "${name}: already present, sdk-version ${have} — skipping"
      continue
    fi
    warn "${name}: present but sdk-version is '${have:-unreadable}', wanted ${VERSION}"
    warn "  re-run with --force to replace it"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ "$source" == "vision" ]]; then
    url="${VISION_BASE}/v${VERSION}/${ARCH}/${remote}"
  else
    url="${GENAI_BASE}/v${VERSION}/blob/${remote}"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] ${url}"
    info "[dry-run]   -> ${target}"
    continue
  fi

  log "${name}"
  info "$url"

  # Download to .part and only move it into place once the version checks out.
  # A half-downloaded or wrong-version file sitting under the real name is
  # indistinguishable from a correct one at a glance, and the app will load it.
  tmp="${target}.part"
  rm -f "$tmp"
  if ! curl -fL --progress-bar -o "$tmp" "$url"; then
    warn "${name}: download failed"
    warn "  Check that v${VERSION}/${ARCH} exists upstream — not every model is"
    warn "  compiled for every architecture and version combination."
    rm -f "$tmp"
    FAILED=$((FAILED + 1))
    continue
  fi

  got="$(hef_sdk_version "$tmp")"
  if [[ -z "$got" ]]; then
    warn "${name}: no sdk-version in the header — a pre-5.x build, most likely"
    warn "  Keeping it, but it may not match your runtime."
  elif [[ "$got" != "$VERSION" ]]; then
    warn "${name}: downloaded file reports sdk-version ${got}, expected ${VERSION}"
    warn "  Refusing to install it. Upstream may have republished under this path."
    rm -f "$tmp"
    FAILED=$((FAILED + 1))
    continue
  fi

  mv "$tmp" "$target"
  size="$(du -h "$target" | cut -f1)"
  info "installed ${local_name} (${size}, sdk-version ${got:-unknown})"
  [[ "$remote" != "$local_name" ]] && info "renamed from ${remote} — the classifier row uses the lower-case name"
done

echo
if [[ $DRY_RUN -eq 1 ]]; then
  exit 0
fi

log "Done"
found=0
while IFS= read -r -d '' f; do
  info "$(du -h "$f" | cut -f1)  $(basename "$f")  sdk-version $(hef_sdk_version "$f")"
  found=1
done < <(find "$DEST" -maxdepth 1 -name '*.hef' -print0 2>/dev/null)
[[ $found -eq 0 ]] && warn "no .hef files in ${DEST}"

echo
info "Next:"
info "  docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d"
info "  then enable the classifier at /classifier"
info ""
info "If a classifier does not come up, read its load_error column — nothing"
info "crashes, so silence is not success."

[[ $SKIPPED -gt 0 ]] && warn "${SKIPPED} model(s) skipped as unsatisfiable at SDK ${VERSION}"

# Said plainly, because "the captioner does not work" three weeks from now is
# otherwise indistinguishable from a broken install — and the fix is one
# command, not an investigation.
if [[ $OMITTED -gt 0 ]]; then
  echo
  warn "${OMITTED} model(s) omitted at your request — those classifiers will not"
  warn "  start, and their load_error will say the HEF is missing. That is this"
  warn "  flag, not a fault. Fetch them later with:"
  warn "      ./scripts/download-models.sh"
fi

[[ $FAILED -gt 0 ]] && exit 1
exit 0
