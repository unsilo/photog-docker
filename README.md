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

### The reference deployment

**A Raspberry Pi 5 booting from an NVMe drive.** That is the machine this is
built and tested for, and it is the configuration to copy if you have no reason
to do otherwise. Booting from NVMe puts `/var/lib/docker`, the database, the
photo library and the thumbnail cache all on fast storage without any of them
needing special handling.

A Pi 4 works. A Pi 5 on an SD card works and will be slow at import time, and
the SD card is where the wear from thumbnailing and Postgres WAL lands.

**If you want an accelerator as well, check the PCIe budget first.** A Pi 5 has
**one** PCIe lane. The AI HAT+ and AI HAT+ 2 occupy it, and so does an NVMe HAT
— you cannot simply stack both. Combining them needs a dual-M.2 carrier with a
PCIe switch, and every one currently sold advertises Hailo-8/8L support rather
than Hailo-10H:

- [Seeed PCIe 3.0 dual M.2 HAT](https://www.seeedstudio.com/PCIe3-0-to-dual-M-2-hat-for-Raspberry-Pi-5-p-6358.html)
- [Seeed PCIe 2.0 dual M.2 HAT](https://www.seeedstudio.com/PCIe-to-dual-M-2-hat-for-Raspberry-Pi-5-p-5973.html)
- [SunFounder dual NVMe Raft](https://www.amazon.com/SunFounder-Raspberry-Hailo-8L-Accelerator-Compatible/dp/B0FC27KH3X)

Both devices then share the one lane. That is fine for inference — a 640×640
frame is about 1.2 MB and results are tiny — but it is shared with every
database write and thumbnail read, so use the Gen 3 board if you are buying one.

**The way round it is USB.** A Hailo-10H on the AI HAT+ 2 using the PCIe lane,
with an NVMe drive in a USB 3 enclosure, gets you both without a switch card.
Pi 5 USB 3 is well clear of anything PhoTog does — the accelerator's PCIe
traffic and the disk are on separate buses entirely. This is a supported and
recommended configuration.

Two things to get right if you go that way, because the failure mode is a drive
that drops off mid-write, and that corrupts databases:

- **Use a 5 V/5 A supply.** The official 27 W one. A Pi 5 on a lesser supply
  limits total USB current, and an NVMe enclosure can exceed that on write
  bursts. Check with `vcgencmd get_config usb_max_current_enable` and look for
  `Under-voltage` in `dmesg`.
- **Use a UASP-capable enclosure**, and check for known-bad USB bridges. Some
  JMicron and ASMedia chipsets need a `usb-storage.quirks=VID:PID:u` kernel
  argument on a Pi and will otherwise hang or corrupt data under sustained
  write. `lsusb -t` will tell you whether you got `uas` or plain
  `usb-storage`.

**The other way round it is a 2-channel PCIe FFC adapter** — a Gen 2 switch
that fans the Pi's single lane into two FFC connectors, so an AI HAT and an
NVMe HAT each keep their native connector. This is the only option that puts a
*HAT-format* accelerator and PCIe storage on the same Pi; the dual-M.2 carriers
above only take M.2 modules, and the AI HAT+ 2's Hailo-10H is not removable.

It buys capacity and a tidier box rather than speed — Gen 2 shared is about the
same as USB 3, and storage is not the bottleneck here anyway. Three things to
check before committing to it:

- **Bench-test that both devices enumerate** before any case work.
  `lspci -nn` should list both, and `sudo lspci -vv | grep -i lnksta` should
  show 5GT/s. Switches on the Pi 5 mostly work and occasionally do not.
- **Leave `dtparam=pciex1_gen=3` off.** The switch is Gen 2; forcing Gen 3
  upstream of it manufactures instability.
- **Mind the 5 V rail and the physical stack.** Two devices on one supply, and
  adapter + AI HAT + NVMe HAT is tall — it does not fit every case.

Five configurations, then:

| | Storage | Accelerator |
|---|---|---|
| Baseline | NVMe boot (PCIe) | none |
| **Recommended with AI** | **NVMe over USB 3** | **Hailo-10H, AI HAT+ 2 on PCIe** |
| Tidiest with AI | NVMe HAT (PCIe, 2-ch FFC switch) | Hailo-10H, AI HAT+ 2 on the same switch |
| Alternative | NVMe (PCIe, dual-M.2 switch) | Hailo-8/8L M.2 on the same switch |
| Not advised | SD card | either |

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

## Which image, which overlays

Two images are published from the same source. The difference is what's
bundled, not which chip you have.

| Tag | Contains | Use it when |
|---|---|---|
| `:0.1.1`, `:latest` | the application | anything except CPU captioning |
| `:0.1.1-python` | + the ~1 GB Python environment for Moondream | you want captions without a Hailo-10H |

Overlays layer on top of `docker-compose.yml` and compose with each other:

| Your machine | Command |
|---|---|
| No accelerator | `-f docker-compose.yml` |
| No accelerator, want captions | `-f docker-compose.yml -f docker-compose.moondream.yml` |
| Hailo-8 (AI HAT+) | `-f docker-compose.yml -f docker-compose.hailo.yml` |
| Hailo-8, want captions | `… -f docker-compose.hailo.yml -f docker-compose.moondream.yml` |
| Hailo-10H (AI HAT+ 2) | `-f docker-compose.yml -f docker-compose.hailo.yml` |

**Captioning splits by hardware.** `qwen2` runs on the accelerator but needs a
**Hailo-10H and HailoRT 5.3.0** — it cannot work on a Hailo-8. `moondream` is a
0.5B model that runs on the CPU, needs no accelerator at all, and is the only
captioning option for everything else. It is not in the default image because
its Python environment is about a gigabyte.

There is deliberately **no separate Hailo-8 compose file**. A Hailo-8 needs
nothing structurally different — `docker-compose.hailo.yml` takes the device
node, group id, host bindings and model directory as variables, and
`scripts/hailo-detect.sh` fills in whichever generation is installed. Layer
`moondream` on top for captions.

**Don't type those flags every time.** Compose reads `COMPOSE_FILE` from `.env`,
so set it once and every command — `up`, `logs`, `pull`, `exec`, `down` — picks
up the right files with no flags at all:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml:docker-compose.moondream.yml
```

```bash
docker compose up -d          # uses all three
docker compose logs -f photog
```

`install.sh` writes the base value; add overlays to it as you enable them.
Passing `-f` explicitly still overrides, so the longhand in these docs keeps
working.

---

## Where things live

The installer asks where your data should go and creates it. Default layout:

```
~/photog/                 the install — compose files, nginx.conf, .env
~/photog-data/
  warehouse/              originals and thumbnails — THE thing to back up
  import/                 drop photos here to import them
  models/                 AI model files (and the bumblebee download cache)
  db/                     the database, out of reach of `down -v`
```

Answer the installer's question with `/mnt/photos` (or wherever your disk is
mounted) and all three land there instead. Config and data stay separate on
purpose: you can delete and reinstall `~/photog` without touching photos.

Only `photog-cache` — upload staging and downloaded models, all rebuildable —
stays in a Docker named volume.

The database goes in `db/` so that `docker compose down -v` cannot delete it.
That is as safe as a named volume on a local ext4/xfs/btrfs disk, since a named
volume is itself just a directory on one; the installer checks the filesystem
and falls back to a named volume on anything that can't hold a database safely
(NFS, SMB, exFAT). **It is still not a backup** — a raw data directory is
readable only by the Postgres major version that wrote it. Keep taking
`pg_dump`, see [docs/upgrading.md](docs/upgrading.md).

**Back up `~/photog/.env`.** It holds your credentials, and losing
`POSTGRES_PASSWORD` locks you out of your own database.

If you set the paths by hand rather than using the installer, every directory
must be owned by **uid 1000** — the container runs as that user and cannot write
a directory it does not own:

```bash
sudo mkdir -p /mnt/photos/{warehouse,import,models}
sudo chown -R 1000:1000 /mnt/photos
```

Getting that wrong is quiet: thumbnails never appear, or the import folder shows
up empty. Nothing fails at startup.

**With no `PHOTOG_WAREHOUSE_PATH` set at all**, the library goes into a named
volume under `/var/lib/docker` — the SD card on a Pi, and somewhere nobody
thinks to back up. Set it before importing anything.

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
- **Captioning needs either a Hailo-10H or the `-python` image.** `qwen2` is
  Hailo-10H only and additionally needs HailoRT 5.3.0, which is newer than the
  Raspberry Pi archive ships. `moondream` runs on the CPU but is only in the
  `-python` variant. See the table above.
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
