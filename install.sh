#!/usr/bin/env bash
#
# PhoTog installer. Fetches the compose files, generates the secrets, writes a
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
#   PHOTOG_TAG   image tag to run         (default 0.1.0)
#   PHX_HOST     hostname to serve at     (default <hostname>.local, or localhost)
#   NO_START=1   write the files, do not start anything

set -euo pipefail

PHOTOG_DIR="${PHOTOG_DIR:-$HOME/photog}"
PHOTOG_REF="${PHOTOG_REF:-main}"
PHOTOG_TAG="${PHOTOG_TAG:-0.1.0}"
RAW="https://raw.githubusercontent.com/unsilo/photog-docker/${PHOTOG_REF}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

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
  armv7l|armv6l) die "32-bit ARM is not supported. PhoTog needs a 64-bit OS —
  on a Raspberry Pi that means the 64-bit build of Raspberry Pi OS." ;;
  x86_64|amd64)
    if [[ -z "${ALLOW_EMULATION:-}" ]]; then
      die "PhoTog ${PHOTOG_TAG} is published for linux/arm64 only, and this is an
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
mkdir -p "${PHOTOG_DIR}/import"
cd "${PHOTOG_DIR}"

for f in docker-compose.yml docker-compose.hailo.yml nginx.conf .env.example; do
  say "fetching ${f}"
  curl -fsSL "${RAW}/${f}" -o "${f}.tmp" || die "could not fetch ${RAW}/${f}"
  mv "${f}.tmp" "${f}"
done

mkdir -p scripts
if curl -fsSL "${RAW}/scripts/hailo-detect.sh" -o scripts/hailo-detect.sh 2>/dev/null; then
  chmod +x scripts/hailo-detect.sh
else
  warn "could not fetch scripts/hailo-detect.sh (only needed for Hailo setups)"
fi

# --- .env ------------------------------------------------------------------

if [[ -f .env ]]; then
  say ".env already exists — leaving it alone"
else
  say "generating .env"

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

PHX_HOST=${host}
SECRET_KEY_BASE=$(openssl rand -base64 48)
POSTGRES_PASSWORD=$(openssl rand -hex 24)

PHOTOG_ADMIN_EMAIL=${admin_email}
PHOTOG_ADMIN_PASSWORD=${admin_pass}

PHOTOG_TAG=${PHOTOG_TAG}
ENV
  chmod 600 .env
  say "wrote .env (mode 600)"
fi

# shellcheck disable=SC1091
PHX_HOST_EFFECTIVE="$(grep -E '^PHX_HOST=' .env | cut -d= -f2-)"
PORT_EFFECTIVE="$(grep -E '^PHOTOG_HTTP_PORT=' .env | cut -d= -f2- || true)"
PORT_EFFECTIVE="${PORT_EFFECTIVE:-80}"

# --- start -----------------------------------------------------------------

if [[ -n "${NO_START:-}" ]]; then
  say "NO_START set — files are in ${PHOTOG_DIR}, nothing started"
  exit 0
fi

if [[ "$PORT_EFFECTIVE" == "80" ]] && ss -ltn 2>/dev/null | grep -qE ':80\s'; then
  warn "something is already listening on port 80. If the proxy fails to start,
       set PHOTOG_HTTP_PORT (and PHOTOG_IMAGE_URL_BASE) in .env — see .env.example."
fi

say "pulling images (first run downloads ~1-2GB and takes a while)"
docker compose pull

say "starting"
docker compose up -d

printf '\n'
say "waiting for the app to become healthy"
for _ in $(seq 1 60); do
  state="$(docker compose ps --format '{{.Health}}' photog 2>/dev/null | head -1)"
  [[ "$state" == "healthy" ]] && break
  sleep 5
done

printf '\n'
if [[ "${state:-}" == "healthy" ]]; then
  url="http://${PHX_HOST_EFFECTIVE}"
  [[ "$PORT_EFFECTIVE" != "80" ]] && url="${url}:${PORT_EFFECTIVE}"
  say "PhoTog is up at ${url}"
  say "log in with the admin email and password in ${PHOTOG_DIR}/.env"
  printf '\n'
  echo "  photos to import   ->  ${PHOTOG_DIR}/import"
  echo "  logs               ->  cd ${PHOTOG_DIR} && docker compose logs -f photog"
  echo "  stop               ->  cd ${PHOTOG_DIR} && docker compose down"
else
  warn "the app has not reported healthy yet. First boot runs migrations and can
       take a few minutes on a Pi. Watch it with:

         cd ${PHOTOG_DIR} && docker compose logs -f photog

       If it is stuck, see docs/troubleshooting.md."
fi
