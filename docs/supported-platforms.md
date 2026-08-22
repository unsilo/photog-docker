# Supported hardware

Three tested configurations. **The accelerator decides what PhoTog can do; the
storage decides how fast it does it.** Those two axes explain every difference
below, and they are worth understanding before choosing a build:

- **Descriptions (AI captions) require a Hailo-10H.** The Hailo-8 and 8L are
  CNN-only parts — this is an architectural limit, not a speed one. No amount of
  waiting produces a caption on a Hailo-8.
- **Everything else tracks storage.** Ingest, thumbnailing and analysis are
  disk-bound, and classification is dominated by image load rather than
  inference. NVMe on the PCIe bus beats a USB bridge on every one of them.

## Capability matrix

| | Platform 1 | Platform 2 | Platform 3 |
|---|---|---|---|
| Import & organise | ✅ | ✅ | ✅ |
| Object & scene tags | ✅ accelerated | ✅ accelerated | ⚠️ CPU, ~10 s/photo |
| AI descriptions | ✅ ~13 s/photo | ❌ not available | ❌ impractical |
| Accelerator | Hailo-10H | Hailo-8 | none |

---

## Platform 1 — Raspberry Pi 5 8GB + AI HAT+ 2

![Platform 1](images/platform-1-ai-hat-2.jpg)
<!-- TODO photo: assembled unit, active cooler and AI HAT+ 2 visible, USB NVMe
     adapter in frame. -->

**The only configuration that supports AI descriptions.** The AI HAT+ 2 carries a
Hailo-10H, which runs the Qwen2-VL captioning model.

| | |
|---|---|
| Board | Raspberry Pi 5, 8GB |
| Accelerator | Raspberry Pi AI HAT+ 2 (Hailo-10H) |
| Storage | USB 3 NVMe adapter |
| Cooling | Active cooler + the heatsink included with the HAT |
| Software | HailoRT 5.3.0 |

**Cooling is sufficient as shipped.** The active cooler and the HAT's own
heatsink hold the accelerator in range through sustained captioning — this is a
real advantage of the HAT over a bare M.2 card, which has no heatspreader at all.

**Choose this if** you want AI descriptions. It is the only build that has them.

**Trade-off:** storage runs over a USB bridge, so ingest and thumbnailing are
slower than a PCIe-attached drive. For a one-time library import that is a
fixed cost paid once; for day-to-day use it is barely visible.

---

## Platform 2 — Raspberry Pi 5 16GB in a Pironman 5 Max + Hailo-8

![Platform 2](images/platform-2-pironman-hailo8.jpg)
<!-- TODO photo: Pironman 5 Max with the side panel off, both M.2 cards visible
     on the splitter. -->

| | |
|---|---|
| Board | Raspberry Pi 5, 16GB |
| Case | Pironman 5 Max |
| Accelerator | Hailo-8 M.2 |
| Storage | NVMe M.2, sharing the PCIe bus with the accelerator |
| Software | HailoRT 4.x (the Hailo-8 line) |

**Fast at everything it does — it just doesn't do captions.** Tagging is
accelerated and the NVMe sits on the PCIe bus rather than behind a USB bridge, so
imports, thumbnails and browsing are the quickest of the three.

**Note on the shared bus:** the Hailo-8 and the NVMe drive share the Pi 5's
single PCIe lane through the case's splitter. This is a well-tested arrangement
for a Hailo-8, whose power draw is modest and whose inference runs in short
bursts. It is **not** a topology that suits a Hailo-10H — see *Unsupported* below.

**Choose this if** you want the fastest library management and don't need
descriptions.

---

## Platform 3 — Raspberry Pi 4 + USB 3 drive

![Platform 3](images/platform-3-pi4-usb.jpg)
<!-- TODO photo: Pi 4 with the USB 3 drive attached. -->

| | |
|---|---|
| Board | Raspberry Pi 4 Model B, 8GB |
| Accelerator | none — all inference on CPU |
| Storage | USB 3 attached drive |

**The entry-level build.** Everything works, but all AI runs on the CPU:
classification takes about ten seconds per photo instead of a fraction of a
second, and descriptions take one to two minutes each — practical for a handful
of photos, not for a library.

**Choose this if** you already own the hardware and want to try PhoTog before
committing to an accelerator. Import, organise, browse and search all work
normally; treat the AI features as optional extras rather than everyday tools.

---

## Measured performance

Milliseconds per photo, lower is better. Ranges are low–high as measured.

| stage | Pi 4 | Pi 5 + Hailo-8 | Pi 5 + AI HAT+ 2 |
|---|---|---|---|
| Ingest | 40–60 | 60 | 30 |
| Thumbnail | 2250 | 1200 | 700 |
| Analyze | 8000 | 350 | 400 |
| Classify | 9000–14000 | 200–300 | 250–350 |
| Describe | 80000–130000 | 44000 (CPU) | 13000 |

Two caveats on reading this table:

- **The Hailo-8 column was measured on a Pi 5 8GB with non-PCIe storage**, not on
  a Pironman with NVMe on the bus. Every storage-bound row — ingest, thumbnail,
  analyze — should be *faster* than shown on Platform 2. Re-measure before
  publishing these as Platform 2's numbers.
- **13 s per description is the sustained figure**, not a best case. Captioning
  holds the accelerator at ~90% utilisation, and a hot accelerator slows down; the
  13 s figure is what a properly cooled unit sustains indefinitely.

---

## Unsupported configurations

### Bare Hailo-10H M.2 card on a passive PCIe splitter

**Not supported.** A Hailo-10H M.2 module sharing a passive splitter with an NVMe
drive fails under load — the accelerator stops responding mid-workload and
requires a full power cycle to recover.

Two distinct faults were identified, one with a workaround and one without:

**Fault 1 — PCIe power-state transitions.** The driver's automatic D0→D3
transitions during idle gaps could leave the card unrecoverable. *Workaround:*

    # /etc/modprobe.d/hailo.conf
    options hailo1x_pci no_power_mode=1

This one is genuinely fixed — 68 consecutive captions ran cleanly with it in
place, against a previous best of 16.

**Fault 2 — power delivery under concurrent load.** When an import runs at the
same time as inference, the accelerator dies instantly. The Pi's 5 V input sags
below 5 V without ever tripping the Pi's own under-voltage detection, which
suggests the 3.3 V rail regulated on the splitter is the one running out of
headroom. **No software workaround.** This is why the configuration is
unsupported.

**If you want to make this work anyway**, in order of likely effect:

1. **Use an externally powered splitter or M.2 HAT.** A board with its own power
   input takes the accelerator off the Pi's rail entirely. This is the fix most
   likely to actually solve it.
2. **Use the official 27 W Raspberry Pi supply.** Necessary but, on the evidence
   here, not sufficient on its own.
3. **Set `no_power_mode=1`** as above — addresses the separate fault and is worth
   doing regardless.
4. **Don't run imports and inference concurrently.** Queue newly imported photos
   and process them after the import completes.
5. **Fit a heatsink and airflow.** A bare M.2 module reached 93.6 °C with no
   cooling and a 74.5 °C idle floor. This isn't what kills it, but it does cost
   real throughput — sustained captioning slowed from 13 s to 21 s per photo.

Full technical detail, including the diagnostic path and what each symptom
actually meant: [[hailo-10h-m2-bringup]].

### Other unsupported combinations

- **Descriptions on a Hailo-8 or 8L.** Architectural, not a performance
  limitation. Those parts cannot run the captioning model at all.
- **HailoRT below 5.3.0 with any Hailo-10H.** No VLM models are published below
  5.3.0, and newer board revisions need firmware that only 5.3.0 carries. The
  Raspberry Pi archive caps its Hailo-10H packages at 5.1.1, so these must come
  from Hailo directly.
- **Mixed HailoRT versions.** Driver, firmware, `libhailort` and the Python
  bindings must all match exactly. Mismatches surface as confusing
  application-level errors rather than as version complaints.

---

## Before publishing

- [ ] **Confirm Platform 3's board.** Written as a Pi 4 Model B 8GB — the Pi 4
      has no 16GB variant. If a Pi 5 16GB with a USB3 drive was meant, this
      section needs rewriting, and its performance numbers would be much better
      than the Pi 4 column shows.
- [ ] **Re-measure Platform 2** on the actual Pironman build with NVMe on the bus.
- [ ] **Confirm the 44 s Hailo-8 description figure.** Descriptions aren't
      supported on that platform, so this is presumably a CPU fallback path —
      worth verifying before it appears in public documentation at all.
- [ ] **Validate Platform 2 under a full archive import** with tagging enabled.
      The concurrent ingest-plus-inference failure is the one scenario not yet
      exercised on that build.
- [ ] Add the three photos.
