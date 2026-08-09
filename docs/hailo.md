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

Set `PHOTOG_MODELS_PATH=/home/<you>/photog/models` in `.env` and put the files
there. Get builds for the **right device** and a HailoRT version matching yours
— `hailo8/` and `hailo10h/` are different compilations of the same network and
are not interchangeable:

```
https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v<version>/<arch>/<model>.hef
```

Filenames must match what the classifier rows ask for:

| Classifier | Filename |
|---|---|
| ResNet-50 scene classification | `resnet_v1_50.hef` |
| YOLOv11m detection | `yolov11m.hef` |
| YOLOv8m detection | `yolov8m.hef` |

A HEF's architecture is checkable; its build version is not, at least not by
`hailortcli`:

```bash
hailortcli parse-hef resnet_v1_50.hef          # architecture
head -c 200000 resnet_v1_50.hef | strings | grep sdk-version    # build version
```

A HEF of the wrong architecture or the wrong SDK version **exists**, passes the
startup check, and fails later. Worth checking both before blaming anything
else.

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

## Captioning (Hailo-10H only)

Image captioning needs a Hailo-10H, HailoRT 5.3.0 or newer, and a VLM HEF of
about 3 GB. It is not available on a Hailo-8 — and on a Hailo-8 the VLM worker
still opens a device on its way to failing, where a lingering one locks the
vision worker out.

Leave the captioning classifier disabled unless you have a Hailo-10H.

---

## Running on bare metal instead

If the container path does not work for you, PhoTog also runs directly on the
host — that is how it is developed, and it is the configuration the accelerator
has actually been verified in. The image is what is published today; a bare
metal distribution is not. If you need Hailo acceleration in 0.1.0 badly enough
to want that, open an issue.
