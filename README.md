# Photog

Photog is a self-hosted photo archiving and organising app. It automatically
organises your digital images and lets you search them by date, location,
dominant colour, or anything else recorded in the EXIF data.

Photog is good at organising folders of photos, and it really shines alongside
the companion macOS, iOS and tvOS apps. The macOS app archives everything in
your Photos library. The tvOS app turns any album into a slideshow. No cloud
account, no upload — all of it over your own local network.

Photog also does AI classification, either in software or accelerated by a
Hailo-8 or Hailo-10H card. Whether your photos are in a Photos library, on a USB
drive or on a DVD, it sorts them into albums, tags, ratings, smart albums, EXIF
and thumbnails, and serves them on your own network. Nothing leaves the machine
it runs on.

The supported way to run it is Docker Compose. What follows works from a fresh
install of Debian Trixie or Raspberry Pi OS.


## Quick start

### 1. Update and Install Docker

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot

curl -sSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker
```

### 2. Install the Hailo software — optional

Only if you have a Hailo card and want to utilize it. Skip to step 3 otherwise.
Set up the toolchain.

**Set up the build toolchain**:

```bash
sudo apt install -y dkms build-essential "linux-headers-$(uname -r)"
ls -d /lib/modules/$(uname -r)/build      # must exist — this is the real check
```

**Hailo-8 (AI HAT+)** — accelerates classification, cannot do descriptions:

```bash
sudo apt install hailo-all
sudo reboot
```

**Hailo-10H (AI HAT+ 2)** — accelerates both:

```bash
sudo apt install hailo-h10-all
sudo reboot
```

After the reboot, check the card is alive before going further:

```bash
hailortcli fw-control identify
```

That should print the device architecture. If it doesn't, fix it now — see
[docs/hailo.md](docs/hailo.md). Nothing in a container can install a kernel
driver for you.

On a **Hailo-10H** this leaves you on HailoRT **5.1.1**, which accelerates
classification but cannot do descriptions. Follow these instructions [docs/upgrade_hailo.md](docs/upgrade_hailo.md) to enable acccelerated descriptions.

### 3. Install Photog

```bash
curl -fsSL https://raw.githubusercontent.com/unsilo/photog-docker/main/install.sh | bash
```

Answer the prompts: where your photos should live, and an admin email and
password.

That creates `~/photog`, fetches the compose files, creates your data
directories and generates the secrets. **It does not start anything** — it
finishes by printing the exact command to run next.

### 4. Set up the accelerator — Hailo only

```bash
cd ~/photog
./scripts/hailo-detect.sh --append   # writes the device settings into .env
./scripts/download-models.sh         # fetches the .hef model files
```

`hailo-detect.sh` inspects the card and writes the device node, group id and
library paths into `.env` — none of which can be known before the hardware is
looked at. It also **sets `COMPOSE_FILE`** to match what it found, so step 5 is
usually already done:

| What it finds | What it sets |
|---|---|
| Hailo-10H | `docker-compose.yml:docker-compose.hailo.yml` |
| Hailo-8 | `…:docker-compose.hailo.yml:docker-compose.python.yml` (+ `PHOTOG_PYTHON_TAG`) |
| no card | `docker-compose.yml` |

The Hailo-8 line assumes you want descriptions, since that card cannot produce
them itself. The script prints how to drop the extra overlay if you would rather
have the smaller image.

`download-models.sh` fetches all three models by default, and the captioning one
is ~3 GB. Skip it with `--vision-only` — on a Hailo-8 it cannot be used anyway.
`--list` shows what there is.

### 5. Choose your features — usually already done

If step 4 ran with `--append`, `COMPOSE_FILE` is set. Check it:

```bash
grep COMPOSE_FILE ~/photog/.env
```

Otherwise set it in `.env` yourself, from
[the table below](#what-the-ai-features-give-you). For a Hailo-10H:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml
```

### 6. Start it

```bash
cd ~/photog
docker compose up -d
```

First start pulls 1–2 GB and then runs database migrations. Give it a few
minutes on a Pi before deciding it is stuck; `docker compose logs -f photog`
shows what it is doing.

Then open `http://<PHX_HOST>` — `http://photog.local` by default — and log in
with the admin email and password from `.env`.

Turn classifiers on at `/classifier`. They all ship disabled.

---

### Doing it by hand

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

**`nginx.conf` is not optional.** The compose file bind-mounts it, and Docker
creates a *directory* at a bind-mount source that does not exist — nginx then
fails on a config path that is not a file.

---

## What the AI features give you

Photog does two separate AI jobs, and what you get depends on your hardware.
**Classification** puts tags on photos — objects, scenes, subjects.
**Descriptions** write a sentence or two about each photo.

| Your hardware | Classification | Descriptions | `COMPOSE_FILE` |
|---|---|---|---|
| No accelerator | software — slow | unavailable | `docker-compose.yml` |
| No accelerator | software — slow | software — slow *(moondream)* | `docker-compose.yml:docker-compose.python.yml` |
| **Hailo-8** (AI HAT+) | **accelerated** | software — slow *(moondream)* | `docker-compose.yml:docker-compose.hailo.yml:docker-compose.python.yml` |
| **Hailo-10H** (AI HAT+ 2) | **accelerated** | **accelerated** *(qwen2 — ~12 s/photo)* | `docker-compose.yml:docker-compose.hailo.yml` |

Put that line in `.env` and every `docker compose` command picks it up — no `-f`
flags to remember. The rows using `docker-compose.python.yml` also need
`PHOTOG_PYTHON_TAG=0.1.3-python`, because software descriptions need a larger
image that bundles a Python environment.

Three things worth knowing before you choose:

- **A Hailo-8 cannot do descriptions.** `qwen2` needs a Hailo-10H and HailoRT
  5.3.0; there is no model, runtime version or setting that changes that. A
  Hailo-8 still accelerates classification, and `moondream` on the CPU covers
  descriptions.
- **The last row needs one extra step.** `apt install hailo-h10-all` gives you
  HailoRT 5.1.1, and no captioning model is published below 5.3.0 — so a
  stock Hailo-10H install accelerates classification but not descriptions until
  you upgrade the runtime. See
  [docs/upgrade_hailo.md](docs/upgrade_hailo.md). Classification works
  either way.
- **Everything else works with no accelerator at all** — import, albums, tags,
  ratings, smart albums, the photo viewer, the native clients. The AI is an
  addition, not a requirement, and every classifier ships disabled.

---


## What you need

| | |
|---|---|
| CPU | **arm64 only in 0.1.x** — see below |
| OS | 64-bit Linux. On a Raspberry Pi that means the **64-bit** build of Raspberry Pi OS; a 32-bit userland cannot run this image. |
| Docker | Engine 24+ with the Compose v2 plugin |
| Disk | ~3 GB for the images, plus your photo library |
| RAM | 2 GB works. 4 GB or more is comfortable. |
| Ports | 80 (change with `PHOTOG_HTTP_PORT`) |

### The reference deployment

**A Raspberry Pi 5 booting from an NVMe drive.** That is what this is built and
tested on. Booting from NVMe puts `/var/lib/docker`, the database, the photo
library and the thumbnail cache on fast storage without any of them needing
special handling.

A Pi 4 works. A Pi 5 on an SD card works and will be slow at import, and the SD
card takes the wear from thumbnailing and Postgres.

**If you want an accelerator too, mind the PCIe budget.** A Pi 5 has **one**
PCIe lane, and the AI HAT+ and AI HAT+ 2 occupy it — as does an NVMe HAT. The
straightforward answer is an NVMe drive in a **USB 3 enclosure** alongside the
AI HAT: USB 3 is well clear of anything Photog does, and the two are on separate
buses. That is a supported and recommended configuration.

If you want both on PCIe, a 2-channel PCIe FFC adapter (a Gen 2 switch with two
downstream FFC ports) lets each HAT keep its native connector. It buys capacity
and a tidier box rather than speed. Bench-test that both devices enumerate
(`lspci -nn`, then `lspci -vv | grep -i lnksta` for 5GT/s) before any case work,
and leave `dtparam=pciex1_gen=3` off — the switch is Gen 2.

| | Storage | Accelerator |
|---|---|---|
| Baseline | NVMe boot (PCIe) | none |
| **Recommended with AI** | **NVMe over USB 3** | **Hailo-10H, AI HAT+ 2 on PCIe** |
| Tidiest with AI | NVMe HAT (PCIe, 2-ch FFC switch) | Hailo-10H on the same switch |
| Not advised | SD card | either |

### arm64 only, for now

The image is published for **`linux/arm64`** and nothing else. That covers
Raspberry Pi 4 and 5 on 64-bit Raspberry Pi OS, other arm64 boards and VMs,
Apple Silicon Macs through Docker Desktop, and arm64 NAS hardware.

It does **not** cover an x86-64 machine. `docker compose pull` there fails with
`no matching manifest for linux/amd64`, which looks like a broken publish and is
not. `linux/amd64` is a build-infrastructure problem rather than a code one —
cross-building under emulation takes hours per attempt — and will arrive when
the build moves to native runners.

Under emulation it is possible and not recommended; the numerical runtime is
exactly what QEMU is worst at:

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64
# then add to .env:  DOCKER_DEFAULT_PLATFORM=linux/arm64
```

---

## Where things live

The installer asks where your data should go and creates it. Default layout:

```
~/photog/                 the install — compose files, nginx.conf, .env
~/photog-data/
  warehouse/              originals and thumbnails — THE thing to back up
  import/                 drop photos here to import them
  models/                 AI model files (and the classifier download cache)
  db/                     the database, out of reach of `down -v`
```

Answer the installer with `/mnt/photos` and all four land there instead. Config
and data stay separate on purpose: you can delete and reinstall `~/photog`
without touching photos.

Only `photog-cache` — upload staging and downloaded models, all rebuildable —
remains a Docker named volume.

**Back up `~/photog/.env`.** It holds your credentials, and losing
`POSTGRES_PASSWORD` locks you out of your own database.

Setting the paths by hand instead? Every directory except the database must be
owned by **uid 1000** — the container runs as that user and cannot write a
directory it does not own:

```bash
sudo mkdir -p /mnt/photos/{warehouse,import,models}
sudo chown -R 1000:1000 /mnt/photos
```

Getting that wrong is quiet: thumbnails never appear, or the import folder shows
up empty. Nothing fails at startup. The database directory is the exception —
create it and leave its ownership alone, because the Postgres image manages that
itself.

---

## Everyday commands

```bash
cd ~/photog

docker compose logs -f photog          # what it is doing
docker compose ps                      # what is running
docker compose restart photog          # restart just the app
docker compose down                    # stop; your data survives
docker compose pull && docker compose up -d    # upgrade
```

With `COMPOSE_FILE` set in `.env`, none of these need `-f` flags.

`docker compose down -v` deletes the named volumes. With the installer's
defaults your photos and database are on your own filesystem and survive it, but
do not make a habit of it.

---

## Documentation

- **[docs/configuration.md](docs/configuration.md)** — every environment
  variable, what it does, and what breaks when it is wrong
- **[docs/hailo.md](docs/hailo.md)** — Hailo-8 and Hailo-10H setup, and why this
  is the hardest part of the stack
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — organised by symptom
- **[docs/upgrading.md](docs/upgrading.md)** — upgrades, backups, restores

---

## Known limitations

Listed because you will hit them, not as an apology.

- **No email.** The mailer is not wired up, so password reset and self-service
  registration do not work. The admin account is created from `.env` on first
  boot; that is the only way in.
- **One library, not one per user.** There is no per-user ownership of photos,
  albums or tags. A second account is a second key to the same library.
- **No HTTPS.** The proxy serves plain HTTP. Put Photog on a network you trust,
  or terminate TLS in front of it — see
  [docs/configuration.md](docs/configuration.md).
- **No authentication on `/media`.** Images are served before the router runs,
  so no session check applies. Anyone who can reach the server and guess a path
  can fetch an image.
- **The upload endpoint has no size limit of its own.** It is authenticated by a
  client token, but a request body is read whole into memory with no ceiling.
  The 1 GB cap in `nginx.conf` is the only thing bounding it — don't remove it,
  and don't expose the app port directly.
- **Import fails noisily on a bad path.** Typing a directory that does not exist
  into the import form crashes the page instead of reporting the error, after
  creating an empty import record.
- **Descriptions in software are slow.** `moondream` runs a 0.5B model on the
  CPU. It works; it is not quick.
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

Photog is free to run for personal, non-commercial use. The image is closed
source and may not be redistributed or reverse-engineered. See
[LICENSE](LICENSE).

The compose files, scripts and documentation in *this repository* are provided
so you can run and adapt the software on your own machines; the licence covers
the image, not your `.env`.
