#!/usr/bin/env bash
#
# Photog installer. Fetches the compose files, generates the secrets, writes a
# .env, and starts the stack.
#
#   curl -fsSL https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh | bash
#
# or, if you would rather read it first (you should):
#
#   curl -fsSLO https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh
#   less install.sh && bash install.sh
#
# It is safe to re-run: an existing .env is never overwritten, and the compose
# files are refreshed in place.
#
# Environment overrides:
#   PHOTOG_DIR   install directory        (default ~/photog)
#   PHOTOG_REF   git ref to fetch from    (default main)
#   PHOTOG_TAG   image tag to run         (default 0.1.4)
#   PHX_HOST     hostname to serve at     (default <hostname>.local, or localhost)
#
# It configures and then stops. It does not start the stack: on a machine with
# an accelerator, starting before scripts/env-detect.sh has run produces a
# container with no device and an empty models directory, which looks like a
# working install that cannot classify anything. The last thing it prints is
# the exact command to run next.

set -euo pipefail

PHOTOG_DIR="${PHOTOG_DIR:-$HOME/photog}"
PHOTOG_REF="${PHOTOG_REF:-main}"
PHOTOG_TAG="${PHOTOG_TAG:-0.1.4}"
RAW="https://raw.githubusercontent.com/unsilo/photog-docker/${PHOTOG_REF}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

# The container runs as uid 1000 and cannot write a directory it does not own.
# Getting this wrong does not fail at startup — it surfaces later as thumbnails
# that never appear, or an import screen that shows an empty folder, which is
# why the installer does it rather than leaving it in the docs.
CONTAINER_UID=1000

owner_of() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null || echo ""
}

free_on() {
  df -h "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

# Postgres needs real POSIX ownership and honest fsync. A named volume always
# has both; an arbitrary directory might not. These are the filesystems where a
# bind-mounted database ranges from "quietly broken" to "corrupts on power
# loss", so the installer declines to use one rather than letting someone find
# out during a restore.
db_fs_unsuitable() {
  local fs
  fs="$(stat -f -c '%T' "$1" 2>/dev/null || echo unknown)"
  case "$fs" in
    ext2/ext3|ext4|xfs|btrfs|zfs|overlayfs|tmpfs) return 1 ;;
    unknown)                                      return 1 ;;  # BSD/macOS stat; let it pass
    *)                                            printf '%s' "$fs"; return 0 ;;
  esac
}

# The database directory, which is NOT chowned to uid 1000 — the postgres image
# starts as root and chowns PGDATA to its own uid itself.
ensure_db_dir() {
  local path="$1"
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" 2>/dev/null || sudo mkdir -p "$path" || die "could not create ${path}"
  fi
  printf '    %-10s %s  (%s free)\n' "database" "$path" "$(free_on "$path")"
}

ensure_dir() {
  local path="$1" label="$2"

  if [[ ! -d "$path" ]]; then
    if ! mkdir -p "$path" 2>/dev/null; then
      say "creating ${path} needs sudo"
      sudo mkdir -p "$path" || die "could not create ${path}"
    fi
  fi

  if [[ "$(owner_of "$path")" != "$CONTAINER_UID" ]]; then
    if [[ "$(id -u)" == "$CONTAINER_UID" ]]; then
      chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$path" 2>/dev/null || true
    else
      say "giving uid ${CONTAINER_UID} ownership of ${path}"
      sudo chown -R "${CONTAINER_UID}:${CONTAINER_UID}" "$path" \
        || warn "could not chown ${path}; the container may not be able to write there"
    fi
  fi

  printf '    %-10s %s  (%s free)\n' "${label}" "$path" "$(free_on "$path")"
}

# --- checks ----------------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker is not installed.
  On Raspberry Pi OS or Debian/Ubuntu:
      curl -fsSL https://get.docker.com | sudo sh
      sudo usermod -aG docker \$USER && newgrp docker"

docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing.
  A 'docker-compose' v1 binary will not do — this stack uses compose v2 syntax."

docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon.
  Either it is not running, or your user is not in the 'docker' group:
      sudo usermod -aG docker \$USER && newgrp docker"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required (apt install openssl)"

case "$(uname -m)" in
  aarch64|arm64) ;;
  armv7l|armv6l) die "32-bit ARM is not supported. Photog needs a 64-bit OS —
  on a Raspberry Pi that means the 64-bit build of Raspberry Pi OS." ;;
  x86_64|amd64)
    if [[ -z "${ALLOW_EMULATION:-}" ]]; then
      die "Photog ${PHOTOG_TAG} is published for linux/arm64 only, and this is an
  x86-64 machine. 'docker compose pull' would fail with 'no matching
  manifest for linux/amd64'.

  An amd64 image is planned — see the README.

  To run it under emulation anyway (slow — the numerical runtime is what
  QEMU handles worst — and not recommended):

      docker run --privileged --rm tonistiigi/binfmt --install arm64
      ALLOW_EMULATION=1 bash install.sh"
    fi
    warn "x86-64 host, arm64 image: running under emulation. This will be slow."
    export DOCKER_DEFAULT_PLATFORM=linux/arm64
    ;;
  *) warn "unrecognised architecture $(uname -m); the image may not run here" ;;
esac

# --- fetch -----------------------------------------------------------------

say "installing into ${PHOTOG_DIR}"
mkdir -p "${PHOTOG_DIR}"
cd "${PHOTOG_DIR}"

for f in docker-compose.yml docker-compose.hailo.yml docker-compose.python.yml nginx.conf .env.example; do
  say "fetching ${f}"
  curl -fsSL "${RAW}/${f}" -o "${f}.tmp" || die "could not fetch ${RAW}/${f}"
  mv "${f}.tmp" "${f}"
done

# docker-compose.moondream.yml was renamed to docker-compose.python.yml. Left in
# place the stale file is harmless until someone's COMPOSE_FILE still names it,
# at which point they are running an overlay that no longer receives fixes.
if [[ -f docker-compose.moondream.yml ]]; then
  rm -f docker-compose.moondream.yml
  say "removed docker-compose.moondream.yml (superseded)"
fi

# Neither captioning overlay is needed any more: Moondream builds its Python
# environment on first enable, so the default image can do descriptions and the
# `-python` tag these overlays select is no longer published. An upgrader whose
# COMPOSE_FILE still names one would get "manifest unknown" from the next
# `pull`, which reads as a broken registry rather than a stale setting — so say
# so plainly instead of leaving them to find out.
if [[ -f .env ]] && grep -qE 'docker-compose\.(python|moondream)\.yml' .env; then
  warn "your .env names a captioning overlay in COMPOSE_FILE."
  warn "  It selects an image tag that is no longer published, so \`pull\` will fail."
  warn "  Remove it: COMPOSE_FILE=docker-compose.yml (plus the hailo overlay if you"
  warn "  have a card). Descriptions still work — enable Moondream in the UI."
fi

mkdir -p scripts
for s in env-detect.sh update-photog download-models.sh upgrade-hailort.sh rollback-hailort.sh; do
  if curl -fsSL "${RAW}/scripts/${s}" -o "scripts/${s}" 2>/dev/null; then
    chmod +x "scripts/${s}"
  else
    rm -f "scripts/${s}"
    warn "could not fetch scripts/${s}"
  fi
done

# hailo-detect.sh became env-detect.sh: same job, but it also writes defaults for
# capabilities that have nothing to do with the accelerator, so the name was
# actively misleading about where to add the next one. Left on disk the old copy
# keeps working for a while and then quietly stops matching the docs, which is
# the worst of both.
if [[ -f scripts/hailo-detect.sh ]]; then
  rm -f scripts/hailo-detect.sh
  say "removed scripts/hailo-detect.sh (now scripts/env-detect.sh)"
fi

# --- .env ------------------------------------------------------------------

# --- where the data lives --------------------------------------------------
#
# Asked once, up front, because the two defaults are both bad in different ways:
# with PHOTOG_WAREHOUSE_PATH unset the photo library goes into a named volume
# under /var/lib/docker — the SD card on a Pi, and somewhere nobody thinks to
# back up — and with PHOTOG_MODELS_PATH unset the Hailo overlay refuses to start
# at all. Both are easy to change later; neither is easy to notice.
#
# The database is deliberately NOT moved here. Postgres is fussy about the
# ownership and mode of its data directory, a bind mount adds a failure mode
# with no benefit for a database you should be backing up with pg_dump anyway,
# and `docker compose down -v` is the only thing that would lose it.

if [[ -f .env ]]; then
  say ".env already exists — leaving it alone"

  # Still make sure the directories it names exist and are writable. Re-running
  # the installer after moving a disk should fix the paths rather than leave a
  # container that starts and then cannot write.
  say "checking the directories .env points at"
  for var in PHOTOG_WAREHOUSE_PATH PHOTOG_IMPORT_PATH PHOTOG_MODELS_PATH; do
    val="$(grep -E "^${var}=" .env | head -1 | cut -d= -f2- || true)"
    [[ -z "$val" ]] && continue
    # A value with no slash is a named volume, not a path — leave it to Docker.
    [[ "$val" != */* ]] && continue
    label="${var#PHOTOG_}"; label="${label%_PATH}"
    ensure_dir "${val/#\~/$HOME}" "$(echo "$label" | tr '[:upper:]' '[:lower:]')"
  done
  # The compose default when PHOTOG_IMPORT_PATH is unset.
  grep -qE '^PHOTOG_IMPORT_PATH=' .env || ensure_dir "${PHOTOG_DIR}/import" "import"
else
  say "generating .env"

  data_root="${PHOTOG_DATA_ROOT:-}"
  if [[ -z "$data_root" ]] && [[ -r /dev/tty ]]; then
    printf '\n'
    echo "Where should Photog keep your photos?"
    echo
    echo "  This holds the photo library, the import folder and any AI model"
    echo "  files. It should be on a disk with room to grow — on a Raspberry Pi"
    echo "  that usually means an SSD or USB disk, not the SD card."
    echo
    read -r -p "data directory [${HOME}/photog-data]: " ans < /dev/tty || true
    data_root="${ans:-${HOME}/photog-data}"
  fi
  data_root="${data_root:-${HOME}/photog-data}"
  data_root="${data_root/#\~/$HOME}"

  printf '\n'
  say "creating directories under ${data_root}"
  ensure_dir "${data_root}/warehouse" "warehouse"
  ensure_dir "${data_root}/import"    "import"
  ensure_dir "${data_root}/models"    "models"

  # The database goes alongside them if the filesystem can carry it, so that
  # `docker compose down -v` cannot take it. Falls back to the named volume
  # rather than risking a database on storage that cannot hold one safely.
  db_path=""
  if bad_fs="$(db_fs_unsuitable "$data_root")"; then
    warn "${data_root} is on a ${bad_fs} filesystem."
    warn "  Postgres needs POSIX ownership and reliable fsync, which that cannot"
    warn "  give it — a database there risks corruption rather than a clean error."
    warn "  Keeping the database in a Docker named volume instead."
    warn "  It will NOT survive 'docker compose down -v'; back it up with pg_dump."
  else
    db_path="${data_root}/db"
    ensure_db_dir "$db_path"
  fi
  printf '\n'

  host="${PHX_HOST:-}"
  if [[ -z "$host" ]]; then
    short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo photog)"
    # mDNS gives .local on a Pi or a Mac; anywhere else it may not resolve, and
    # the value is easy to change afterwards.
    host="${short}.local"
  fi

  admin_email="${PHOTOG_ADMIN_EMAIL:-}"
  admin_pass="${PHOTOG_ADMIN_PASSWORD:-}"

  # Only prompt when there is a human attached. Piped into bash from curl, stdin
  # is the script itself, so read from the terminal explicitly.
  if [[ -z "$admin_email" || -z "$admin_pass" ]] && [[ -r /dev/tty ]]; then
    printf '\n'
    read -r -p "admin email [${admin_email:-you@example.com}]: " ans < /dev/tty || true
    admin_email="${ans:-${admin_email:-you@example.com}}"
    while [[ ${#admin_pass} -lt 12 ]]; do
      read -r -s -p "admin password (12+ chars, blank to generate one): " ans < /dev/tty || true
      printf '\n'
      if [[ -z "$ans" ]]; then
        admin_pass="$(openssl rand -base64 18)"
        say "generated admin password: ${admin_pass}"
        break
      fi
      admin_pass="$ans"
      [[ ${#admin_pass} -lt 12 ]] && warn "too short — 12 characters minimum"
    done
  fi

  if [[ -z "$admin_pass" ]]; then
    admin_email="${admin_email:-you@example.com}"
    admin_pass="$(openssl rand -base64 18)"
    say "generated admin password: ${admin_pass}"
  fi

  umask 077
  cat > .env <<ENV
# Written by install.sh on $(date -u '+%Y-%m-%d %H:%M UTC').
# Full reference: https://github.com/unsilo/photog-docker/blob/main/.env.example

# Which compose files to use. Compose reads this from .env, so every
# \`docker compose\` command in this directory picks them up with no -f flags.
# There is one overlay worth adding, and only if you have a Hailo card:
#
#   Hailo accelerator      docker-compose.yml:docker-compose.hailo.yml
#
# It also needs the values scripts/env-detect.sh prints.
#
# Image descriptions are NOT a compose choice — every image can caption, and the
# environment for it is built the first time you enable the classifier.
COMPOSE_FILE=docker-compose.yml

PHX_HOST=${host}
SECRET_KEY_BASE=$(openssl rand -base64 48)
POSTGRES_PASSWORD=$(openssl rand -hex 24)

PHOTOG_ADMIN_EMAIL=${admin_email}
PHOTOG_ADMIN_PASSWORD=${admin_pass}

PHOTOG_TAG=${PHOTOG_TAG}

# Your data. All three are ordinary directories on this machine, owned by uid
# 1000 so the container can write them. Move them by changing these values and
# running \`docker compose up -d\` — copy the contents across first, with
# \`sudo cp -a\` so ownership is preserved.
#
# Photo library: originals and thumbnails. The one that must be backed up.
PHOTOG_WAREHOUSE_PATH=${data_root}/warehouse
# Drop photos here to import them.
PHOTOG_IMPORT_PATH=${data_root}/import
# Hailo .hef model files, and (see docs) the bumblebee HuggingFace cache.
# Only used with docker-compose.hailo.yml, which requires it.
PHOTOG_MODELS_PATH=${data_root}/models
${db_path:+# The database, on your own filesystem so \`down -v\` cannot take it.
# Do NOT chown this — the postgres image manages its own ownership.
# Still take pg_dump backups: a raw data directory is readable only by the
# Postgres major version that wrote it.
PHOTOG_DB_PATH=${db_path}}
ENV
  chmod 600 .env
  say "wrote .env (mode 600)"
fi

# shellcheck disable=SC1091
PHX_HOST_EFFECTIVE="$(grep -E '^PHX_HOST=' .env | cut -d= -f2-)"
PORT_EFFECTIVE="$(grep -E '^PHOTOG_HTTP_PORT=' .env | cut -d= -f2- || true)"
PORT_EFFECTIVE="${PORT_EFFECTIVE:-80}"

# --- what to do next -------------------------------------------------------
#
# This installer deliberately does NOT start the stack.
#
# Starting here would be wrong on any machine with an accelerator: COMPOSE_FILE
# is `docker-compose.yml` at this point, so `up -d` would build a base-stack
# container with no device, no HailoRT mounts and an empty models directory —
# and then the real configuration would need `--force-recreate` to replace it.
# The first thing the user sees would be an install that appears to work and
# quietly cannot classify anything.
#
# Hailo setup also has to come first in the other direction: env-detect.sh
# reads the device to write HAILO_DEVICE, HAILO_GID and the libhailort soname,
# and none of that can be known before the hardware is inspected.
#
# So: configure, then hand over.

printf '\n'
if [[ "$PORT_EFFECTIVE" == "80" ]] && ss -ltn 2>/dev/null | grep -qE ':80\s'; then
  warn "something is already listening on port 80. Set PHOTOG_HTTP_PORT (and
       PHOTOG_IMAGE_URL_BASE) in .env before starting — see .env.example."
  printf '\n'
fi

url="http://${PHX_HOST_EFFECTIVE}"
[[ "$PORT_EFFECTIVE" != "80" ]] && url="${url}:${PORT_EFFECTIVE}"

say "installed into ${PHOTOG_DIR} — nothing started yet"
printf '\n'

# Look for a Hailo without needing the detect script, so the next step can be
# named specifically rather than offered as a menu.
have_hailo=0
shopt -s nullglob
hailo_nodes=(/dev/hailo[0-9]* /dev/h1x-[0-9]*)
shopt -u nullglob
[[ ${#hailo_nodes[@]} -gt 0 ]] && have_hailo=1

if [[ "$have_hailo" == "1" ]]; then
  echo "  A Hailo accelerator is present (${hailo_nodes[0]}). Set it up before starting:"
  echo
  echo "    cd ${PHOTOG_DIR}"
  echo "    ./scripts/env-detect.sh --append    # writes the device settings to .env"
  echo "    ./scripts/download-models.sh          # fetches the .hef model files"
  echo
  echo "  Then add the overlay to COMPOSE_FILE in .env — env-detect.sh prints"
  echo "  the exact line for your hardware, including the captioning options:"
  echo
  echo "    COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml"
  echo
  echo "  And start it:"
  echo
  echo "    docker compose up -d"
else
  echo "  No accelerator detected — nothing else to configure. Start it with:"
  echo
  echo "    cd ${PHOTOG_DIR}"
  echo "    docker compose up -d"
  echo
  echo "  Classification and image descriptions both work without an"
  echo "  accelerator, on the CPU. Enable them on the Classifiers page; the"
  echo "  first enable of Moondream builds its Python environment, which takes"
  echo "  a few minutes once."
fi

import_dir="$(grep -E '^PHOTOG_IMPORT_PATH=' .env | head -1 | cut -d= -f2- || true)"

printf '\n'
echo "  First start pulls ~1-2GB and then runs migrations; give it a few minutes"
echo "  on a Pi before deciding it is stuck."
printf '\n'
echo "  then                 ${url}"
echo "  log in with          the admin email and password in ${PHOTOG_DIR}/.env"
echo "  photos to import ->  ${import_dir:-${PHOTOG_DIR}/import}"
echo "  logs             ->  cd ${PHOTOG_DIR} && docker compose logs -f photog"
echo "  stop             ->  cd ${PHOTOG_DIR} && docker compose down"
echo "  update later     ->  cd ${PHOTOG_DIR} && ./scripts/update-photog"
printf '\n'
echo "  update-photog backs up the database, takes the current compose files,"
echo "  pulls and restarts, then checks it came back. Use it rather than a bare"
echo "  \`docker compose pull\` — a release can change the compose file, and"
echo "  Compose ignores settings the file on your disk does not mention."
printf '\n'
