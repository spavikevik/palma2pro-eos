# AOSP tree patches

Changes to the AOSP source tree, which lives on the builder at `/aosp` and is
**not** part of this repository. Without these files those edits exist only on
that one machine.

Apply from the root of each AOSP project:

```sh
cd /aosp/system/core        && git apply /path/to/patches/main/0001-*.patch
cd /aosp/frameworks/native  && git apply /path/to/patches/onyx-sf/000{1,2,3}-*.patch
cd /aosp/packages/modules/adb && git apply /path/to/patches/onyx-sf/0004-*.patch
```

Regenerate after further edits with `git diff -- <file>` in the relevant project.

## `main/` -- belongs on the main line

| patch | what | why |
|---|---|---|
| `0001-system-core-ueventd-dev-ebc-0666.patch` | `/dev/ebc 0666` ueventd rule | SurfaceFlinger opens `/dev/ebc` directly to drive the EPD. The driver leaves it `0600 root:root`, so SF (uid `system`) cannot open it and reports `hasHwTcon: 0`. **TODO**: tighten to `0660 root system` once bring-up no longer needs to probe it from an adb shell. |

## `onyx-sf/` -- branch only, do NOT apply to main

These exist to run Onyx's proprietary SurfaceFlinger. See
`docs/12-onyx-sf-branch.md`.

| patch | what | why |
|---|---|---|
| `0001-libgui-move-getMaxLayerPictureProfiles-last.patch` | move one AIDL method to the end of `ISurfaceComposer.aidl` | AIDL assigns transaction codes by declaration order. This method sits at code 25 in our build and does not exist in Onyx's, shifting the 45 methods after it by +1 -- our `getCompositionPreference` (34) invoked their `getDisplayedContentSamplingAttributes` (33). Surfaced as `SurfaceControl.getCompositionColorSpaces()` returning null and killing `system_server`. Verify with `scripts/aidl-txn-codes.py <built libgui.so> firmware/stock-extract/lib64/libgui.so`, which must print `ALIGNED`. |
| `0002-libgui-adaptive-216-224-display-events.patch` | accept both 216- and 224-byte `DisplayEventReceiver::Event` | Their `libgui` sends 216 (`sendEvents`: `mov w3,#0xd8`), ours 224 (`#0xe0`). Both dialects are genuinely on the wire **per connection, even within one process** -- so no fixed size works. Reads with an 8-byte granule (8 divides both, so `BitTube`'s modulo assert cannot fire) then demuxes on datagram size. The only structural difference is our `numberQueuedBuffers` (4 bytes + 4 padding); confirmed from their binary, where `VsyncEventData::preferredVsyncId()` loads `frameTimelines` from `[x8,#0x10]` versus our `[x8,#0x18]`. |
| `0003-surfaceflinger-rc-run-onyx-sf.patch` | start `surfaceflinger_onyx` with `LD_LIBRARY_PATH`, `LD_PRELOAD` and a `setprop` | Their binary needs their own 129-lib closure, which cannot be mixed with ours, so it lives in `/system/lib64/onyxsf`. `vendor.display.use_smooth_motion=0` must be set from `on init` -- via `PRODUCT_SYSTEM_PROPERTIES` it lands in `/system/build.prop` and Onyx's `/vendor/build.prop` overrides it, and their SF then SIGSEGVs in `qtiCreateSmomoInstance`. `LD_PRELOAD` attaches the read-only ioctl tracer. |
| `0004-adbd-honour-debuggable-for-adb-root.patch` | let `adb root` work | **Security-relevant.** /e/OS gates adbd's root restart behind an `adbroot` binder service which reports disabled to adbd even when it answers `getEnabled()==true` directly. Forces `enabled` on debuggable builds -- already AOSP's own condition for permitting `adb root`. Branch only; do not ship. |

## Not captured here

Device-local changes that are not source patches and will not survive a reflash
of the partition they live in:

* `/vendor/etc/fstab.default` -- 7-byte `dirsync` -> `noatime` patch
  (`docs/09-vendor-fstab-patch.md`); undo image in `firmware/analysis/`
* `ro.adb.secure=0` in both `system_b` and `vendor_b` build.prop (task #10);
  vendor's copy is the one that wins
* the Onyx prebuilts themselves (`surfaceflinger_onyx` + 129 libs), which are
  proprietary and deliberately gitignored -- see `scripts/onyx-sf/README.md`
  for how to re-stage them
