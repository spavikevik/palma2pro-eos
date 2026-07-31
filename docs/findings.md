# Recon findings — Palma 2 Pro (Palma2_Pro_C)

Source: `palma-recon.txt`, stock firmware `2026-05-11_20-31_4.2-rel_05112`, security patch
2026-04-01. Non-root ADB shell.

## Platform identity

| Property | Value | Note |
|---|---|---|
| `ro.product.device` | `Palma2_Pro_C` | |
| `ro.board.platform` | `lito` | SM7225, confirms SD750G |
| `ro.build.version.release` | 15 | **system only** |
| `ro.vendor.build.fingerprint` | `...Palma2_Pro_C:11/...` | **vendor is Android 11** |
| `ro.vndk.version` | **30** | Android 11 VNDK |
| `ro.board.api_level` / `first_api_level` | 30 | |
| `ro.product.first_api_level` | 30 | device launched as API 30 |
| `ro.treble.enabled` | true | GSI viable |
| `ro.boot.slot_suffix` | `_b` | **active slot is B** |
| `ro.product.ab_ota_partitions` | product, system, system_ext, vbmeta_system | vendor is *not* OTA-updated |

`ro.build.fingerprint` reports `ONYX/TabBoox/TabBoox:13/TKQ1.230615.001/...` — an Android
13 fingerprint on a device whose system is 15 and vendor is 11. Spoofed, presumably for
Play integrity. Three different Android versions are asserted across the prop set.

This is the standard Qualcomm **qssi** split: a modern generic system image over a frozen
older vendor BSP. Onyx froze vendor at Android 11 and has been shipping newer qssi systems
on top ever since.

### Implication for GSI selection

A VNDK-30 vendor needs a GSI that ships the VNDK 30 snapshot. **Android 15 deprecated
VNDK**, so an A15 GSI is the wrong first choice despite the device's system being A15 —
Onyx's own qssi image bundles the VNDK 30 APEX, a generic one likely won't.

- **First attempt: /e/OS Android 13 GSI, arm64, A/B, vndklite.** A13 still carries VNDK 30.
- Second attempt: A15 GSI. Cheap to test — worst case is a bootloop and a reflash.
- `vndklite` is indicated both by the VNDK situation and because we want `/system`
  writable for the refresh shim.
- /e/OS GSIs are community/unofficial builds, not official e Foundation device releases.

Encouraging precedent: Onyx already runs a system image four Android versions newer than
its vendor. The vendor interface on this device demonstrably tolerates version skew.

## E-ink control surface — GOOD outcome

This was the make-or-break question. It resolved in our favour.

### Kernel exposes the EPD controller

```
/sys/devices/platform/onyx_epdc_fb.0
/sys/class/sepdc
/sys/devices/virtual/sepdc
/sys/devices/platform/soc/soc:sepdc_mfd
/sys/bus/platform/drivers/onyx_epdc_mfd    -> soc:sepdc_mfd
/sys/bus/platform/drivers/onyx_epdc_fb     -> onyx_epdc_fb.0
/sys/module/onyxdsi
```

`onyx_epdc_fb` is an EPDC **framebuffer** driver — the same shape as i.MX's `mxc_epdc_fb`,
which exposes waveform mode and update mode through ioctls (`MXCFB_SEND_UPDATE`-style) and
sysfs attributes. `sepdc_mfd` is the multi-function device for the EPD controller itself.
`onyxdsi` handles the panel over Qualcomm's DSI.

Display path: MDSS/SDE DRM (`card0-DSI-1`, `sde-crtc-0/1`) → `onyxdsi` → `sepdc` controller.

### No proprietary Onyx HAL exists

`lshal` output contains **zero** `vendor.onyx.*` entries. Every display service is stock
Qualcomm:

```
vendor.qti.hardware.display.composer@3.0::IQtiComposer/default
vendor.qti.hardware.display.allocator@{3,4}.0
vendor.display.config@2.0::IDisplayConfig/default
```

So there is no closed binder HAL standing between userspace and the EPD controller. The
chain is almost certainly:

```
Onyx Java code (/system)  ->  libonyx_epd_listener.so (JNI)  ->  ioctl/sysfs on onyx_epdc_fb
```

`libonyx_epd_listener.so` appearing in the library scan is a strong hint at exactly that.

**Consequence:** task 6 (refresh controller) drops from "reverse-engineer proprietary
blobs, months, may not land" to "enumerate a kernel driver's ioctl/sysfs surface and drive
it ourselves, weeks." This is the difference between the project being viable and not.

### Open question

`/system/framework/` showed only `privapp-permissions-onyx.xml` — no `onyx-framework.jar`.
But Onyx may have patched `framework.jar`, `services.jar` or `SurfaceFlinger` **in place**,
under stock filenames, which a name-based grep can't detect. A GSI replaces all of those.

If the refresh policy lives in patched framework internals rather than in an app, we have
to reimplement the policy layer, not just the transport. Still tractable — the kernel
interface is the hard part and it's open — but it changes the effort.

Resolved by inspecting the stock `system` image. See below.

## Telemetry surface

All Onyx packages are in `/system/app` or `/system/priv-app`:

```
com.onyx.igetshop          com.onyx.appmarket        com.onyx.aiassistant
com.onyx.android.ksync     com.onyx.android.onyxotaservice
com.onyx.kreader           com.onyx.android.note     com.onyx.easytransfer
com.onyx (priv-app, kcb-release)                     com.onyx.mail  ... (21 total)
```

Plus `com.google.android.gms`, `com.android.vending`, `com.google.android.gsf`,
`com.google.android.gms.location.history`, and preinstalled `com.amazon.kindle`,
`org.chromium.chrome`.

No standalone `umeng` / `baidu` / `tencent` / `jpush` / `getui` packages — those SDKs are
bundled inside the Onyx APKs rather than shipped separately.

**Because every one of these lives in `/system`, a GSI removes all of them by
construction.** The stated goal — stop the device talking to Onyx's servers — is fully
achieved by the GSI step alone. /e/OS microG additionally displaces GMS.

## Partition notes

- `super` → `sda8`; dynamic partitions confirmed.
- Active slot **B**. `edl-verify-restore.sh` tests `dtbo_b` by default — **must be changed
  to `dtbo_a`** before running, since B is live.
- `onyxconfig` → `sda9`, an Onyx-specific config partition, mounted at boot
  (`dev.mnt.blk.onyxconfig`). Unknown contents, possibly device provisioning. Back it up;
  do not assume the GSI can recreate it.
- Onyx init services exist (`init.svc.init_onyx_config`, `init.svc.onyx-sh`,
  `init.svc.onyx_console`) but no matching rc files were found in `/vendor/etc/init` or
  `/system/etc/init` — they likely live in the boot ramdisk. A GSI keeps `boot`, so these
  survive.
- `/proc/partitions` was permission-denied on a non-root shell; not important, the
  `by-name` listing covers it.
- `/sys/class/graphics` listed empty and `find` could not descend into `/sys/class/sepdc`
  or `onyx_epdc_fb.0` — sysfs directories are root-only. **Re-run recon with root** to
  enumerate the actual attribute names.

## Hardware, confirmed over EDL

From a live Sahara/Firehose session (`edl-verify-restore.sh`, Gate 3 pass):

```
HWID          0x0013f0e100000000  (MSM_ID 0x0013f0e1, OEM_ID 0x0000)
CPU           "bitra_SDM"          -> Qualcomm bitra = SM7225 = Snapdragon 750G
Chip serial   0x5197f39b
Storage       UFS, 6 physical LUNs, 30119936 blocks x 4096 = ~123 GB
UFS part      H9QT0G6CN6X146 (SK Hynix), fw 003
Loader        Lenovo/Motorola SM7225 firehose, build Aug 21 2020 -- accepted
```

`bitra` independently confirms the SM7225 identification the whole Fairphone 4 strategy
rests on.

Firehose functions available: `program, read, erase, patch, configure,
setbootablestoragedrive, power, firmwarewrite, getstorageinfo, benchmark, emmc, ufs,
fixgpt, getsha256digest, getvar, dump`.

Two of those are worth remembering:

- **`power`** — `edl reset` reboots the device out of EDL. A device parked in EDL is
  indistinguishable from a bricked one on an e-ink panel, because the display holds its
  last frame. Reach for this before assuming the worst.
- **`getsha256digest`** — lets us verify a partition's contents *on the device* rather
  than trusting a read-back, which is stronger verification for the ABL swap.

### Gate 3 result

`dtbo_a` (inactive slot; active is `_b`) written from backup at physical partition 4,
sector 126690, 6144 sectors, then read back and compared over its full 25165824 bytes:
**identical**. EDL read and write both work on this unit. Receipt at
`backup/<stamp>/GATE3-PASS`.

## Super image analysis — both open questions answered

Source: `firmware/super.img` (6 GiB raw EDL read, LP metadata valid), unpacked with
`scripts/lpunpack.py`, read with `debugfs`.

### Dynamic partition layout — Virtual A/B with active snapshots

```
metadata slot 0:  odm_a, product_a, system_a, system_ext_a, vendor_a   (single extents)
metadata slot 1:  odm_b, product_b, system_b, system_ext_b, vendor_b   (multi-extent)
                + odm_b-cow, product_b-cow, system_b-cow
```

The `-cow` devices mean **Virtual A/B (VABC)** with a snapshot overlay live, consistent
with `sys.boot.reason.last: reboot,onyxotaservice`. Two consequences:

- Concatenating `system_b`'s extents yields the **pre-merge base**, not live content.
  Analysis therefore used metadata slot 0 / the `_a` set: single clean extents, and
  `vendor`/`odm` are excluded from `ro.product.ab_ota_partitions` so `vendor_a` is
  byte-identical to what runs.
- **An unmerged snapshot will interfere with flashing.** Before any fastbootd work on
  logical partitions, the merge must be complete or cancelled. Add this to the unlock
  checklist.

### Q1 — Onyx patched SurfaceFlinger in place. Confirmed.

`/system/bin/surfaceflinger` is not stock. Extracted symbols and strings:

```
android::EpdcWrapper::addEpdc(int,int,int,int,int)
android::EpdcWrapper::addEpdcList(std::vector<hwc_epdc_llist> const&, bool)
android::EpdcWrapper::mergeByMode(...)
EpdcManager   EpdcSchemaManager   HWEpdcManager   SWEpdcManager
ApplyEInkShader   setEInkShaderType. type %d
### add full screen epdc, mVisibleRegionsDirty %d mGeometryDirty %d
### sf epdc region received: %d %d %d %d mode: %d
### do not switch epd Schema in handwriting mode
refresh screen (%d, %d - %d, %d) waveform_mode %d flags 0x%x marker %d
```

`mVisibleRegionsDirty` / `mGeometryDirty` are SurfaceFlinger internals — this is a real
source-level patch to the compositor, not a shim beside it. The refresh *policy* (which
waveform mode for which damage region, schema switching, handwriting special-casing,
an e-ink shader) lives inside the compositor Onyx built.

There are also `init.onyx.sh`, `init.onyx.misc.sh`, `init.onyxconfig.sh` in `system`, and
a `hwc_epdc_llist` type shared with hwcomposer.

**This is the bad half of the news, and it changes the plan — see below.**

### Q2 — The transport is `/dev/ebc`, a Rockchip-derived EBC ioctl API. Excellent.

The EPD drivers are **built into the kernel**, not modules (`vendor/lib/modules` holds only
audio/wlan/`lcd.ko`). `boot_a` carries an uncompressed ARM64 `Image`, so its strings read
directly.

Device node, from the SurfaceFlinger binary: **`/dev/ebc`**.

Kernel-side ioctl vocabulary:

```
SET_EBC_SEND_BUFFER            GET_EBC_BUFFER
SET_EBC_SEND_UPDATE            GET_EBC_BUFFER_INFO
SET_EBC_WAIT_ALL_UPDATE_COMPLETE   GET_EBC_DRIVER_SN
SET_EBC_CLEAR_ALL_UPDATE       SET_EBC_LUT_ENABLE
SET_EBC_FORCE_WAVEFORM         SET_EBC_GAMMA_TAB
SET_EBC_UPDATE_SCHEME          SET_EBC_UPD_LIST_SIZE
SET_EBC_EXTBUF_SYNC_FB_ENABLE  + capture-all APIs
```

Update parameters, straight from a kernel log format string:

```
commit[%d] upd_data_cnt[%d][0] [%d %d %d %d] waveform_mode[%d] update_mode[%d]
    update_marker[%d] flag[%d] temp[%d]
[UI] update_marker[%d] waveform[%d] update_mode[%d] flags[0x%x]
```

Rect, waveform mode, update mode, marker, flags, temperature — plus `ebc_open`,
`ebc_ioctl`, `ebc_mmap`, and marker-completion waits. Waveform modes present: `INIT`,
`DU`, `A2`, `GC16`, `REGAL`/`REAGL`.

**`/dev/ebc` with `SET_EBC_SEND_UPDATE` is the Rockchip E-Book Controller interface.**
Onyx ported Rockchip's EBC driver onto Qualcomm. That driver is open source in the
Rockchip kernel tree and is what the PineNote uses — so ioctl numbers and struct layouts
have a **public reference implementation** rather than needing blind reversing.

Also noted: `/sys/onyx_misc/cytp_lo_filter` (touch filter), `dithering_set_debounce_*`,
`epdc_display_timeout`, `epdc_power_timeout`.

`libonyx_epd_listener.so` turned out to be a red herring — it is only a FIFO event
listener for `android.onyx.optimization.EpdEventListener`, not the ioctl path.

## What this means for the plan

The transport is easy and documented. The **policy lives in a patched compositor**, and a
prebuilt GSI ships a stock SurfaceFlinger. So:

- **A prebuilt /e/OS GSI cannot carry a patched SurfaceFlinger.** Flashing one gives a
  booting, de-Onyx'd system whose display drives itself with no EPD update policy.
- Getting *good* e-ink on /e/OS therefore means **building /e/OS from source** with our own
  `EpdcManager` equivalent in SurfaceFlinger, driving `/dev/ebc`. That is the device-tree
  port (task 7), not the GSI path.
- A **userspace daemon** talking to `/dev/ebc` directly — periodic full-screen `GC16`
  refreshes plus `A2` for fast regions, without compositor damage information — is a
  viable stopgap. Usable, visibly worse than stock, and it needs SELinux permission to
  open `/dev/ebc`.

Revised expectation: **GSI is a hardware-compatibility experiment, not the destination.**
It answers whether modem/wifi/BT/sensors survive on a non-Onyx system, cheaply. The
daily-driver end state is a source build.

## Revised plan

EDL **reads** do not require an unlocked bootloader. So the remaining unknowns can be
resolved with zero risk, before any bootloader work:

1. EDL-dump `super` (read-only), `lpunpack` it, and:
   - check whether `SurfaceFlinger` / `services.jar` / `framework.jar` are Onyx-patched,
   - pull `onyx_epdc_fb.ko`, `onyxdsi.ko`, `libonyx_epd_listener.so` and extract the sysfs
     attribute names and ioctl numbers from their strings/disassembly.
2. That output specs the refresh shim **and** gives the go/no-go on the whole plan.
3. Only then take on the ABL swap and its brick risk.

Task 4 (extract firmware) therefore moves ahead of task 3 (unlock).

## VABC snapshot state — verified clear (task 9)

Checked with root, which was not available when this concern was first raised:

```
snapshotctl dump  ->  Update state: none
                      Read state file failed: No such file or directory
/metadata/ota/snapshots  ->  empty
```

**No snapshot merge is pending.** The `-cow` entries visible in `super`'s
metadata slot 1 are inert leftover allocations from a completed OTA, not live
snapshots. The earlier worry that they would interfere with fastbootd was
unfounded.

Live layout from on-device `lpdump`:

```
super                        6442450944 bytes
group qti_dynamic_partitions_b  max 6438256640

system_b       ~3.0 GiB      product_b      ~700 MB
system_ext_b   ~665 MB       vendor_b       ~650 MB     odm_b  ~1 MB
group "cow":   odm_b-cow, product_b-cow, system_b-cow   ~1.07 GiB total
```

`system_b` at ~3.0 GiB is comfortably larger than a typical GSI, so the flash
needs no partition surgery beforehand. The cow partitions waste ~1 GiB but are
harmless; if space is tight during the flash, fastbootd can delete them at that
point rather than pre-emptively.

Header flags confirm `virtual_ab_device`, and
`ro.virtual_ab.compression.enabled` is unset — plain Virtual A/B, no compression.

## Task 5 blocked: Onyx fastbootd rejects `flash`

```
is-userspace: yes        product: Palma2_Pro_C
fastboot delete-logical-partition  -> OK
fastboot create-logical-partition  -> OK
fastboot flash system <gsi>        -> FAILED (remote: 'Unrecognized command flash')
```

Onyx stripped `flash` from their fastbootd, exactly as they stripped unlock from
their ABL. Bootloader fastboot also has no `oem edl` and the client has no
`reboot-edl`, so there is no software route from fastboot to EDL.

**No damage was done.** The sparse `Sending` step only downloads into a buffer;
the rejected `Writing` step means `system_b` was never modified. `delete` +
`create` reused the same extents, so stock Android booted normally. Cost: the
three inert `-cow` partitions were deleted (no loss) and `system_b` is now
allocated at 3597176832 bytes.

### Lesson

`fastboot flash` was never probed before committing. This vendor removes
commands as a matter of habit -- unlock from ABL, store handlers from sysfs, now
flash from fastbootd. A one-line test against a throwaway partition would have
caught it.

### Remaining path

Rebuild `super` offline and write it whole over EDL, which is proven on this
device:

1. `lpunpack` / `lpmake` (or `lpadd`) to produce a new super image with the GSI
   as `system_b`, using `firmware/super.img` as the base.
2. `edl w super <new-super.img> --loader=... --memory=ufs`

Everything needed is already on disk: `firmware/super.img` (6 GB, LP magic
verified), `firmware/eos-a14-gsi.img` (3597176832 bytes, raw ext4, arm64),
`scripts/lpunpack.py`, and a verified EDL write path.

### GSI availability note

`/e/OS` publishes no Android 13 GSI (only 14, 15, 16) and no `vndklite` variant
-- one build per version. A14 was chosen as the newest release still likely to
carry the VNDK 30 snapshot this Android-11 vendor needs.

## ROOT CAUSE of the GSI boot failure: wrapped-key encryption

`/vendor/etc/fstab.emmc`:

```
/dev/block/bootdevice/by-name/userdata  /data  f2fs  ...,inlinecrypt
  latemount,wait,check,formattable,quota,reservedsize=128M,
  fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0,
  metadata_encryption=aes-256-xts:wrappedkey_v0,
  keydirectory=/metadata/vold/metadata_encryption,checkpoint=fs
```

**`wrappedkey_v0`** is Qualcomm's hardware-wrapped key scheme (HWKM + inline
crypto engine). The kernel supports it; a generic GSI's `vold` does not, because
that support is a vendor-specific build option rather than something stock AOSP
enables by default.

Consequence: `/data` cannot be set up, the format attempt also fails, and the
device drops to recovery offering a factory reset -- on every boot. That is
exactly the loop observed.

### This supersedes the VNDK theory

Earlier reasoning blamed `ro.vndk.version=30` and drove the A13 -> A14 GSI
choice. The evidence contradicts it: **Onyx's own Android 15 system image
contains no VNDK apex, no vndk directories, and no vndk build properties.**
Android 15 removed VNDK entirely; the `ro.vndk.version=30` prop on this device is
a vestigial vendor value. VNDK was never the blocker.

### What it means for a source build (task 7)

This is solvable and well understood in the LineageOS world: Qualcomm device
trees enable wrapped-key support in `vold`/`keymaster` via board flags. A proper
device-tree build can turn it on, unlike a prebuilt GSI.

So the ordering is: a source build needs (a) wrapped-key support enabled, and
(b) the EPD story from docs/03-ebc-api.md. Item (a) is the boot blocker and must
be handled first -- without it, nothing boots regardless of display support.

### Also noted: Onyx system-side init dependencies

`/vendor/etc/init/hw/init.onyx.rc` (imported by `init.qcom.rc`) runs
`/system/bin/mkfifo` to create `/dev/onyx/listener`, and chmods a long list of
`/sys/onyx_misc/*` nodes. Any system port must provide `mkfifo` at that path or
the Onyx FIFO and several sysfs permissions will be missing. Not boot-fatal, but
required for the pen, keyboard, backlight and vibrator paths to work.

### Correction: wrapped keys are probably NOT the GSI blocker

The LineageOS Fairphone 4 tree (`android_device_fairphone_FP4`, same SM7225) uses
the same scheme:

```
fileencryption=aes-256-xts:aes-256-cts:v2+inlinecrypt_optimized+wrappedkey_v0
metadata_encryption=aes-256-xts:wrappedkey_v0
```

(Palma differs only in `emmc_optimized` vs `inlinecrypt_optimized`, and lacks
FP4's `sysfs_path=` hint.)

Crucially, **FP4's `BoardConfig.mk` sets no crypto or keymaster flags at all.**
Wrapped-key support is therefore generic in AOSP `vold`, with the vendor's
KeyMint supplying the storage-key capability -- not something a device tree has
to switch on.

If it is generic, a prebuilt GSI's `vold` would have it too, so `wrappedkey_v0`
is unlikely to be what broke the GSI boot. The earlier claim in this document
that it was "the root cause" is **not supported** and should be treated as an
open question.

Remaining candidates for the GSI failure, none yet confirmed:

- vendor VINTF / HAL manifest incompatibility with a generic system image
- missing Onyx system-side pieces the vendor init expects (`/system/bin/mkfifo`
  for `/dev/onyx/listener`, the `/sys/onyx_misc/*` chmods)
- the `/onyxconfig` partition mount and its `on fs` setup
- something in first-stage init or the ramdisk

Diagnosing it properly needs the failure logs, which recovery would not give us
(adb unauthorized). It is moot for task 7 either way: a device-tree build is the
plan regardless, and it can carry whatever the GSI lacked.

### What the FP4 tree IS good for

A directly usable reference for an SM7225 device tree: same SoC, same encryption
setup, maintained. It is the right starting point for a Palma 2 Pro tree --
BoardConfig, partition layout, kernel packaging and fstab structure all transfer.

## GSI failure: seven hypotheses tested offline, all rejected

With both the stock system and the /e/OS GSI extracted locally, each candidate
was checked by direct comparison rather than reasoning. Every one came back
identical or non-fatal:

| Hypothesis | Test | Result |
|---|---|---|
| VNDK 30 missing | list `/system/apex`, `vndk` dirs, build.prop | stock A15 ships **no VNDK at all** |
| `vold` lacks wrapped-key support | `strings` on both `vold` binaries | both have `wrappedkey_v0`, `emmc_optimized`, `metadata_encryption` |
| VINTF mismatch | compare framework manifests + vendor matrix | **identical**; vendor needs 7 framework HALs, both satisfy |
| Missing `/system` binaries | 17 vendor-init refs vs both images | 5 Onyx scripts missing, but **no vendor service is `critical`** |
| keystore2 / keymaster | `strings` for HIDL keymaster + storage key | both have `IKeymasterDevice`, `KeyMintDevice`, `convertStorageKeyToEphemeral` |
| f2fs tooling absent | list `make_f2fs`, `fsck.f2fs`, `sload_f2fs` | identical in both |
| SELinux version mapping | vendor `plat_sepolicy_vers.txt` vs system mappings | vendor wants 30.0; **both** ship `30.0.cil` + `30.0.compat.cil` |

Vendor was built against platform sepolicy **30.0**, and provides keymaster only
as **HIDL `@4.1`** (no AIDL KeyMint) -- both facts worth remembering, neither
fatal.

### Correction: the symptom was misread

The recovery message *"Can't load Android system. Your data may be corrupt"* is
Android's **generic** failed-boot fallback, offered with a factory reset because
that is the only remedy recovery has. It does not specifically mean `/data`
failed to mount. Several hypotheses above were built on that misreading.

### The untested structural difference

A GSI replaces **only `system`**. Both flash attempts left Onyx's `product`
(683 MB: `framework/`, `lib64/`, 10 RRO overlays, 7 priv-apps) and `system_ext`
in place -- built against Onyx's own system. RRO overlays targeting framework
resources are a well-known way to break a foreign system image, and nothing was
done to neutralise them.

If a GSI is ever retried, blank `product` and `system_ext` first rather than
only replacing `system`. That is the most plausible remaining explanation and it
was never controlled for.

### Also never cleanly tested

The A15 attempt was flashed alongside a **broken recovery image**, so its hang is
fully explained by "system fails -> falls back to recovery -> recovery is
broken -> hang". A15 has never had a clean boot attempt. The only sound data
point is A14 failing to boot with Onyx's product/system_ext still present.

### Eighth: AVB GSI keys (also rejected, but worth knowing)

The boot ramdisk's fstab entry for `system` is:

```
system /system ext4 ro,barrier=1
  wait,slotselect,avb=vbmeta_system,logical,first_stage_mount,
  avb_keys=/avb/q-gsi.avbpubkey:/avb/r-gsi.avbpubkey:/avb/s-gsi.avbpubkey
```

and `/avb/` in the ramdisk contains exactly three keys: **q-gsi, r-gsi, s-gsi**
-- Android 10, 11 and 12. There is no t/u/v key, so this device can only verify
official Google GSIs up to Android 12. Onyx never provisioned it for newer ones.

That is a real, designed-in limitation and worth remembering. It was **not** the
blocker for our attempts, though. From `system/core/init/first_stage_mount.cpp`:

```cpp
if (!fstab_entry->avb_keys.empty()) {
    if (!InitAvbHandle()) return false;
    // Checks if hashtree should be disabled from the top-level /vbmeta.
    if (IsHashtreeDisabled(*avb_handle_, fstab_entry->mount_point)) {
        return true;  // Returns true to mount the partition directly.
    }
```

`IsHashtreeDisabled()` returns true for `kHashtreeDisabled` **or**
`kVerificationDisabled`. Our vbmeta was patched to flags `0x3` (both), so init
takes the early return and mounts `system` without consulting `avb_keys` at all.

Consequence for a *signed* deployment: if verified boot were ever re-enabled,
only a Q/R/S-signed GSI could mount. Our own builds sidestep this by being
flashed with verification disabled on an unlocked bootloader.

---

# The GSI failure, resolved: `init_user0_failed`

Eleven hypotheses were rejected by inference before anyone read the one place
the device records *why* it rebooted. The `misc` partition's bootloader control
block held the answer the whole time:

```
command : boot-recovery
recovery: recovery
          --prompt_and_wipe_data
          --reason=init_user0_failed
```

`--prompt_and_wipe_data` is what renders the "Can't load Android system. Your
data may be corrupt." screen. It is not a generic failure -- it is a specific,
deliberate request from the framework.

## What this proves

`init_user0_failed` is set by **system_server**, not by the bootloader, not by
init, and not by recovery. It comes from `StorageManagerService`, in the catch
around `vold.initUser0()`, which calls
`RecoverySystem.rebootPromptAndWipeUserData()`.

So the GSI was never failing early. Every run it:

1. passed the bootloader and AVB (verification disabled),
2. mounted `system` and ran init to completion,
3. mounted `/data` -- metadata encryption and the f2fs format both worked,
4. started zygote and system_server,
5. failed **only** when creating user 0's FBE keys.

That retroactively invalidates the reasoning behind most of the eleven
hypotheses. VNDK, VINTF, missing `/system` binaries, sepolicy version mapping
and the rest all concern early boot. Early boot was fine.

## What was then tested against it, and failed

| Test | Result |
|---|---|
| Wipe `/data` + zero `/metadata`, clear BCB | identical `init_user0_failed` |
| `androidboot.selinux=permissive` (userdebug GSI, so honoured) | identical failure |
| Blank `product` + `system_ext` | identical failure |

The wipe is the important one. It kills the obvious explanation -- that `/data`
carried stale keys provisioned by stock -- because a freshly formatted `/data`
with a zeroed `/metadata` fails exactly the same way. The failure is in
**creating** user-0 keys, not in loading old ones.

Permissive is equally decisive in the other direction: SELinux is now excluded
by measurement rather than by reading policy files.

## Leading explanation

The fstab requires hardware-wrapped keys:

```
fileencryption=aes-256-xts:aes-256-cts:v2+emmc_optimized+wrappedkey_v0
metadata_encryption=aes-256-xts:wrappedkey_v0
```

`wrappedkey_v0` needs KeyMint to mint a storage key (`TAG_STORAGE_KEY`). This
vendor is Android 11, so it exposes Keymaster 4.1 and the request must traverse
keystore2's legacy compat path. Stock works because its system side is
Qualcomm's own qssi build, which carries QTI's downstream vold/keystore
handling; a generic AOSP GSI has only the upstream path.

Note `/metadata` encryption -- also `wrappedkey_v0` -- **succeeds**, since `/data`
mounts. Only the per-user FBE keys fail. Any final explanation has to account
for that asymmetry, so this remains the leading hypothesis rather than a proven
cause.

## Why the investigation stopped here

Direct logs from the failing boot were pursued and are not obtainable:

- **adb during boot** -- the GSI ships `ro.adb.secure=0` and `ro.debuggable=1`,
  so its adbd would appear as `device`, needing no dialog. It never enumerates:
  46 seconds of no USB at all during the boot window. USB gadget setup goes
  through Onyx's Android 11 vendor HAL, which the A15 GSI framework does not
  drive. Every `unauthorized` ever seen on this device was *stock recovery's*
  adbd, never the GSI's.
- **`logfs` / `logdump` / `rawdump`** -- all zero. `logfs` is a bare FAT12
  volume with 497 non-zero bytes (boot sector only). These Qualcomm regions are
  only populated when ramdump collection is armed, which it is not on a retail
  unit.
- **Recovery's on-screen log** -- this is an A/B device with no `/cache`, and
  persistent logs live in `/data/misc/recovery`, which is wiped and unmountable.
- **Magisk `overlay.d` injection** -- a `bootlog.rc` looping `logcat -d` into the
  unused `logdump` partition. The rebuilt boot image did not reach system_server
  at all (the BCB stopped being written), so this was debugging the
  instrumentation rather than the device.

The remaining question is answerable far more cheaply in the source build, where
vold, keystore2 and the fstab are all ours to configure, than by reverse
engineering a prebuilt image through hand-patched boot images.

---

# Correction: the `init_user0_failed` conclusion was wrong

The section above concluded that the GSI booted to system_server and died in
`vold.initUser0()` under `wrappedkey_v0`. Once the full A15 source was available
on the build host, both halves of that turned out to be unsupported.

## `init_user0_failed` is not an Android 15 string

It does not exist anywhere in the `v4.2-a15` tree (grepped, excluding `.repo`
and `out`). A15 reports this failure from a different place with different
wording -- `frameworks/base/.../pm/UserDataPreparer.java:151`:

```java
RecoverySystem.rebootPromptAndWipeUserData(mContext,
        "failed to prepare internal storage for system user");
```

`init_user0_failed` is Android 11-13 wording, from when
`StorageManagerService` called `mVold.initUser0()` directly. `initUser0` still
exists as a vold API (`IVold.aidl:85`, `VoldNativeService.cpp:583`) but the A15
framework no longer reports failures that way.

And the GSI we flashed really is A15, built from the same BUILD_ID as this tree:

```
ro.system.build.fingerprint=google/treble_arm64_bmGN/tdgsi_arm64_ab:15/BP1A.250505.005/...
ro.system.build.version.sdk=35
```

So whatever wrote that BCB, **it was not the A15 GSI's framework.** Candidates
not yet distinguished: Onyx's stock A15 qssi system (which carries a spoofed
`:13` fingerprint and may carry older framework code with it), or a leftover from
the earlier A14 GSI attempt on the other slot. Unresolved, and no longer worth
resolving -- the GSI path is closed either way.

The reasoning error is worth naming: a BCB reason string was treated as proof of
which component wrote it, without checking that the component in question
contains that string.

## AOSP already supports hardware-wrapped keys

The proposed mechanism -- generic AOSP lacking QTI's downstream vold/keystore
handling for `wrappedkey_v0` -- is false. Upstream A15 implements the whole path:

| Concern | Where |
|---|---|
| `metadata_encryption=...:wrappedkey_v0` parsed | `system/vold/MetadataCrypt.cpp:239` |
| `fileencryption=...+wrappedkey_v0` read from fstab | `system/vold/FsCrypt.cpp:337` |
| ephemeral key exported for FBE | `system/vold/FsCrypt.cpp:350` |
| KeyMint `TAG_STORAGE_KEY` call | `system/vold/Keystore.cpp:162` (`convertStorageKeyToEphemeral`) |
| `wrappedkey_v0` handed to dm-default-key | `system/core/libdm/dm_target.cpp:284` |

This also explains an asymmetry the earlier hypothesis could not: `/metadata`
encryption uses `wrappedkey_v0` too and **succeeded**. Support is not partial --
it is present for both.

**Consequence for the source build: no wrapped-key patches are needed.** The
device's fstab can be used as-is, which is what `device.mk` already assumed for a
different (and also wrong) reason. Ship it unmodified and let vold do its job.

## Second correction: the source of `init_user0_failed` is unknown

The correction above proposed that, since A15 lacks the string, an older
framework wrote it. That is also unsupported. An exhaustive search found it
nowhere:

| Searched | Result |
|---|---|
| `v4.2-a15` source (literal and the `init_user` fragment) | absent |
| stock A15 `services.jar`, all three dex | absent |
| stock, **all 45 jars** under `/system/framework` | absent |
| /e/OS A15 GSI `services.jar` (sdk 35, `BP1A.250505.005`) | absent |
| /e/OS A14 GSI `services.jar` (sdk 34, `AP2A.240905.003`) | absent |
| `boot`, `recovery_a`, `recovery_b` ramdisks, **decompressed** | absent |
| 186 firmware partitions incl. `tz`, `keymaster`, `abl`, `xbl`, `hyp` | absent |

Method notes, since the blind spots mattered:

* Raw byte grep of an ext4 image **does** cover native binaries -- file contents
  are not compressed -- so `/system/bin/vold` and `/system/bin/init` are covered
  by the whole-image greps.
* It does **not** cover dex inside a `.jar` (deflated zip) or a gzip ramdisk.
  Those were extracted with `debugfs` + `unzip`, and via `gzip.decompress`,
  respectively.

A promising false lead: stock's dex contains `init_user` and `_failed` as
separate strings, suggesting runtime concatenation. It is not that. The actual
string is `userspace_failed,init_user0` -- one of init's **userspace reboot**
failure reasons (`userspace_failed,enablefilecrypto`,
`userspace_failed,watchdog_triggered`, ...). `init_user0` appears only as a token
inside those, which is not evidence of an `init_user0_failed` builder.

Community reports describe the same reason string as a **user-0 storage
decryption failure**, resolved by wiping data, with one report attributing the
strings to a Trusty image -- not applicable here, since this device's TEE
partitions do not contain it either.

**Status: unattributed.** The BCB bytes were unambiguous, so something wrote
them. Two earlier attributions in this document were stated with more confidence
than the evidence supported; this one is left open deliberately.

What matters for the port is settled regardless, and is not affected by the
attribution: AOSP A15 implements hardware-wrapped keys fully (table above), so
the device's fstab needs no patching. Note also the timing -- by the time this
reason was read, `/metadata` had been zeroed and userdata's superblock destroyed
by us, which is exactly the state that legitimately produces a user-0 storage
failure on *any* system.

---

# A/B slots: which one is real

Needed because the device tree ships a prebuilt kernel and DTBO, and the two
slots are **not** copies of each other. Getting the pairing wrong risks a
kernel/overlay mismatch on a device whose display is the whole point.

## Slot B is active; slot A is marked unbootable

Authoritative source: the GPT partition **attribute bits**, which is where
Qualcomm's bootctrl HAL keeps slot state (48-49 priority, 50 active, 51-53 retry,
54 successful, 55 unbootable). Decoded from `backup/*/lun4/gpt_main4.bin`:

```
boot_a    attr=0x00f3000000000000  active=0  successful=1  unbootable=1  prio=3
boot_b    attr=0x0077000000000000  active=1  successful=1  unbootable=0  prio=3
dtbo_a    active=0  unbootable=1        dtbo_b    active=1  unbootable=0
vbmeta_a  active=0  unbootable=1        vbmeta_b  active=1  unbootable=0
```

Identical in both backup sets. Note the GPT header sits at offset **0x1000**, not
0x200 -- this is UFS with 4096-byte sectors, which is why a 512-byte-sector
assumption finds nothing.

## boot_a vs boot_b: same release, different kernel build

| | boot_a | boot_b (active) |
|---|---|---|
| kernel size | 56,541,200 | **60,735,504** |
| kernel banner | `4.19.157-perf-g8b1b2dc01cc9-dirty` | `4.19.157-perf-g3d47a6619220-dirty` |
| ramdisk | 1,146,790 | 1,314,906 |
| dtb size | 407,904 | 407,904 |
| header / os_version / patch | v2 / 11.0.0 / 2025-10 | v2 / 11.0.0 / 2025-10 |
| cmdline | identical | identical |

Same 4.19.157-perf base, same builder (`onyx@onyxUbuntu`), same clang 10.0.7,
same security patch -- but **different git commits** and a 4 MB size gap. Slot B
is a later Onyx build of the same release, consistent with an OTA having moved the
device from A to B.

`device/onyx/Palma2_Pro_C/prebuilt/Image` is `g3d47a6619220`, i.e. the **active**
slot's kernel. Confirmed twice over: by GPT attributes and by matching the
shipped SHA against both slots.

`dtbo_b` is paired with it for the same reason (`dtbo_a` 213,391 B vs `dtbo_b`
213,484 B -- genuinely different, not padding).

## `super` has two metadata slots, and `--list` shows the wrong one by default

```
LP metadata slot 0:  system_a 3.0G,  product_a 682.9M,  system_ext_a 665.3M
LP metadata slot 1:  system_b 3.0G,  product_b 701.0M,  vendor_b 649.4M
                     + system_b-cow 466.3M, product_b-cow 609.7M
```

Slot 1 describes the live layout and carries the Virtual A/B **COW snapshots** --
the same `-cow` partitions that had to be deleted in fastbootd before any logical
partition could be recreated.

`scripts/lpunpack.py --list` defaults to metadata slot 0, which describes the
stale slot A layout. That is a trap: it made slot A look like the populated one
and led to extracting `system_a` -- the *inactive* system -- when checking stock's
framework. Use `--slot 1` for the live tree, or better, read the GPT attributes
first and derive the slot from those.

Re-running that check against the live `system_b` changed nothing: same
fingerprint (`qti/qssi/qssi:15/...`), a `services.jar` of identical size
(21,621,567 bytes -- the OTA did not touch it), and still no
`init_user0_failed`.

---

# RESOLVED: `init_user0_failed` -- the actual chain

Supersedes the two "corrections" above. Both were wrong, and the *original*
conclusion was mechanically right. Recorded in order because the mistakes are
instructive.

## The code path

`system/core/init/builtins.cpp`:

```cpp
static Result<void> ExecVdcRebootOnFailure(const std::string& vdc_arg) {
    auto reboot_reason = vdc_arg + "_failed";              // <-- assembled here
    auto reboot = [reboot_reason](const std::string& message) {
        // TODO (b/122850122): support this in gsi
        if (IsFbeEnabled() && !android::gsi::IsGsiRunning()) {
            LOG(ERROR) << message << ": Rebooting into recovery, reason: " << reboot_reason;
            reboot_into_recovery({"--prompt_and_wipe_data", "--reason="s + reboot_reason});
        } else {
            LOG(ERROR) << "Failure (reboot suppressed): " << reboot_reason;
        }
    };
    std::vector<std::string> args = {"exec", "/system/bin/vdc", "--wait", "cryptfs", vdc_arg};
    return ExecWithFunctionOnFailure(args, reboot);
}

static Result<void> do_init_user0(const BuiltinArguments&) {
    return ExecVdcRebootOnFailure("init_user0");           // builtins.cpp:1175
}
// registered at builtins.cpp:1307 as the `init_user0` init builtin
```

So the chain is:

```
init.rc:1054  init_user0
  -> do_init_user0
  -> exec /system/bin/vdc --wait cryptfs init_user0
  -> vold VoldNativeService::initUser0()   (creates user 0's DE/CE keys)
  -> non-zero exit
  -> reboot_into_recovery --prompt_and_wipe_data --reason=init_user0_failed
```

**It is `init`, not `system_server`.** And `reboot_reason` is `vdc_arg + "_failed"`,
built at runtime -- which is the whole reason an exhaustive search for the literal
`init_user0_failed` across source, four framework dex sets, 186 partitions and
every ramdisk found nothing. Confirmed on-device: both the live stock system and
the /e/OS A15 GSI contain `init_user0` (x4) and `enablefilecrypto` (x2), and
neither contains `init_user0_failed`.

Community reports quote the matching log line, which is this exact lambda:

```
init: Exec service failed, status 25: Rebooting into recovery, reason: init_user0_failed
```

The `status N` is **vdc's exit code**, i.e. the specific vold failure. Worth
capturing next time -- it is the one number that would name the underlying error.

## Why it rebooted instead of continuing

```cpp
bool IsGsiRunning() { return !access(kGsiBootedIndicatorFile, F_OK); }
```

That indicator file is written by **DSU** (Dynamic System Updates). AOSP knows
`init_user0` can fail under a GSI -- that is what `TODO (b/122850122)` is about --
and suppresses the wipe-and-reboot when a GSI is detected, logging
`Failure (reboot suppressed)` and carrying on.

Our GSI was **flashed to `system_b`**, not DSU-booted, so no indicator file
existed, `IsGsiRunning()` returned false, and the suppression did not apply. Hence
the loop we observed: boot -> `init_user0` fails -> wipe prompt -> recovery ->
repeat.

That is the full explanation of the GSI failure. It is a known AOSP GSI
limitation, not a defect in this device, and not the wrapped-key theory.

## Consequences

* **For a GSI on this device:** boot it via **DSU** (`gsi_tool` / `adb shell
  gsi_tool install`) rather than flashing it. The reboot is then suppressed.
  Untested here; the GSI path is closed.
* **For our source build:** a non-issue. It is not a GSI, `IsGsiRunning()` is
  irrelevant, vold gets the device's real fstab, and AOSP A15 implements
  hardware-wrapped keys in full (table earlier). No patches needed.

## The reasoning errors, named

1. **Original:** "dies in `vold.initUser0()`" -- mechanically correct, but
   attributed the reporting to `StorageManagerService`, whose A11-13 wording it
   resembled.
2. **Correction 1:** "A15 has no such string, so it was not A15" -- wrong. Searched
   for a literal that is concatenated at runtime, then treated its absence as
   proof about the component.
3. **Correction 2:** "unattributable" -- wrong. The search space was wrong, not
   exhausted: never asked *who can write `--prompt_and_wipe_data`*, which finds it
   in three greps.

The productive question was not "where is this string?" but "what code writes this
BCB command?".

---

# THE ACTUAL BLOCKER: Android 15's BPF loader rejects this kernel

Found by booting the /e/OS A15 GSI as a **DSU** (with root, so `/sys/fs/pstore`
was finally readable) and reading the *previous* boot's kernel log.

## What happens

```
NetBpfLoad: NetBpfLoad v0.46 (/apex/com.android.tethering/...)
NetBpfLoad: Android V requires 4.19 kernel to be 4.19.236+.
NetBpfLoad: Unsupported kernel version (0x41309d)        <- 4.19.157
reboot: Restarting system with command 'netbpfload-missing'
```

`packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp`:

```c
if (isAtLeastV) {
    ...
#define REQUIRE(maj, min, sub) \
        if (isKernelVersion(maj, min) && !isAtLeastKernelVersion(maj, min, sub)) { \
            ALOGW("Android V requires %d.%d kernel to be %d.%d.%d+.", ...); bad = true; }
    REQUIRE(4, 19, 236)
    ...
    if (bad) { ALOGE("Unsupported kernel version (%07x)."); return 1; }
}
```

Onyx's kernel is **4.19.157** -- 79 stable releases below the required
**4.19.236**. `NetBpfLoad` returns 1, init's `netbpfload` service fails, and the
device reboots. This is a **hard gate**, and it is enforced only for
`isAtLeastV` (Android 15+); Android 14 and below merely warn.

**This, not `init_user0`, is why the A15 GSI could never boot.** The DSU attempt
reached ~16.6s -- well past `post-fs-data` where `init_user0` runs -- and died
here instead. The two failures are separate: a flashed GSI hit `init_user0`
first (stock-provisioned `/data`), while the DSU had fresh userdata and got
further.

## Why stock Android 15 works on the same kernel

Stock boots A15 on this exact 4.19.157 kernel. Both stock and the GSI ship
`com.android.tethering.capex`, at **different sizes** (11,161,600 vs
11,698,731), and `netbpfload` extracted from both contains the *same* gate
strings. So the difference is the compiled-in `REQUIRE` minimums, not the logic:
Onyx's APEX is an older or patched build that accepts 4.19.157.

That is the key insight -- the check is a **version heuristic** standing in for a
set of BPF backports, not a feature test. Qualcomm's 4.19.157 evidently carries
those backports, since stock A15 networking works on it.

## The fix, applied

`packages/modules/Connectivity` is built from source in this tree (no prebuilt
`com.android.tethering.apex` in `prebuilts/`), so the gate is ours to change:

```
REQUIRE(4, 19, 236)   ->   REQUIRE(4, 19, 0)
```

Original kept as `NetBpfLoad.cpp.orig`. Residual risk: if some BPF program in the
loader genuinely needs a post-.157 backport, it will fail at load time rather
than at the version check -- and that would show up as broken networking, not a
boot loop. Stock's behaviour argues against it.

## Alternative, if the patch proves insufficient

Target **Android 14**: the `REQUIRE` table is inside `if (isAtLeastV)`, so U and
below only warn. /e/OS has a14 branches. Costs device-tree rework (`bp1a` release
config is A15) but is a supported configuration rather than a patched one.

## Why this took so long to find

Every earlier attempt was blind: no adb during boot (vendor USB HAL), empty
`logfs`/`logdump`, no `/cache`, unreadable `/data`. The unlock was **root plus
DSU**: DSU boots the GSI without touching `super`, and root makes
`/sys/fs/pstore/console-ramoops-0` and `/data/misc/recovery/last_kmsg*` readable
-- the previous boot's kernel log, which named the failure in one line.

Note the pstore log is a 128 KB ring holding only the *tail* of the previous
boot, and its contents are bit-rotted (`reboot: PestarTing s0steE gith command
'netbpfDoad-missiNg'`), so exact string matching fails. Use `grep -a` with short,
corruption-tolerant fragments.

## A14 DSU test: the BPF blocker is deeper than the V version gate

Tested the fallback recommendation directly by installing the /e/OS **A14** GSI
(sdk 34, `lineage_arm64_bmGN`) as a DSU. It also failed:

```
init: starting service 'bpfloader'...
init: Service 'bpfloader' has 'reboot_on_failure' option and failed, shutting down
reboot: Restarting system with command 'bpfloader-failed'
```

Different service name (A14 `bpfloader`, A15 `netbpfload`) and a different reboot
reason, but the same class of failure at the same point in boot (~17s).

**So "target Android 14" is not a free escape.** The `REQUIRE(4, 19, 236)` gate is
V-only, but A14's loader fails on this kernel for its own reasons. The A15 patch
we applied removes the version heuristic; whether the BPF *programs* then load is
a separate question this test does not answer.

The one thing that demonstrably works on this kernel is **Onyx's own tethering
APEX** -- stock A15 boots with it. That points at the more promising fix: ship
stock's `com.android.tethering.capex` rather than the one we build. Both stock and
GSI carry the same gate strings, so the difference is the compiled-in minimums.

### Encouraging side observation: the e-ink pipeline works under a GSI

The same log shows Onyx's EPDC display path initialising and committing frames
during the DSU boot:

```
[17.2] [drm:sde_crtc_prepare_commit_epdc:2320] plane[96][plane-5] ...
[17.2] sde_crtc_complete_commit_epdc(): crtc[...] is not is_dummy, dont release fence
```

The vendor display stack -- the part with no source and the hardest to replace --
comes up under a generic system image. That de-risks the largest unknown in the
port.

## APEX swap test: the loader lives in the APEX, so only a rebuild can fix it

Swapped Onyx's `com.android.tethering.capex` (the one that demonstrably works on
this kernel) into the A15 GSI with `debugfs`, preserving mode `0644`, `root:root`
and `security.selinux="u:object_r:system_file:s0\0"`; md5 round-tripped and
`e2fsck -fn` was clean.

Result: it booted **3 seconds further** (19.6s vs 16.6s) and then still failed:

```
init: processing action (load-bpf-programs) from (/system/etc/init/hw/init.rc)
init: starting service 'bpfloader'...
init: Service 'bpfloader' (pid 1183) exited with status 1
init: Service bpfloader has 'reboot_on_failure' option and failed, shutting down
reboot: Restarting system with command 'netbpfload-missing'
```

Two things learned:

* There is **no `/system/bin/netbpfload`** in either stock or the GSI. The
  `bpfloader` service is not defined in `init.rc` either -- `init.rc` only does
  `on load-bpf-programs / exec_start bpfloader`. The service definition *and* the
  binary both come from inside the tethering APEX.
* So a GSI cannot be fixed by swapping files around it: the loader that gates the
  kernel version is packaged in the APEX, and making it accept 4.19.157 means
  **rebuilding the APEX from source**.

Which is precisely what our tree does -- `packages/modules/Connectivity` is
source-built, and the patch to `NetBpfLoad.cpp` produces the loader that ships in
our own APEX. The GSI experiments cannot validate that patch; only our own build
can.

### Where this leaves the GSI question

Closed, with the cause understood rather than guessed:

| Attempt | Reached | Failed at |
|---|---|---|
| A15 flashed to `system_b` | `post-fs-data` | `init_user0` (stock-provisioned `/data`) |
| A15 via DSU | ~16.6s | `netbpfload`, `REQUIRE(4, 19, 236)` vs kernel 4.19.157 |
| A14 via DSU | ~17.2s | `bpfloader`, `reboot_on_failure` |
| A15 via DSU + stock APEX | ~19.6s | `bpfloader` from APEX, status 1 |

No prebuilt GSI can boot on this device, because every one of them ships a BPF
loader that rejects Onyx's 4.19.157 kernel, and that loader is inside an APEX.
Only a source build can carry the fix.

## Corroboration: TrebleDroid carries a patch for exactly this

This is a known, general GSI-vs-old-kernel problem, not device-specific.
TrebleDroid -- the patch set most GSI builds are based on -- ships
`platform_system_bpf/0001-bpfloader-relax-kernel-version-gates-and-fatal-error`
([example consumer](https://github.com/Lost-Entrepreneur439/LineageOS-a64_gsi/blob/lineage-23.2/patches/trebledroid-staging/platform_system_bpf/0001-bpfloader-relax-kernel-version-gates-and-fatal-error.patch)),
which does two things:

* relaxes the per-program kernel version gates (skip only below 4.9, where eBPF
  does not work at all, and at/above `max_kver`)
* removes the fatal early-return paths, and downgrades a `panic!` on
  `mkdir /sys/fs/bpf/vendor` to a warning

Their commit message names the mechanism precisely: the point is to stop
`bpf.progs_loaded` being left unset, because that is what trips
`reboot_on_failure`.

General web searching for the symptom mostly returns the usual GSI-bootloop
advice ("flash vbmeta to disable verification"), which is unrelated -- so the
patch set is much better evidence than the forums.

### What that means for our patch -- it was incomplete

Our first change only relaxed the `REQUIRE(4, 19, 236)` version gate. That alone
walks straight into the *second* failure:

```cpp
if (loadAllElfObjects(bpfloader_ver, location) != 0) {
    ALOGE("=== CRITICAL FAILURE LOADING BPF PROGRAMS ...");
    sleep(20);
    return 2;        // skips the "done" re-exec that sets bpf.progs_loaded=1
}
```

`bpf.progs_loaded=1` is set *only* by the `argv[1] == "done"` re-exec in `main()`.
Any early return leaves it unset, init's `bpfloader` service fails, and
`reboot_on_failure` reboots with `netbpfload-missing` -- the exact symptom we
observed. Passing the version gate would simply have moved the failure a few
lines later.

Both changes are now applied to `NetBpfLoad.cpp` (26 insertions), with the
reasoning in-comment and `NetBpfLoad.cpp.orig` kept. The reusable patcher is
`build/patches/netbpfload-nonfatal.py` (idempotent, refuses to guess if upstream
moves).

**Honest limitation:** this preserves *boot*, not *function*. BPF programs
requiring post-4.19.157 backports will not load, and the networking features
behind them are degraded. Stock Android 15 running on this kernel with Onyx's own
tethering APEX suggests most programs do load, but that is inference, not a
measurement. First real test is our own build.

## What Onyx actually does differently (measured, not inferred)

Stock Android 15 boots on this 4.19.157 kernel. Reading its *own* loader output
from a live stock boot settles why:

```
NetBpfLoad: NetBpfLoad v0.46 (/apex/com.android.tethering/bin/netbpfload) api:35/35 kver:413009d
NetBpfLoad: Tethering APEX version 352090000
NetBpfLoad: Android V requires 4.19 kernel to be 4.19.236+.
NetBpfLoad: Unsupported kernel version (413009d).
NetBpfLoad: write('/proc/sys/kernel/unprivileged_bpf_disabled','0',2) -> Invalid argument
NetBpfLoad: Loading optional ELF object .../test.o with license Apache 2.0
NetBpfLoad: BpfLoader version 0x0002e ignoring ELF object ... with max ver 0x00013
NetBpfLoad: Loading critical for Connectivity (Tethering) ELF object .../offload.o
```

Onyx does **nothing clever**. Same loader version (v0.46), same kernel, and it
prints the *identical* "Unsupported kernel version" complaint we saw fail the
GSI. The difference is that on stock it is **not fatal** -- the loader carries on
and loads what it can, skipping objects outside its version range.

Three concrete differences, all measured:

| | stock | GSI |
|---|---|---|
| Tethering APEX version | **352090000** | newer (netbpfload 102,496 B vs 78,128 B) |
| version gate outcome | warns, continues | `return 1` -> service fails |
| `trigger bpf-progs-loaded` in init.rc | **absent** | present |
| `bpf.progs_loaded` after boot | **unset** | required |

So stock tolerates BPF programs not being fully loaded: it never sets
`bpf.progs_loaded`, and its `init.rc` has no `bpf-progs-loaded` trigger to wait
on one. The newer mainline module in the GSI turned the same condition into a
hard failure, and the GSI's `init.rc` also waits for the property.

Both systems ship the same `netbpfload.rc` with
`reboot_on_failure reboot,netbpfload-missing`, and the same
`service bpfloader /system/bin/false` -- which is only overridden if the APEX
activates. That explains the *other* reboot we saw: when the stock APEX was
swapped into the GSI it presumably failed apexd verification (signed with Onyx's
key), so the service ran `/system/bin/false`, which exits **1** -- exactly the
"exited with status 1" observed. The reason string `netbpfload-missing` is
literal.

### This retro-validates the patch

Our change makes program-load failure non-fatal, which is precisely stock's
behaviour on this hardware. We are not inventing a workaround -- we are
restoring the tolerance that the older mainline module had and the newer one
removed. TrebleDroid arrived at the same place independently.

Remaining honest caveat unchanged: features backed by BPF programs that do not
load are degraded. Stock ships in exactly that state, which is a reasonable
precedent for a port of this device.

## GSI with stock's BPF tolerance: past the reboot, into a netd crashloop

Reproduced stock's tolerance in the A15 GSI with two text edits (no binary
patching), via `build/patches/gsi-bpf-tolerant.sh`:

* `/system/etc/init/netbpfload.rc` -- commented out
  `reboot_on_failure reboot,netbpfload-missing` (which is exactly what AOSP's own
  comment in that file instructs for debugging bootloops)
* `/system/etc/init/hw/init.rc` -- commented out `trigger bpf-progs-loaded`

Result: **the reboot loop is gone.** The GSI ran for over **12 minutes**
(pstore reaches 747.8s) with no reboot, where every previous attempt died at
16-20s. The blocker that killed four earlier attempts is cleared.

But the system is not usable. It sat at a blank screen because:

```
init: process with updatable components 'zygote' exited 4 times before boot completed
init: process with updatable components 'netd' exited 4 times before boot completed
init: ... 'installd' / 'gatekeeperd' / 'mediaextractor' exited 4 times ...
libprocessgroup: Failed to open /sys/fs/cgroup/uid_1041/pid_13400/cgroup.procs
```

`netd` crashloops, which takes zygote and system_server with it -- precisely what
the upstream comment in `netbpfload.rc` warns about:

> bpfloader succeeding is critical to system health, since a failure will cause
> netd crashloop and thus system server crashloop... and the only recovery is a
> full kernel reboot.

### The important distinction this draws

Suppressing the reboot is **not** the fix, and this corrects the earlier note that
the patch "preserves boot" -- boot survives, but nothing works.

* On **stock**, the loader warns about the kernel version and then **carries on and
  loads the BPF programs**. netd gets what it needs.
* On this **GSI**, the loader `return 1`s at the version gate *before loading
  anything*. Zero programs loaded -> netd cannot function.

So the programs must actually load. That is what the *first* half of our source
patch does -- relaxing `REQUIRE(4, 19, 236)` so `bad` never becomes true and the
loader proceeds to `loadAllElfObjects()`, exactly as stock's build does. The
second half (non-fatal load failure) is then a safety net for individual programs
that genuinely need newer kernel backports.

This DSU test could only exercise the init/rc half, because the gate lives in a
binary inside the APEX. Validating the binary half requires our own build --
which is the current task, and now has a concrete acceptance criterion:
**`netd` must stay up.**

## The kernel is capable: stock loads all the networking BPF programs

This is the finding that decides the port's viability, and it is measured on the
live stock system with root:

```
bpf.progs_loaded = 1          init.svc.netd = running

/sys/fs/bpf/netd_shared    30 entries   map_netd_app_uid_stats_map, map_netd_cookie_tag_map, ...
/sys/fs/bpf/netd_readonly   2 entries
/sys/fs/bpf/net_shared     11 entries
/sys/fs/bpf/tethering      21 entries   map_offload_tether_downstream4_map, ...
/sys/fs/bpf/netd_shared/mainline_done   (marker present)
```

Onyx's Android 15, tethering APEX **352090000**, on kernel **4.19.157**, loads the
complete networking BPF program set. The kernel is **not** missing the backports.

That reframes everything:

* The A15 GSI failed because its loader `return 1`s at `REQUIRE(4, 19, 236)`
  **before loading anything** -- not because the programs cannot load.
* Our patch relaxes exactly that gate, so the loader proceeds to
  `loadAllElfObjects()` on a kernel that demonstrably supports the programs.
* The earlier worry -- "features backed by programs that fail to load will be
  degraded" -- looks unfounded on this hardware. Stock is the existence proof.

### The A14 result is a separate quirk, not counter-evidence

A14 with `reboot_on_failure` disabled ran 702s and crashlooped
zygote/installd/mediaextractor the same way. Its loader has no V gate, so it did
proceed -- and still exited 1. That is a property of that particular LineageOS-
based A14 GSI, not a statement about the kernel, which stock has just disproven
as the cause. Not worth chasing: the A14 path was only ever a fallback, and the
fallback is no longer needed.

### Status of the two suppression edits

`build/patches/gsi-bpf-tolerant.sh` (now handling both GSI layouts) reliably
removes the reboot loop -- both images ran 700+ seconds instead of dying at
16-20s. But suppressing the reboot alone never produces a usable system, because
netd needs the programs. It was a diagnostic tool, not a fix.

The fix is the source patch, and it now has a clear rationale rather than a hope:
make the loader proceed, on a kernel proven to load the programs.

**Acceptance criterion for the first build, unchanged but now well-founded:**
after boot, `/sys/fs/bpf/netd_shared` should be populated and
`init.svc.netd` should read `running`.

---

# First real boot logs (our own build) -- and the linkerconfig root cause

Captured with `palma-bootlog.rc` writing `dmesg` -> `rawdump` and `logcat` ->
`logdump`, both raw partitions read back over EDL. No adb, no /data, no root, no
serial cable. 2,896 dmesg lines and 22,888 logcat lines from a failed boot.

Getting this working took two passes: triggering only `on post-fs-data` captured
nothing, because the failure happens *before* that. Moving the triggers to
`early-init`/`init` captured everything.

## The failure chain

```
E linkerconfig: Unable to access VNDK APEX at path: /apex/com.android.vndk.v30
F linkerconfig: Check failed: !"undefined var" SANITIZER_DEFAULT_VENDOR is not defined
I linkerconfig: Fatal signal 6 (SIGABRT) in BuildVendorNamespace
  -> /linkerconfig/ld.config.txt never generated
F linker: CANNOT LINK "/system/bin/keystore2":
          library "libandroidicu.so" not found: needed by libsqlite.so
  -> keystore2 never starts
   servicemanager: vold(pid 640) waiting for IKeystoreService ... every second, forever
   init: Too many pending control messages, dropped 'interface_start'
  -> /data never set up, boot stops. Blank screen, no USB, no reboot.
```

**Cause:** `device.mk` set `PRODUCT_TARGET_VNDK_VERSION := 30` (declaring the
vendor is VNDK 30, which is true -- it is Android 11) but never
`PRODUCT_EXTRA_VNDK_VERSIONS := 30`, which is what actually builds
`com.android.vndk.v30` from `prebuilts/vndk/v30` (already in the tree, unused).
`build/make/core/main.mk:1017` is where the latter turns into the APEX.

Another stale idiom inherited from the Fairphone 4 tree, same family as the
`TARGET_DEVICE` prop override and the non-existent boot HALs.

## Why "take it from stock" does not work

Stock has no VNDK APEX and does not declare `ro.vndk.version` at all -- so its
linkerconfig never looks for one and never aborts. VNDK was deprecated in
Android 15.

That suggests a second possible fix (drop the declaration, match stock), but the
log argues against it:

```
F linker: CANNOT LINK "/vendor/bin/vndservicemanager":
          cannot locate symbol "_ZNK7android8BpBinder6handleEv"
```

An Android 11 vendor binary linking against Android 15's `libbinder` and hitting
a removed symbol -- exactly the ABI break VNDK exists to prevent. So providing
VNDK 30 is likely genuinely required here, not merely a way to quiet linkerconfig.

## Other findings from the same logs

**Also broken by the missing ld.config.txt** (all downstream, not separate bugs):

| binary | missing |
|---|---|
| `/system/bin/keystore2` | `libandroidicu.so` (via libsqlite.so) |
| `/vendor/bin/qseecomd` | `libandroidicu.so` (via libxml2.so) |

**Vendor HALs missing system-side HIDL interface libraries** -- may or may not be
resolved by VNDK 30; A15 dropped many HIDL libs. Neither is boot-critical:

```
vendor.qti.esepowermanager@1.1-service  -> vendor.qti.esepowermanager@1.1-impl.so
vendor.qti.secure_element@1.2-service   -> android.hardware.secure_element@1.0.so
```

**SELinux denials while permissive** -- the policy TODO for going enforcing later.
Short and unremarkable:

```
4x  fsck -> block_device (blk_file)
1x  vendor_init -> build_prop / default_prop (property_service)
1x  vendor_init -> persist_debug_prop (file)
1x  linkerconfig -> self (capability)
1x  init -> debugfs_tracing_debug (dir)
1x  hal_bootctl_default -> gsi_metadata_file (dir)
1x  vdc -> self (capability)
```

**Hardware, kernel side, all healthy** (these come from the stock kernel+DTB we
ship unmodified, so they occur on stock too):

* E-ink power: **`tps6518x-pmic`** -- a TI TPS6518x, the standard e-ink display
  PMIC, on I2C next to `mxo 1-0040`. Its warnings (`no epdc pmic v3p3 pin
  available`, `no ... pwrgood_second`, `no ... intr pin`, `panelvdd not found,
  using dummy regulator`) are board configuration, not failures.
* Onyx kernel surface: `onyxdsi` display module, `onyx_pinctrl`, `onyx-vsys`
  regulator, `onyx_power_off` / `onyx_shutdown_type` in the PMIC restart path.
* Radios init fine: `wlan_fw_region` and `modem_region` reserved, MSS assigned,
  IPA/SMMU linked for WLAN, `Bluetooth: Core ver 2.22`. Their userspace HALs
  never started, but nothing indicates a kernel-side problem.
