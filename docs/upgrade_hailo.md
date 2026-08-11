

### 3b. Upgrade HailoRT — Hailo-10H, and only if you want descriptions

You are on **HailoRT 5.1.1**, because the Raspberry Pi archive caps every `h10-`
package there. Hailo publishes no captioning model below **5.3.0**, so `qwen2`
has nothing to load and fails with `HAILO_INVALID_OPERATION(6)` — a message that
names neither the version nor the file.

Nothing is wrong with your install. Classification is fully accelerated on 5.1.1
and gains nothing from upgrading. **If you only want tags, skip this step** — and
step 4 will tell you which side of 5.3.0 you are on if you are unsure.

For descriptions, download the runtime deb, the driver deb and the python wheel
from the Hailo Developer Zone into `~/hailo-5.3.0` — a login is required, so no
script can fetch them for you — then:

```bash
cd ~/photog
./scripts/upgrade-hailort.sh --dry-run              # read what it will do first
./scripts/upgrade-hailort.sh --debs ~/hailo-5.3.0
sudo reboot
```

This is not a routine `apt upgrade`. Hailo's debs **replace** the archive's
packages rather than upgrading them, apt stops managing the result, and the PCIe
driver becomes something you rebuild after a kernel bump.
`scripts/rollback-hailort.sh` undoes it — but only if the upgrade script ran
first, because that is what caches the old packages. Read
[Upgrading to HailoRT 5.3.0](docs/hailo.md#upgrading-to-hailort-530) before you
start.

The new driver renames the device node — `/dev/hailo0` becomes `/dev/h1x-0` —
which is why step 4 comes after this one and not before. If you upgrade later,
re-run step 4 or the container will look for a device that no longer exists.
