# Hailo acceleration


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





> **Experimental in 0.1.0.** The bare-metal path is verified — object detection
> and scene classification have been checked against known-answer images on both
> a Hailo-8 and a Hailo-10H. **The containerised path in this document has not
> been.** If you want a working accelerator today rather than a working
> experiment, this is not yet the way to get one.

Photog can use a Hailo M.2 accelerator for object detection (YOLO), scene
classification (ResNet-50) and, on a Hailo-10H, image captioning. Everything
else works without one, and every classifier ships disabled.

Get Photog running on the CPU first. An accelerator adds classification to a
working install; it is not part of getting one.

---

## The one thing to understand first

Four components have to be the **same version**, and they come from four
different places:

```
host kernel driver   hailo_pci (4.x) / hailo1x_pci (5.x)   apt
host firmware        /lib/firmware/hailo/                  apt (hailofw on 4.x)
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

| Host | Python | Works with the published image? |
|---|---|---|
| Raspberry Pi OS **Trixie** | 3.13 | **yes** — matches the image |
| Raspberry Pi OS **Bookworm** | 3.11 | **no** — import fails |
| Debian 13 / Ubuntu 25.04+ | 3.13 | probably |

`scripts/env-detect.sh` checks this for you.

If you are on Bookworm, the options today are: upgrade the host to Trixie
(which also moves you onto the current Hailo packages), or run Photog on bare
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
ls -l /dev/hailo0 /dev/h1x-0           # the device node exists (name varies)
hailortcli fw-control identify         # driver + firmware + libhailort agree
```

The node's name depends on which driver bound the card: `hailo_pci` and the
archive's `hailo1x_pci` both create `/dev/hailo0`, but HailoRT 5.3.0's `hailo1x`
creates `/dev/h1x-0`. Looking only for `/dev/hailo0` is how a working card gets
diagnosed as dead.

`fw-control identify` is the single best check: it exercises the whole host
stack and prints the architecture, so it tells you which chip you have as well
as whether it works.

On a Pi 5 the PCIe slot may also need enabling in `/boot/firmware/config.txt`.

If the device node is missing after all that, and `dmesg` mentions firmware, the
fix is usually to reinstall the package that owns the firmware — **which is not
the same package on both cards**:

```bash
dpkg -S /lib/firmware/hailo          # ask, rather than guess
sudo apt install --reinstall hailofw          # Hailo-8 / 4.x only
sudo apt install --reinstall hailo-h10-all    # Hailo-10H / 5.x
```

On a Hailo-8 that has been the entire fix twice.

`hailofw` is the archive's **Hailo-8** firmware package and it does not exist on
the 5.x line at all. `Unable to locate package hailofw` on a Hailo-10H box is
not a broken apt or a missing repository — it means you are on the 5.x stack and
are reading advice for the other card.

### 2. Detect

From your Photog directory:

```bash
./scripts/env-detect.sh
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

#### Skipping the captioner

The default fetches everything, and the captioning model is **~3 GB** against
tens of MB for the other two. On a slow connection, a metered one, or a Hailo-8
that cannot use it at all, that download is pure waste:

```bash
./scripts/download-models.sh --vision-only
```

`--no-vlm` is the same flag. To name models individually — repeatable, or
comma-separated:

```bash
./scripts/download-models.sh --skip qwen2-vl
./scripts/download-models.sh --skip qwen2-vl,yolov11m
```

`--only <name>` is the inverse: fetch that one and nothing else, which is what
you want after a runtime upgrade when the vision models are already in place.

To see what there is without downloading anything — this needs no accelerator
and no network:

```bash
./scripts/download-models.sh --list
```

```
resnet_v1_50   ~25 MB   default   scene and subject tags
yolov11m       ~40 MB   default   object detection
yolov8m        ~50 MB   opt-in    object detection, faster than yolov11m on a Hailo-8
qwen2-vl       ~3 GB    default   image descriptions (Hailo-10H only)  [needs SDK 5.3.0+]
```

**opt-in** models are alternatives to something already in the default set, so
they are fetched only when named — the app runs one detector at a time, and
pulling both is wasted disk:

```bash
./scripts/download-models.sh --include yolov8m     # defaults plus this one
./scripts/download-models.sh --only yolov8m        # only this one
```

#### Which detector

`yolov8m` and `yolov11m` are both supported, and which is the better trade
**depends on the card** — the answer is not the same on both:

| | Hailo-8 | Hailo-10H |
|---|---|---|
| yolov8m | 49.2 mAP · 66.9 FPS | 49.2 mAP · 78.5 FPS |
| yolov11m | 49.9 mAP · 50.2 FPS | 50.1 mAP · 70.6 FPS |
| cost of v11m | **+0.7 mAP for −25% FPS** | **+0.9 mAP for −10% FPS** |

On a **Hailo-10H**, `yolov11m` is close to free and is the default for that
reason. On a **Hailo-8**, and more so a **Hailo-8L**, a quarter of the
detector's throughput for two-thirds of a point of mAP is a much weaker deal —
`--include yolov8m` and switch the classifier if detection turns out to be your
bottleneck.

Whether it *is* the bottleneck is worth measuring rather than assuming. Import
is usually I/O bound — JPEG decode, thumbnailing and Postgres dominate on a Pi —
so the FPS column often does not reach the wall clock at all. Watch
`hailortcli monitor` during an import before optimising it.

Larger variants exist upstream (`yolov11l` at 52.3 mAP, `yolov11x` at 53.1) but
are not in the catalogue and have no classifier row in the app. The curve goes
flat there anyway: `l` buys +2.4 mAP over `m` for −24% FPS, while `x` buys only
+0.8 more for another −52%.

A misspelled name is an error, not a silent no-op — `--skip qwen2` (the real
name is `qwen2-vl`) stops the script rather than downloading the 3 GB file you
typed the flag to avoid.

**What omitting a model costs you.** Nothing crashes. The classifier simply does
not start, and its `load_error` at `/classifier` says the HEF is missing — which
is indistinguishable from a broken install if you have forgotten you skipped it.
The script says so on the way out for that reason. Fetch it whenever you like;
re-running is cheap, because a model already present at the right SDK version is
left alone:

```bash
./scripts/download-models.sh
```

Note `--vision-only` keys on where a model comes from, not on its name, so it
covers any captioning model added later without anyone having to remember.

You do not need this flag on a **Hailo-8**: `qwen2-vl` requires SDK 5.3.0, a
Hailo-8 runs the 4.x line, and the script already refuses it as unsatisfiable
and tells you Moondream on the CPU is the route to descriptions. Passing
`--vision-only` there is harmless and slightly quieter.

That verification is the point. A HEF of the wrong architecture or the wrong SDK
version **exists**, passes the startup check, and fails later — on the vision
path it may not fail at all, it may just be wrong. And upstream publishes the
VLM as `Qwen2-VL-2B-Instruct.hef` while the classifier row asks for
`qwen2-vl-2b-instruct.hef`; Linux is case-sensitive, and a case-only mismatch
resolves silently to a file that is not there.

#### Two version numbers, and they are not the same number

This trips everyone once, so it is worth thirty seconds.

| | Hailo-8 / 8L | Hailo-10H / 15H |
|---|---|---|
| Model Zoo | **v2.x** (currently 2.19.0) | v5.x |
| Dataflow Compiler | v3.x | v5.x |
| HailoRT | 4.x | 5.x |

**On the Hailo-10H line all three numbers are the same.** On the Hailo-8 line
they are three unrelated sequences. The model zoo's `master` branch is
Hailo-10/15 only; Hailo-8 and 8L live on its `v2.x` branch.

The vision download URL is versioned by the **model zoo**, not by your runtime:

```
vision   https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v<zoo>/<arch>/<model>.hef
genai    https://dev-public.hailo.ai/v<sdk>/blob/<Model>.hef
```

So a Hailo-8 running HailoRT 4.20.0 wants
`.../Compiled/**v2.19.0**/hailo8l/yolov11m.hef` — not `v4.20.0`, which has never
existed and answers with a 403 rather than anything that mentions versions.

`download-models.sh` handles this: `--version` is the runtime, `--zoo-version`
is the model zoo, and on a Hailo-8 it defaults to the head of the 2.x branch.
Override it when that branch moves:

```bash
./scripts/download-models.sh --zoo-version 2.19.0
```

There is no formula converting one to the other. Known fixed points: zoo v2.14
is HailoRT 4.20.0, v2.15 is 4.21.0, v2.16 is 4.22.0. After that the
correspondence stops being published anywhere machine-readable, which is why
this is a flag and not a calculation.

One consequence worth knowing: on the Hailo-8 line the script **reports** the
`sdk-version` inside a downloaded HEF but does not enforce it. That header
records the *compiler* version (3.x), and comparing it against a HailoRT 4.x
number is arithmetic across two unrelated scales — it would reject correct files
and pass wrong ones with equal confidence. On the Hailo-10H line, where the
numbers genuinely match, the check is exact and a mismatch is refused.

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

Rather than passing both flags to every `logs`, `pull` and `down`, put it in
`.env` — Compose reads `COMPOSE_FILE` from there and applies it to every
command:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.hailo.yml
```

Then plain `docker compose up -d` and `docker compose logs -f photog` do the
right thing.

`env-detect.sh --append` sets this for you: the hailo overlay if it found a
usable card of either generation, the base file alone if it did not. It replaces
any existing `COMPOSE_FILE` line rather than adding a second one, so re-running
it after a hardware change is safe.

It used to add a third overlay on a Hailo-8, for captioning. It does not any
more — see below.

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

Re-run `scripts/env-detect.sh`; it reads the soname out of the binding's own
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

**Then re-run `scripts/env-detect.sh` — see below.**

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
./scripts/env-detect.sh --append
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

## Captioning on a Hailo-8 — use Moondream

`qwen2` needs a Hailo-10H. There is no version of HailoRT, no HEF and no
configuration that makes it run on a Hailo-8: the GenAI stack and the models it
loads are Hailo-10H builds. Do not run `upgrade-hailort.sh` hoping to get there
— it refuses on a Hailo-8, and rightly.

**Moondream is the answer on that hardware.** It is a 0.5B int8 model running on
the Pi's CPU, entirely independent of the accelerator, so your Hailo-8 keeps
doing detection and classification while the CPU does captions.

**Nothing to change in compose.** Enable **moondream** at `/classifier` — not
qwen2 — and that is the whole procedure. Up to 0.1.4 this needed a
`docker-compose.python.yml` overlay and a larger `-python` image, because
Moondream's ~350 MB Python environment existed only in that image. It is now
built on demand: the default image carries the environment's `pyproject.toml`
and `uv.lock` plus `uv`, and the first enable builds it.

That first enable takes a while and needs the internet. The classifier row shows
each stage while it works:

```
Preparing the Python environment (step 1 of 3) — fetching the interpreter…
Preparing the Python environment (step 2 of 3) — installing packages.
Downloading and loading the model (step 3 of 3).
```

and the log narrates the same thing:

```
MoondreamServer: starting Python environment and loading model
PythonEnv: uv sync --no-dev
MoondreamServer: model ready
```

Later starts skip all of it — the environment is on disk and the weights are in
`/app_cache/huggingface`, which is a volume, so neither survives being asked for
twice.

### If Moondream fails with `:enoent` and `{:spawn_executable, nil}`

Snex looked for its interpreter at

```
/app/snex/projects/Elixir.PhoTog.Classifications.MoondreamInterpreter/venv/bin/python
```

found nothing, and passed `nil` to `open_port`. On 0.1.4 that meant you were on
the default image rather than the `-python` one, and the fix was to change
images. From 0.1.5 the environment builds itself, so this error means the build
did not happen or could not — and the row's `load_error` says which. Check:

```bash
# is the scaffolding there? pyproject.toml and uv.lock, no venv yet is normal
docker compose exec photog ls -la /app/snex/projects/*/

# is uv there?
docker compose exec photog uv --version
```

Most likely causes, in order: no route to PyPI or python-build-standalone when
the box was ticked; a container with no writable space left; or an image built
before 0.1.5, where nothing can rebuild the environment because the
`pyproject.toml` was deleted along with the venv.

`PHOTOG_PYTHON` is unrelated — that points the *Hailo* workers at an
interpreter. Moondream manages its own.

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

### `Failed to install PCIe driver to the DKMS tree`

```
Failed to install PCIe driver to the DKMS tree. Trying to install PCIe
driver without DKMS
Failed. Exited with status 2. See /var/log/hailort-pcie-driver.deb.log
dpkg: error processing package hailort-pcie-driver (--configure):
```

Almost always **`dkms` or the kernel headers were not installed when the driver
package's postinst ran**. Any package that builds a kernel module builds it at
`dpkg --configure` time, so the toolchain has to be there first — this applies
to `apt install hailo-h10-all` as much as to the debs above.

Fix the ordering and let the postinst finish:

```bash
sudo apt-get install -y dkms build-essential "linux-headers-$(uname -r)"
sudo dpkg --configure hailort-pcie-driver
```

Check that headers actually landed, because the package name varies and apt
reports success either way:

```bash
ls -d /lib/modules/$(uname -r)/build
```

A missing directory there is the real fault. `linux-headers-$(uname -r)` is
usually right on Raspberry Pi OS; if it does not exist, try
`raspberrypi-kernel-headers`. If you upgraded the kernel recently, reboot first
— the headers must match the **running** kernel, not the newest installed one.

`upgrade-hailort.sh` installs the toolchain in phase 0a, before any package is
touched, so it does not produce this. Versions of the script before 2026-08-11
installed it in phase 4 — after the postinst had already failed — and the
resulting message is indistinguishable from the kernel-incompatibility failure
described below. If you are on an older copy, take the current one.

If the toolchain was already in place, this is the real driver-build failure
instead: `del_timer_sync` was removed in kernels ≥ 6.15 and the shipped source
still calls it. The script patches that automatically; by hand, see
[The device node is gone after the upgrade](#the-device-node-is-gone-after-the-upgrade)
and the build notes in `scripts/upgrade-hailort.sh`.

### What you are trading away

**apt stops managing this.** The Pi archive ships `h10-hailort`; Hailo ships
`hailort`. They cannot coexist, so the archive's packages are removed.
Afterwards apt sees `hailort` with an archive candidate of **4.23.0 — a Hailo-8
runtime — sitting below what you installed**. One stray `apt upgrade` reinstates
it. The script runs `apt-mark hold`; leave the hold alone.

**The PCIe driver may stop being DKMS-from-apt** and become a module built from
an unmerged pull request. Every kernel upgrade, you rebuild it. A kernel bump
that silently fails to rebuild looks exactly like dead hardware.

### `error gathering device information ... no such file or directory`

```
Error response from daemon: error gathering device information while adding
custom device "/dev/hailo0": no such file or directory
```

**The char device is not always `/dev/hailo0`.** Each driver generation names it
differently, and the overlay bind-mounts it by path:

| Module | HailoRT | From | Node |
|---|---|---|---|
| `hailo_pci` | 4.x | `hailo-all` (Hailo-8) | `/dev/hailo0` |
| `hailo1x_pci` | 5.1.1 | RPi archive `hailo-h10-all` | `/dev/hailo0` |
| `hailo1x` | 5.3.0 | Hailo's own debs | **`/dev/h1x-0`** |

Confirmed on a Pi 5 + Hailo-10H: upgrading 5.1.1 → 5.3.0 moves the node, and the
old path simply stops existing. `dmesg` names it —
`hailo1x 0001:01:00.0: Device created at /dev/h1x-0`.

Find it and record it:

```bash
ls -l /dev/hailo* /dev/h1x-* 2>/dev/null
sudo dmesg | grep -i 'device created'
```

```
HAILO_DEVICE=/dev/h1x-0
```

`env-detect.sh` searches all the known names and writes this for you. The
overlay defaults to `/dev/hailo0` when it is unset, which covers 4.x and 5.1.1.

### The device node is gone after the upgrade

```
Error response from daemon: error gathering device information while adding
custom device "/dev/hailo0": no such file or directory
```

That Docker error is a consequence, not the problem — Compose cannot attach a
device that does not exist.

**Reboot first.** Swapping a PCIe driver under a live kernel does not re-run the
bus probe. The old module stayed resident through the whole upgrade — which is
why the device kept working right up until it was unloaded — and the new one
often does not bind until a cold start. This is the single most common outcome
and it is not a failed upgrade.

```bash
sudo reboot
# then
ls -l /dev/hailo0
sudo hailortcli fw-control identify
```

Your photos are not down meanwhile. The base stack needs no accelerator:

```bash
cd ~/photog && docker compose up -d      # no -f overlay
```

Still missing after a reboot? `dmesg` answers it:

```bash
lspci -nn | grep -i hailo          # is the card on the bus at all
lsmod | grep -i hailo              # is a module loaded, and which
sudo dmesg | grep -i hailo | tail -30
modinfo hailo1x_pci | head -3 ; uname -r ; dkms status
ls -l /usr/lib/firmware/hailo/
```

| What `dmesg` says | What it means |
|---|---|
| `probe ... failed with error -2`, or anything about firmware | The firmware went with the removed packages. |
| `sysfs: cannot create duplicate filename '/class/hailo_chardev'` | A stale legacy `hailo_pci` is winning the probe. |
| nothing at all, and `lspci` shows the card | The module is not loading — check `dkms status` against `uname -r`. |
| `lspci` shows nothing | Hardware or PCIe seating. Not a software problem. |

**Firmware:** reinstall the deb that owns it. **Not** `apt install --reinstall
hailofw` — that is the Raspberry Pi archive's **Hailo-8 / 4.x** firmware
package, it is the fix from the 4.x notes, and on a 5.3.0 Hailo-10H it is the
wrong firmware. On a box that has moved to Hailo's own debs it usually is not
even installable, which is your clue.

```bash
dpkg -L hailort | grep -i firmware        # confirm which package owns it
sudo dpkg -i ~/hailo-5.3.0/hailort_5.3.0_arm64.deb
```

`dpkg -S /lib/firmware/...` will tell you "no path found" — it does not resolve
the usrmerge `/lib` → `/usr/lib` symlink. Query `/usr/lib`. And do not follow
that with `rm`; a live library has been deleted that way here.

**Stale module:**

```bash
sudo rm -f /lib/modules/$(uname -r)/{updates/dkms,extra,kernel/drivers/misc}/hailo_pci.ko*
sudo depmod -a && sudo reboot
```

**Built for the wrong kernel** — `dkms status` naming a kernel that is not
`uname -r`:

```bash
cd ~/hailort-drivers/linux/pcie && sudo make install_dkms
```

**Do not roll back for a missing device node.** Rolling back re-does the whole
upgrade in reverse to fix something a reboot usually fixes.

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

If the container path does not work for you, Photog also runs directly on the
host — that is how it is developed, and it is the configuration the accelerator
has actually been verified in. The image is what is published today; a bare
metal distribution is not. If you need Hailo acceleration in 0.1.0 badly enough
to want that, open an issue.
