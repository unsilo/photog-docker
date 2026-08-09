# PhoTog

Self-hosted photo archive. You point it at a folder of photos, it organises
them — albums, tags, ratings, smart albums, EXIF, thumbnails — and serves them
over your own network. Nothing leaves the machine it runs on.

This repository is how you **run** it: Docker Compose files, an installer, and
the documentation. The application image comes from Docker Hub. The application
source is not published.

> **v0.1.0 — first release.** The CPU path is what this release is for. It runs
> on a stock Raspberry Pi — or any **arm64** machine — with no accelerator and
> no host packages. There is no x86-64 image yet; see
> [arm64 only, for now](#arm64-only-for-now). Hailo acceleration works on bare
> metal but its Docker path is
> **experimental and untested** — see [docs/hailo.md](docs/hailo.md) before
> counting on it.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh | bash
```

That creates `~/photog`, fetches the compose files, generates the secrets, asks
for an admin email and password, and brings the stack up. When it finishes it
prints the URL.

Prefer to read the script first:

```bash
curl -fsSLO https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh
less install.sh
bash install.sh
```

Or do it by hand — four files, four values:

```bash
mkdir -p ~/photog/import && cd ~/photog
curl -fsSLO https://raw.githubusercontent.com/unsilo/photog-docker/main/docker-compose.yml
curl -fsSLO https://raw.githubusercontent.com/unsilo/photog-docker/main/nginx.conf
curl -fsSL  https://raw.githubusercontent.com/unsilo/photog-docker/main/.env.example -o .env
chmod 600 .env

# fill in PHX_HOST, SECRET_KEY_BASE, POSTGRES_PASSWORD, PHOTOG_ADMIN_PASSWORD
#   openssl rand -base64 48    -> SECRET_KEY_BASE
#   openssl rand -hex 24       -> POSTGRES_PASSWORD

docker compose up -d
```

Then open `http://<PHX_HOST>` and log in with `PHOTOG_ADMIN_EMAIL` /
`PHOTOG_ADMIN_PASSWORD`.

**`nginx.conf` is not optional.** The compose file bind-mounts it, and Docker
creates a *directory* at a bind-mount source that does not exist — nginx then
fails on a config path that is not a file.

---

## What you need

| | |
|---|---|
| CPU | **arm64 only in 0.1.0** — see below |
| OS | 64-bit Linux. On a Raspberry Pi that means the **64-bit** build of Raspberry Pi OS; a 32-bit userland cannot run this image. |
| Docker | Engine 24+ with the Compose v2 plugin. `curl -fsSL https://get.docker.com \| sudo sh` |
| Disk | ~3 GB for the images, plus whatever your photo library needs |
| RAM | 2 GB works. 4 GB or more is comfortable. |
| Ports | 80 (change with `PHOTOG_HTTP_PORT`) |

A Raspberry Pi 5 with an SSD is the machine this was built for. A Pi 4 works;
imports are slower.

### arm64 only, for now

The 0.1.0 image is published for **`linux/arm64`** and nothing else. That covers:

- Raspberry Pi 5 and Pi 4 on 64-bit Raspberry Pi OS — the primary target
- other arm64 single-board computers and arm64 VMs
- Apple Silicon Macs (M1 and later) through Docker Desktop
- arm64 NAS hardware

It does **not** cover an x86-64 machine — an Intel or AMD laptop, desktop,
mini-PC or NAS. `docker compose pull` there fails with `no matching manifest for
linux/amd64`, which looks like a broken publish and is not.

`linux/amd64` is planned and is a build-infrastructure problem rather than a
code one: the app is portable, but cross-building it under emulation takes hours
per attempt. It will arrive when the build moves to native runners. Watch the
releases page.

Running it on x86 today is possible under emulation and not recommended — the
numerical runtime is exactly the sort of code QEMU is worst at:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
# then add to .env:  DOCKER_DEFAULT_PLATFORM=linux/arm64
```

Expect it to be slow enough that you will not want to keep it.

---

## Pick your hardware

### Stock Raspberry Pi, arm64 NAS, or Apple Silicon Mac — no accelerator

The quick start above is the whole story. The AI classifiers appear in the UI
and ship disabled; everything else — import, albums, tags, ratings, smart
albums, the photo viewer, the native clients — works.

### Raspberry Pi 5 + Hailo-8 (AI HAT+), or + Hailo-10H (AI HAT+ 2)

Start with the quick start. Get PhoTog running on the CPU first and confirm you
can log in and import a photo — an accelerator adds classification to a working
install, it is not part of getting one.

Then read **[docs/hailo.md](docs/hailo.md)**. The short version:

1. Install the host packages (`hailo-all` for a Hailo-8, `hailo-h10-all` for a
   Hailo-10H) and reboot. Nothing in a container can do this for you.
2. Run `./scripts/hailo-detect.sh`, which checks the four things that have to
   line up and prints the `.env` lines to paste.
3. Set `PHOTOG_MODELS_PATH` in `.env`, then `./scripts/download-models.sh` —
   it picks the right architecture and SDK version and verifies what it fetched.
4. Bring the stack up with the overlay:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d
   ```
5. Enable a classifier at `/classifier`.

Captioning additionally needs **HailoRT 5.3.0**, which is newer than
`apt install hailo-h10-all` gives you — `./scripts/upgrade-hailort.sh` handles
that, with `./scripts/rollback-hailort.sh` to undo it.

**Status:** detection and classification are confirmed working in Docker on a
Raspberry Pi 5 + Hailo-10H. Captioning needs HailoRT 5.3.0, which is newer than
the Raspberry Pi archive ships — see [docs/hailo.md](docs/hailo.md). The Hailo-8
path is untested.

The
image ships no HailoRT python bindings — they are not on PyPI, and baking one
version in would be wrong for every host running a different driver — so the
overlay borrows the host's copy. That keeps driver, library and bindings in
lockstep automatically, at the cost of requiring the host and the container to
be on the same CPython minor version. Raspberry Pi OS **Trixie** matches the
image; **Bookworm** does not. [docs/hailo.md](docs/hailo.md) explains what to do
about it.

---

## Where things live

| | |
|---|---|
| `~/photog/import` | drop photos here to import them |
| `~/photog/.env` | your configuration and credentials — back this up |
| `photog-warehouse` volume | originals and thumbnails. Point it at a real disk with `PHOTOG_WAREHOUSE_PATH`. |
| `photog-db` volume | the database |
| `photog-cache` volume | upload staging and downloaded models |

A named volume lives under `/var/lib/docker` — on a Pi, that is the SD card.
Before you import a library of any size, set `PHOTOG_WAREHOUSE_PATH` to a
mounted disk:

```bash
sudo mkdir -p /mnt/photos && sudo chown 1000:1000 /mnt/photos
```

The `1000:1000` matters: the container runs as uid 1000 and cannot write a
root-owned directory. Getting it wrong shows up as thumbnails that never appear,
not as an error at startup.

---

## Everyday commands

```bash
cd ~/photog

docker compose logs -f photog          # what it is doing
docker compose ps                      # what is running
docker compose restart photog          # restart just the app
docker compose down                    # stop (volumes survive)
docker compose pull && docker compose up -d    # upgrade
```

`docker compose down -v` deletes the volumes, and with them your photos and
database. There is no confirmation prompt.

---

## Documentation

- **[docs/configuration.md](docs/configuration.md)** — every environment
  variable, what it does, and what breaks when it is wrong
- **[docs/hailo.md](docs/hailo.md)** — Hailo-8 and Hailo-10H setup, and why this
  is the hardest part of the stack
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — organised by symptom
- **[docs/upgrading.md](docs/upgrading.md)** — upgrades, backups, restores

---

## Known limitations in 0.1.0

Listed because you will hit them, not as an apology.

- **No email.** The mailer is not wired up, so password reset and self-service
  registration do not work. The admin account is created from `.env` on first
  boot; that is the only way in. `PHOTOG_ALLOW_REGISTRATION` exists but needs a
  mailer to be useful.
- **One library, not one per user.** There is no per-user ownership of photos,
  albums or tags. A second account is a second key to the same library.
- **No HTTPS.** The proxy serves plain HTTP. Put PhoTog on a network you trust,
  or terminate TLS in front of it (see
  [docs/configuration.md](docs/configuration.md)).
- **No authentication on `/media`.** Images are served by the endpoint before
  the router runs, so no session check applies. Anyone who can reach the server
  and guess a path can fetch an image.
- **The upload endpoint has no size limit of its own.** It is authenticated by a
  client token, but a request body is read whole into memory with no ceiling.
  The 1 GB cap in `nginx.conf` is the only thing bounding it — don't remove it,
  and don't expose the app port directly.
- **Import fails noisily on a bad path.** Typing a directory that does not exist
  into the import form crashes the page instead of reporting the error, after
  creating an empty import record.
- **Hailo in Docker is unverified.** See above and
  [docs/hailo.md](docs/hailo.md).
- **The `moondream` and `qwen2` classifiers are not usable in this image.** They
  need a Python environment and model files that are not shipped.
- **Idle memory is higher than it should be.** The numerical runtime loads at
  boot whether or not any classifier is enabled.

---

## Reporting problems

Open an issue at
[github.com/unsilo/photog-docker/issues](https://github.com/unsilo/photog-docker/issues)
with:

```bash
docker compose ps
docker compose logs --tail=200 photog
uname -m && docker --version && docker compose version
```

and, for anything Hailo-related, the full output of
`./scripts/hailo-detect.sh`.

---

## Licence

PhoTog is free to run for personal, non-commercial use. The image is closed
source and may not be redistributed or reverse-engineered. See
[LICENSE](LICENSE).

The compose files, scripts and documentation in *this repository* are provided
so you can run and adapt the software on your own machines; the licence covers
the image, not your `.env`.
