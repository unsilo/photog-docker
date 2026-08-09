# Hailo acceleration

> **Experimental in 0.1.0.** The bare-metal path is verified — object detection
> and scene classification have been checked against known-answer images on both
> a Hailo-8 and a Hailo-10H. **The containerised path in this document has not
> been.** If you want a working accelerator today rather than a working
> experiment, this is not yet the way to get one.

PhoTog can use a Hailo M.2 accelerator for object detection (YOLO), scene
classification (ResNet-50) and, on a Hailo-10H, image captioning. Everything
else works without one, and every classifier ships disabled.

Get PhoTog running on the CPU first. An accelerator adds classification to a
working install; it is not part of getting one.

---

## The one thing to understand first

Four components have to be the **same version**, and they come from four
different places:

```
host kernel driver   hailo_pci (4.x) / hailo1x_pci (5.x)   apt
host firmware        /lib/firmware/hailo/                  apt (hailofw)
libhailort.so        the C++ runtime                       apt
hailo_platform       the python bindings                   apt, or a wheel
```

A mismatch between any two produces a different error that points at a third.
This is the single largest source of trouble in the whole stack, and it is not
specific to Docker — people hit it on bare metal constantly.

**Hailo-8 and Hailo-10H are not a version ladder. They are two products.**

| | Hailo-8 / 8L (AI HAT+) | Hailo-10H (AI HAT+ 2) |
|---|---|---|
| HailoRT line | 4.x | 5.x |
| metapackage | `hailo-all` | `hailo-h10-all` |
| kernel module | `hailo_pci` | `hailo1x_pci` |
| python bindings | `python3-hailort` | `python3-h10-hailort`, or Hailo's wheel for 5.3.0+ |
| inference API | vstreams | `InferModel` |
| HEF files | `hailo8/` builds | `hailo10h/` builds |
| captioning (VLM) | not supported | needs HailoRT 5.3.0+ |

Installing the 5.x stack on a Hailo-8 breaks it. The Raspberry Pi archive
carries both simultaneously, so the wrong one is always one `apt install` away —
`python3-hailort`'s candidate is 4.23 even on a 5.x box.

---

## Why the image has no bindings, and what this overlay does instead

`hailo_platform` is not on PyPI. It arrives from Hailo's apt packages, and the
version has to match the driver on *your* host. Baking one version into a
published image would be correct for whoever built it and wrong for everyone
else — which is exactly the failure that fills the Frigate forums.

So `docker-compose.hailo.yml` **borrows the host's copy**: it mounts the host's
`hailo_platform` package and the matching `libhailort.so` into the container,
along with `/dev/hailo0` and your HEF files.

**What that buys:** driver, firmware, library and bindings cannot drift apart,
because there is only one set of them and it is the host's. The version problem
above disappears for the container.

**What it costs:** a Python ABI requirement. The bindings are a compiled
extension built for one CPython minor version, and this runs them under the
container's interpreter.

| Host | Python | Works with the 0.1.0 image? |
|---|---|---|
| Raspberry Pi OS **Trixie** | 3.13 | **yes** — matches the image |
| Raspberry Pi OS **Bookworm** | 3.11 | **no** — import fails |
| Debian 13 / Ubuntu 25.04+ | 3.13 | probably |

`scripts/hailo-detect.sh` checks this for you.

If you are on Bookworm, the options today are: upgrade the host to Trixie
(which also moves you onto the current Hailo packages), or run PhoTog on bare
metal instead of in Docker. A future release will publish image variants with
matching bindings baked in and tagged by HailoRT version — `:0.2.0-hailort4.20`
and so on — which removes this constraint. It is not in 0.1.0.

---

## Setup

### 1. Host packages

Nothing in a container can install a kernel driver.

**Hailo-8 / AI HAT+:**

```bash
sudo apt update
sudo apt install hailo-all
sudo reboot
```

**Hailo-10H / AI HAT+ 2:**

```bash
sudo apt update
sudo apt install hailo-h10-all
sudo reboot
```

Then confirm, in this order — each step is a prerequisite of the next, and
checking them out of order is how people end up debugging the wrong layer:

```bash
lspci | grep -i hailo                  # the card is seen at all
lsmod | grep -i hailo                  # the module is loaded
dmesg | grep -i hailo                  # what the driver said about it
ls -l /dev/hailo0                      # the device node exists
hailortcli fw-control identify         # driver + firmware + libhailort agree
```

`fw-control identify` is the single best check: it exercises the whole host
stack and prints the architecture, so it tells you which chip you have as well
as whether it works.

On a Pi 5 the PCIe slot may also need enabling in `/boot/firmware/config.txt`.

If `/dev/hailo0` is missing after all that, and `dmesg` mentions firmware, the
fix is usually:

```bash
sudo apt install --reinstall hailofw
```

That has been the entire fix twice.

### 2. Detect

From your PhoTog directory:

```bash
./scripts/hailo-detect.sh
```

It reports on the device, the bindings, the library and the Python version
match, and prints the `.env` lines to paste. `--append` writes them into `.env`
for you.

```
HAILO_GID=993
HAILO_PYTHON_PACKAGE=/usr/lib/python3/dist-packages/hailo_platform
HAILORT_LIB=/usr/lib/aarch64-linux-gnu/libhailort.so.4.20.0
HAILORT_SONAME=libhailort.so.4.20.0
```

`HAILO_GID` is the group that owns `/dev/hailo0`. The container runs as uid 1000
with no supplementary groups, so without it every `open()` on the device is
`EACCES` — which looks exactly like a driver mismatch and will send you chasing
HailoRT versions for an hour.

### 3. Models

HEF files are not in the image. They are large, and Hailo's Dataflow Compiler
and model-zoo terms are a licensing question of their own.

```bash
mkdir -p ~/photog/models
```

Set `PHOTOG_MODELS_PATH=/home/<you>/photog/models` in `.env`, then:

```bash
./scripts/download-models.sh
```

It detects your architecture from the device and your SDK version from the
installed runtime, downloads to `PHOTOG_MODELS_PATH`, **verifies the SDK version
recorded in the downloaded bytes before installing the file**, and normalises
the filename. `--dry-run` shows what it would fetch.

That verification is the point. A HEF of the wrong architecture or the wrong SDK
version **exists**, passes the startup check, and fails later — on the vision
path it may not fail at all, it may just be wrong. And upstream publishes the
VLM as `Qwen2-VL-2B-Instruct.hef` while the classifier row asks for
`qwen2-vl-2b-instruct.hef`; Linux is case-sensitive, and a case-only mismatch
resolves silently to a file that is not there.

By hand, if you prefer. Two upstreams, two path shapes:

```
vision   https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v<ver>/<arch>/<model>.hef
genai    https://dev-public.hailo.ai/v<ver>/blob/<Model>.hef
```

Filenames on disk must match what the classifier rows ask for:

| Classifier | Filename on disk |
|---|---|
| ResNet-50 scene classification | `resnet_v1_50.hef` |
| YOLOv11m detection | `yolov11m.hef` |
| YOLOv8m detection | `yolov8m.hef` |
| Qwen2-VL captioning | `qwen2-vl-2b-instruct.hef` |

`hailortcli parse-hef` reports a HEF's architecture. It does **not** report its
build version — for that:

```bash
head -c 200000 resnet_v1_50.hef | strings | grep sdk-version
```

### 4. Start with the overlay

```bash
cd ~/photog
docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d
```

You need both `-f` flags every time, including for `logs`, `pull` and `down`. To
avoid typing them, set it once per shell:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml
```

or add that line to `~/.bashrc`.

Check the bindings actually loaded:

```bash
docker compose exec photog /usr/bin/python3 -c \
  "import hailo_platform; print(hailo_platform.__version__)"
```

If that prints a version, the hard part is done.

### 5. Enable a classifier

Open `/classifier` in the UI and turn one on.

**Nothing crashes when this fails.** The worker writes the reason to that row's
`load_error` column and the app carries on — which is the intended design, and
also means silence is not success. If a classifier does not come up, read
`load_error` first. It is the most specific error message in the system.

---

## When it does not work

Read `load_error` on the classifier row first. Then, in order:

### `ModuleNotFoundError: No module named 'hailo_platform'`

The mount did not land, or `PYTHONPATH` is not set. Check:

```bash
docker compose exec photog ls /opt/hailo/python/hailo_platform
docker compose exec photog printenv PYTHONPATH
```

An empty directory means `HAILO_PYTHON_PACKAGE` pointed somewhere that does not
exist, and Docker created a directory there on the host. Fix the path and
`docker compose up -d`.

### `ImportError: libhailort.so.<version>: cannot open shared object file`

The library is not where the bindings expect it. Check the soname matches
exactly — a `libhailort.so` symlink does not satisfy a `NEEDED` of
`libhailort.so.4.20.0`:

```bash
docker compose exec photog ls -l /opt/hailo/lib/
docker compose exec photog printenv LD_LIBRARY_PATH
```

Re-run `scripts/hailo-detect.sh`; it reads the soname out of the binding's own
ELF headers rather than guessing.

### `ImportError: undefined symbol: ...`

A C++ ABI break: bindings from one HailoRT major loading a library from another.
On the host:

```bash
hailortcli --version
python3 -c "import hailo_platform; print(hailo_platform.__version__)"
```

If those disagree, fix the host first — this is not a container problem. The
usual cause is `python3-hailort` (4.23) having won over `python3-h10-hailort` on
a 5.x box, or a hand-installed deb layered over an apt one.

### `ImportError` mentioning the interpreter or a compiled extension

Probably the Python minor version mismatch. Compare:

```bash
/usr/bin/python3 -V
docker compose exec photog /usr/bin/python3 -V
```

See "Why the image has no bindings" above.

### `HAILO_INVALID_DRIVER_VERSION` (74)

Userspace and the kernel module disagree. On the host:

```bash
hailortcli --version
modinfo hailo_pci   | grep ^version      # Hailo-8
modinfo hailo1x_pci | grep ^version      # Hailo-10H
```

A module whose package has been removed **stays resident until you reboot**, so
`/dev/hailo0` keeps working right up until it does not. `modinfo` reporting the
new version is the proof, not the presence of a module with the right name.

### `HAILO_OUT_OF_PHYSICAL_DEVICES` (74) — read the whole line

`requested: 1, found: 0` means **no device exists**, not that the device is
busy. Go back to `ls /dev/hailo0` and `dmesg`.

A non-zero `found` means something else has it. On the host:

```bash
fuser -v /dev/hailo0
```

`fuser` reporting that the file does not exist — rather than naming a holder —
is what distinguishes the two cases.

### `Permission denied` opening the device

`HAILO_GID` is wrong or missing.

```bash
ls -l /dev/hailo0                    # crw-rw---- 1 root hailo ...
getent group hailo | cut -d: -f3     # the gid to use
```

### `HAILO_NOT_IMPLEMENTED` (7) on every photo

The wrong inference API for the chip. HailoRT 5.x still *exports* the whole 4.x
vstreams API on a Hailo-10H — the import succeeds, the model loads, and
inference fails. An exported symbol is not an implemented one.

The worker picks its API from the HailoRT major version and retries once on the
other after a `NOT_IMPLEMENTED`, so this should self-correct. If it does not,
override it:

```
PHOTOG_HAILO_API=infer_model     # Hailo-10H
PHOTOG_HAILO_API=vstreams        # Hailo-8
```

Runtime, not a rebuild. Leave it unset otherwise — a wrong value forces an API
the chip does not implement onto every photo.

### `HAILO_INVALID_OPERATION` (6) — "Failed to create VLM"

Detection and classification work; captioning fails instantly with a status code
and nothing else:

```
[HailoRT] [error] CHECK_SUCCESS failed with status=HAILO_INVALID_OPERATION(6) - Failed to create VLM
[error] VLM worker failed to boot: "6"
```

**This asymmetry is the most misleading thing in the stack.** The vision models
load through a low-level path that does not check the HEF's SDK version. The
GenAI wrapper validates it up front and rejects — naming neither the version nor
the file. So "ResNet and YOLO work, captioning doesn't" is not evidence that the
VLM model is bad.

Three causes, all producing exactly this. Check in this order, because the first
is free:

**1. The HEF was never found.** Nothing validates that the file exists before
the worker starts, so a missing model reaches HailoRT as a status code rather
than as "no such file". The log says which path was used:

```bash
docker compose logs photog | grep -iE "VLM HEF|falling back"
```

`No VLM HEF in /app_cache/models; falling back to …/priv/qwen2-vl-2b-instruct.hef`
means the mount is empty or the name is wrong — **and the `priv/` copy does not
exist in this image**, because it is 3.1 GB and deliberately excluded. The file
must be in `PHOTOG_MODELS_PATH`, named exactly `qwen2-vl-2b-instruct.hef`.
Upstream ships it as `Qwen2-VL-2B-Instruct.hef`; Linux is case-sensitive, and a
case-only mismatch is logged as a warning rather than failing.

```bash
docker compose exec photog ls -l /app_cache/models
```

**2. HailoRT is older than 5.3.0.** The likeliest cause on a freshly installed
Pi. The Raspberry Pi archive caps every `h10-` package at **5.1.1**, and **no VLM
HEF is published below 5.3.0** — so a stock `apt install hailo-h10-all` gives you
a runtime that cannot load any captioning model in existence.

```bash
hailortcli --version                                              # on the host
head -c 200000 qwen2-vl-2b-instruct.hef | strings | grep sdk-version
```

If those disagree, that is the whole answer, and there is a script for it:

```bash
./scripts/upgrade-hailort.sh --dry-run          # read what it will do first
./scripts/upgrade-hailort.sh --debs ~/hailo-5.3.0
```

See [Upgrading to HailoRT 5.3.0](#upgrading-to-hailort-530) below — it is not a
routine `apt upgrade` and there are things you give up.

**Then re-run `scripts/hailo-detect.sh` — see below.**

**3. Not a Hailo-10H.** Captioning needs one. On a Hailo-8 there is nothing to
fix.

### After changing HailoRT on the host, re-run the detection

This overlay mounts the host's library **by its exact versioned soname**, which
is what keeps the container in lockstep with the driver. The cost is that a host
upgrade invalidates your `.env`: `HAILORT_LIB` and `HAILORT_SONAME` still name
`libhailort.so.5.1.1`, which no longer exists.

Docker creates a **directory** at a missing bind-mount source, so the container
comes up with a directory where a library should be and fails at import — a
confusing error about a file that is right there.

```bash
cd ~/photog
# remove the old HAILO_GID / HAILO_PYTHON_PACKAGE / HAILORT_* lines from .env
./scripts/hailo-detect.sh --append
docker compose -f docker-compose.yml -f docker-compose.hailo.yml up -d
```

No rebuild and no re-pull — the image never contained a HailoRT version to be
wrong about. That is the whole point of borrowing the host's.

### Tags appear, but they are wrong

Take this seriously rather than as a quality issue. A scrambled class list or an
off-by-one produces confident, well-formed, entirely wrong labels — and so does
a HEF built for a different architecture. So does a caption generated with a
contaminated context.

Check the HEF's architecture and SDK version (step 3 above). Confirm the
classifier row's `model_repo` names the file you actually installed. If the
labels look shifted rather than random, suspect a 1001-class model against a
1000-class label list.

---

## Upgrading to HailoRT 5.3.0

**Only on a Hailo-10H, and only if you want captioning.** Detection and
classification already work on 5.1.1 and gain nothing from this.

`4.x is the Hailo-8 stack, 5.x is the Hailo-10H stack.` Putting a Hailo-8 on the
5.x line produces `HAILO_STREAM_NOT_ACTIVATED(72)` and `HAILO_STREAM_ABORT(63)`
mid-inference, which reads as an application bug and takes an evening to unpick.
`upgrade-hailort.sh` asks the device its architecture and refuses if it is not a
Hailo-10H. Do not talk yourself past that check.

### You supply the packages

Hailo's Developer Zone needs a login, so nothing can fetch these for you.
Download into one directory — `~/hailo-5.3.0` by default:

```
hailort_5.3.0_arm64.deb
hailort-pcie-driver_5.3.0_all.deb
hailort-5.3.0-cp313-cp313-linux_aarch64.whl
```

The wheel is not optional and **the runtime deb does not contain it**. Without
it you end up with a working accelerator no Python can talk to — and nothing for
the container mount to mount. `cp313` is for Raspberry Pi OS Trixie; match the
tag to `python3 -V` on the host.

### Run it

```bash
cd ~/photog
./scripts/upgrade-hailort.sh --dry-run
./scripts/upgrade-hailort.sh --debs ~/hailo-5.3.0
```

It stops the stack, caches your current packages so a rollback is possible,
swaps the runtime, patches and rebuilds the PCIe driver for your kernel, holds
the packages, and verifies that `hailo_platform.genai.VLM` actually imports —
which is the check that distinguishes "5.3.0 is installed" from "captioning will
work".

### What you are trading away

**apt stops managing this.** The Pi archive ships `h10-hailort`; Hailo ships
`hailort`. They cannot coexist, so the archive's packages are removed.
Afterwards apt sees `hailort` with an archive candidate of **4.23.0 — a Hailo-8
runtime — sitting below what you installed**. One stray `apt upgrade` reinstates
it. The script runs `apt-mark hold`; leave the hold alone.

**The PCIe driver may stop being DKMS-from-apt** and become a module built from
an unmerged pull request. Every kernel upgrade, you rebuild it. A kernel bump
that silently fails to rebuild looks exactly like dead hardware.

### Rolling back

```bash
./scripts/rollback-hailort.sh
```

Only works if `upgrade-hailort.sh` ran first — it is what cached the old debs.
The archive is under no obligation to keep serving a version you stopped asking
for, so a rollback that needs a remote to cooperate is not a rollback.

---

## Captioning (Hailo-10H only)

Image captioning needs a Hailo-10H, **HailoRT 5.3.0 or newer**, and a VLM HEF of
about 3 GB.

The 5.3.0 floor is the part that catches people. `apt install hailo-h10-all`
gives you **5.1.1** — the Raspberry Pi archive caps every `h10-` package there —
and no VLM HEF is published below 5.3.0. Detection and classification work fine
on 5.1.1, so the box looks healthy right up until you enable captioning and get
`HAILO_INVALID_OPERATION(6)` with no explanation. 5.3.0 comes from Hailo's own
debs, which replace the archive's packages rather than upgrading them, plus a
separate python wheel.

Captioning is not available on a Hailo-8 at all — and there, the VLM worker
still opens a device on its way to failing, where a lingering one locks the
vision worker out of it.

Leave the captioning classifier disabled unless you have a Hailo-10H on 5.3.0+.

Two behaviours worth knowing before you point it at a library:

- **It will not decline, it will invent.** A 2B model captions flat synthetic
  images — screenshots, logos, clip art, scanned documents — confidently and
  wrongly. Photographs are what it is good at.
- Captions are written to the database as fact. There is no confidence score to
  filter on.

---

## Running on bare metal instead

If the container path does not work for you, PhoTog also runs directly on the
host — that is how it is developed, and it is the configuration the accelerator
has actually been verified in. The image is what is published today; a bare
metal distribution is not. If you need Hailo acceleration in 0.1.0 badly enough
to want that, open an issue.
