# Branch `onyx-sf`: ship Onyx's SurfaceFlinger as prebuilts

Goal: a **usable** device now, and a live reference implementation to study
while we work out how to drive the EPD from our own SurfaceFlinger.

This branch is deliberately not a candidate for `main`. See "Licensing" below.

## What already works (established on-device, not theory)

Onyx's SF runs on our Android 15 build and gets all the way to serving clients:

* it links and starts, given its library closure;
* it registers `SurfaceFlinger` **and** `SurfaceFlingerAIDL`;
* `bootanimation` starts against it;
* the kernel's EPDC plane hook stops rejecting commits -- **0 errors, versus 363
  and climbing under our SF**.

Three things were required to get there, all found the hard way:

1. **The library closure: 130 libs.** Its 56 `DT_NEEDED` plus everything they
   pull in transitively, extracted from the stock `system`/`system_ext` with
   `debugfs`. Partial sets fail in both directions -- their SF needs their
   `libgui` (`android::JankData` vtable), while our `libcamera_client`/`libmedia`
   need ours.
2. **Except the binder libraries.** Onyx's `libbinder.so` / `libbinder_ndk.so`
   speak a different `IServiceManager` AIDL revision than our servicemanager, so
   every `addService` fails *silently* -- SF ignores the return value, and the
   only symptom is `isDeclared ... EX_TRANSACTION_FAILED 'BAD_TYPE'`. They must
   come from the system. This single detail is the difference between "registers"
   and "does not".
3. **Two properties**, or it SIGSEGVs:
   * `vendor.display.use_smooth_motion=0` -- else `qtiCreateSmomoInstance`
   * `debug.sf.prime_shader_cache.*=0` -- else Skia shadow-layer priming

Bionic (`libc`, `libdl`, `libm`, `libc++`) and the ICU libs must come from the
device's APEXes, never from the stock dump.

## The blocker to solve on this branch

`system_server` dies immediately after SF registers:

```
java.lang.NullPointerException: Attempt to get length of null array
    at android.view.SurfaceControl.getCompositionColorSpaces(SurfaceControl.java:2589)
    at com.android.server.display.DisplayManagerService.<init>(DisplayManagerService.java:660)
*** FATAL EXCEPTION IN SYSTEM PROCESS
```

The framework talks to SF over the wire format defined by `libgui`. Our
`system_server` uses ours, their SF uses theirs, and the two disagree. Swapping
our `libgui` for theirs is **not** an option: ours exports 215 symbols theirs
lacks (`setLuts`, `setPictureProfileHandle`, `setEdgeExtensionEffect`,
`setBufferReleaseChannel`, `getMaxLayerPictureProfiles`, ...) and our
`libandroid_runtime` is linked against them.

So the approach here is **patch our framework to tolerate the gaps**, one failure
at a time:

* start with `SurfaceControl.getCompositionColorSpaces()` returning null ->
  fall back to a sane default in `DisplayManagerService` rather than throwing;
* boot, find the next failure, repeat.

**This is open-ended.** It might be three methods or thirty; the two libgui
builds differ by 353 symbols in total, though most of those are not on the
framework's hot path. The first two or three iterations will show whether the
tail is short. If `system_server` gets through `DisplayManagerService` and into
`WindowManagerService` without new failures, it is probably short.

## Build integration

* prebuilt `surfaceflinger` binary + the 130-lib closure minus the binder libs,
  as `PRODUCT_PACKAGES` prebuilts landing in `/system`;
* the two properties via `PRODUCT_SYSTEM_PROPERTIES`;
* framework patches as source changes under `frameworks/base` on the builder.

Note the launcher-script trick used during investigation (a shell script at
`/system/bin/surfaceflinger` exec'ing the real binary from `/data`) was a
bring-up expedient only -- on this branch the binary should be installed
properly so it survives a `/data` wipe.

## Licensing -- READ BEFORE COMMITTING ANYTHING

`surfaceflinger`, `libgui`, `libpenguin.so`, `libdolphin.so` and the QTI display
libraries are **proprietary Onyx/Qualcomm binaries**. They are extracted from the
device the user owns, which is fine for that device, and they are **not
redistributable**.

* `.gitignore` already excludes `firmware/`, so nothing extracted there is
  tracked today. Keep it that way.
* Do **not** add the blobs under `device/onyx/Palma2_Pro_C/` where they would be
  tracked. Reference them from an ignored path, or add an explicit ignore rule
  before importing anything.
* This branch must never be merged to `main` or published as a flashable ROM.
  Its value is a working device for its owner, and a reference to study.

The redistributable outcome remains the `main` line: our own EPD implementation,
for which `docs/11-epd-update-path.md` records everything recovered so far.
