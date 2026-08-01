# Building and installing /e/OS on the Boox Palma 2 Pro

Complete reproduction: unlock, back up, build, flash, boot.

> **Read this section before anything else.**
>
> This replaces the firmware on a device that has no recovery UI you can see —
> the bootloader draws to a DSI framebuffer that does not exist on this panel, so
> **every bootloader-level prompt is invisible**. Recovery is host-driven, via
> EDL, or not at all.
>
> Unlocking the bootloader **wipes `/data`** unconditionally: the TEE re-derives
> the userdata keys on any lock-state change.
>
> The full EDL backup in step 2 is not optional. It is the only way back.
>
> This is a port in progress, not a product. Read "Current limitations" at the
> bottom before deciding to install it.

---

## 0. What you need

**A device:** Onyx Boox Palma 2 Pro (`Palma2_Pro_C` / OPC1410R). No other model.

**A host:** Linux or macOS with `adb`, `fastboot`, `python3`, and
[`edlclient`](https://github.com/bkerler/edl). `zig` if you want to build the
native tools (`brew install zig` — far smaller than the NDK).

**A build machine** for AOSP: 16+ cores, 64 GB RAM, ~400 GB free. Apple Silicon
cannot do soong's analysis pass natively (`docs/04` explains why); this project
drives a remote x86_64 builder over SSH (`docs/05`, `scripts/builder.sh`).

**Time:** a first full build is hours. Any `.mk` change afterwards forces a
~45 minute regeneration before anything compiles.

---

## 1. Unlock the bootloader

Onyx's own bootloader will not unlock. The workaround uses the Fairphone 4's
ABL, which runs because the FP4 shares the SM7225 SoC.

Full detail and rationale: **`docs/02-unlock.md`**. Summary:

1. Enter EDL: `adb reboot edl` (`adb reboot bootloader` does **not** help here).
2. Back up `abl_a`/`abl_b` before touching them.
3. Flash the FP4 ABL to the `abl` partition of the active slot.
4. **Do not wait for the on-screen confirmation** — it is rendered to a
   framebuffer this panel does not have, so the screen stays blank. Drive the
   unlock from the host instead: write `is_unlocked` and `is_unlock_critical`
   directly in `devinfo` (offsets 13 and 14) over EDL —
   `scripts/patch-devinfo-unlock.sh`.
5. Restore Onyx's ABL afterwards if you prefer; the unlock state persists.

`/data` is wiped. Expect it.

## 2. Back up the whole device — do this now

```sh
scripts/edl-backup.sh              # every partition, both slots
scripts/edl-verify-restore.sh      # prove the restore path actually works
```

Verify the backup before continuing. An unverified backup is not a backup, and
this is the only route back to a working device.

Keep it off the machine you are building on.

## 3. Extract the proprietary blobs from *your* device

This repository ships **no Onyx binaries**. They are not redistributable: the
kernel is a modified Linux for which Onyx publishes no source (a GPL-2.0
violation on their part), and the vendor libraries, waveform blob and TCON
firmware are proprietary. You must take them from the device you own.

```sh
scripts/extract-stock-firmware.sh      # pulls kernel, dtb, vendor bits from your dump
```

This populates `device/onyx/Palma2_Pro_C/prebuilt/` (kernel `Image`, `dtb/`) and
`firmware/`. Both are gitignored and must stay that way.

The build will not start without them.

## 4. Get the sources

```sh
repo init -u https://gitlab.e.foundation/e/os/releases.git -b v4.2-a15 --git-lfs
repo sync -j8
```

Then place this repository's device tree at `device/onyx/Palma2_Pro_C`, or use
the sync helper if you are driving a remote builder:

```sh
scripts/builder.sh push        # rsync -a, preserves mtimes so no needless regen
```

## 5. Apply the patches

Patches live in `patches/` and apply to the AOSP tree, **not** to this repo.
`patches/README.md` lists what each one does and why.

```sh
cd /aosp/system/core        && git apply /path/to/patches/main/0001-*.patch
cd /aosp/frameworks/native  && git apply /path/to/patches/main/0002-*.patch
```

| patch | what it does |
|---|---|
| `main/0001-…-dev-ebc.patch` | ueventd rule making `/dev/ebc` accessible |
| `main/0002-…-publish-epd-damage.patch` | SurfaceFlinger publishes its damage region for the composer shim |

Also copy the shared contract header into the AOSP tree, where the SF patch
includes it from:

```sh
cp src/epdc_damage.h \
   /aosp/frameworks/native/services/surfaceflinger/CompositionEngine/include/compositionengine/
```

Validate any device-tree XML you have edited *before* building — aapt2 reports
malformed XML as a bare "not well-formed" with no line number, and a device-tree
change costs a full regeneration to find out:

```sh
scripts/check-device-xml.py device/onyx/Palma2_Pro_C
```

## 6. Build

```sh
source build/envsetup.sh
lunch lineage_Palma2_Pro_C-bp1a-userdebug
m
```

Or remotely: `scripts/builder.sh build` (`scripts/builder.sh logs -f` to watch).

Wait for the real completion marker, not for `pgrep ninja` — there are gaps
between build phases and you will otherwise deploy a stale artifact:

```sh
grep -c "build completed successfully" /aosp/build.log
```

Build the native tools too:

```sh
zig cc -target aarch64-linux-none -fPIC -shared -nostdlib -O2 -o out/libepdcshim.so src/epdcshim.c
zig cc -target aarch64-linux-musl -static -O2 -o out/ebcrefresh src/ebcrefresh.c
```

## 7. Flash

**`fastboot flash` does not work on this device** — Onyx's fastbootd rejects it.
Everything goes through EDL.

```sh
adb reboot edl                                   # screen stays blank; normal

# logical partitions live inside `super`; resolve extents from lpdump
scripts/flash-logical-via-edl.py out/target/product/Palma2_Pro_C/system.img \
    lpdump.txt system_b --go
```

Details, including the `super` offset arithmetic and how to resize a logical
partition when an image no longer fits: **`docs/08-lp-resize.md`**,
`scripts/lp-resize-partition.py`.

Iterating on one binary later? Do not reflash a partition —
`scripts/edl-delta-flash.py` writes only changed sectors, and
`docs/16-build-flash-test.md` describes the much faster `adb push` loop that
avoids EDL entirely.

## 8. Install the display shim

The panel stays blank without this. The shim supplies the EPD update rectangles
that nothing else in an AOSP stack sets (`MANUAL.md` §2 explains why).

```sh
adb root && adb remount
adb push out/libepdcshim.so /vendor/lib64/libepdcshim.so
adb shell chmod 644 /vendor/lib64/libepdcshim.so
```

Add to `/vendor/etc/init/vendor.qti.hardware.display.composer-service.rc`, inside
the service block:

```
    setenv LD_PRELOAD /vendor/lib64/libepdcshim.so
```

And install the client-composition helper, without which the navigation bar,
status bar and IME are drawn but invisible:

```sh
adb push device-files/system/etc/init/epdc-clientcomp.rc /system/etc/init/
```

## 9. First boot

Expect several minutes. The screen may stay blank until the shim loads.

```sh
adb wait-for-device && adb root

# the display sleeps aggressively; wake it before judging anything
adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'

# known-good refresh policy
adb shell '
setprop persist.epdcshim.wf       2
setprop persist.epdcshim.upd      0
setprop persist.epdcshim.flag     0x31000
setprop persist.epdcshim.interval 120'
```

Sanity checks:

```sh
adb shell 'getprop sys.boot_completed'                                  # 1
adb shell 'dumpsys SurfaceFlinger | grep usesDeviceComposition'         # must be false
adb shell 'dmesg | grep -c waveform_clean_work_handler'                 # rises when you interact
```

If the screen is blank but `screencap` shows real content, the framework is fine
and the fault is in the EPD path — `MANUAL.md` §7 is the playbook.

## 10. Post-install tuning

`docs/17-eink-device-tuning.md` has the full set with reasoning. The essentials:

```sh
adb shell '
settings put global window_animation_scale 0
settings put global transition_animation_scale 0
settings put global animator_duration_scale 0
settings put secure high_text_contrast_enabled 1
cmd uimode night no'
```

Animation is far more expensive here than on an LCD: every frame is a panel
refresh. Turning it off took idle refreshes from ~12 per 10 s to zero.

## 11. If it does not boot

`adb` usually survives, because the display is not on the boot path.

| symptom | action |
|---|---|
| boots, screen blank | check the shim loaded: `grep -c epdcshim /proc/$(pidof vendor.qti.hardware.display.composer-service)/maps` |
| nav/status bar missing | client composition: `service call SurfaceFlinger 1008 i32 1` |
| SurfaceFlinger crash loop | restore the previous binary from `/data/local/tmp/` |
| no boot, adb dead | EDL, restore from your step-2 backup |
| bootloop after a partition write | wrong extents or a stale `lpdump` — re-dump before patching metadata |

---

## Current limitations

Be clear-eyed about what you are installing.

* **Updates are full-panel.** Every change repaints all 1648×824 pixels, because
  SurfaceFlinger publishes one coarse damage rectangle. It works and it is
  usable, but it is not as snappy as stock. Fixing this is the main open task
  (`docs/15`).
* **Client composition is forced**, which costs GPU work that hardware
  composition would avoid.
* **`temp` is sent as 0** in every EPD update, while the driver exposes a
  temperature index. Waveforms are temperature-indexed, so behaviour in a cold
  or hot room is unvalidated.
* **The settle pass is disabled** — its timer thread does not currently fire.
* **No OTA.** Updating means rebuilding and reflashing.
* **Camera, sensors and radio are only lightly tested.** This project's focus has
  been the display.

## Where to look next

| | |
|---|---|
| `MANUAL.md` | hardware, the display path end to end, `/dev/ebc`, debugging playbook |
| `docs/16` | build/flash/test loop and the traps that cost the most time |
| `docs/17` | e-ink tuning with reasoning |
| `docs/18` | how other open e-ink projects handle refresh |
| `docs/15` | the open task: per-layer damage |
| `THIRD_PARTY.md` | what was reused, and under what licence |
