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

## MEASURED: the interfaces are 5 methods apart, and the shift is +1 from code 25

`ISurfaceComposer` is `_ZN7android3gui17BpSurfaceComposer...` (note
`BpSurfaceComposerClient` is a *different* interface -- filter on the `17` length
prefix or its entries pollute the map):

```
OURS: 75 methods      ONYX: 70 methods
```

Each `Bp` method loads its transaction code as an immediate into `w1` before
`transact()`, so the code -> method map is recoverable by disassembly. Diffing
the two maps shows the interfaces are identical up to code 24, then ours gains
one method and everything after shifts by exactly +1:

```
code 25   ours=getMaxLayerPictureProfiles     onyx=captureDisplay
code 26   ours=captureDisplay                 onyx=captureDisplayById
code 27   ours=captureDisplayById             onyx=captureLayersSync
code 28   ours=captureLayersSync              onyx=captureLayers
code 29   ours=captureLayers                  onyx=clearAnimationFrameStats
code 33   ours=onPullAtom                     onyx=getCompositionPreference
code 34   ours=getCompositionPreference       onyx=getDisplayedContentSamplingAttributes
```

So when our framework calls e.g. `getCompositionPreference` (code 34), their SF
executes `getDisplayedContentSamplingAttributes` instead. That is exactly the
class of failure behind
`SurfaceControl.getCompositionColorSpaces()` returning null and killing
`system_server` -- the wrong method runs and the reply does not parse.

**The fix is to move our extra methods to the END of
`frameworks/native/libs/gui/aidl/android/gui/ISurfaceComposer.aidl`**, so the
shared prefix keeps identical codes and only our newer additions occupy codes
beyond theirs. Calls into those extras then fail cleanly with an unknown
transaction rather than silently invoking the wrong method.

### RESULT: exactly one method needs moving

Walking both maps in code order and accounting for our extras:

```
OURS 75 codes   ONYX 70 codes   (extra = 5)

insertion points (ours-only, mid-interface): 1
    code 25: getMaxLayerPictureProfiles

remaining mismatches after that insertion: 0
```

Of the five methods we have and they do not, **four are appended past the end of
their interface** -- harmless, since their SF is never asked for those codes --
and exactly **one**, `getMaxLayerPictureProfiles`, sits at code 25 and shifts the
45 methods after it by +1.

So the entire wire incompatibility is one misplaced declaration. Moving
`getMaxLayerPictureProfiles` to the end of

    frameworks/native/libs/gui/aidl/android/gui/ISurfaceComposer.aidl

makes all 70 shared codes line up exactly. Re-run the diff afterwards to confirm
it reports 0 insertion points.

Method to reproduce the measurement: for each `_ZN7android3gui17BpSurfaceComposer*`
FUNC symbol, disassemble its body and take the last `mov w1, #imm` with
`0 < imm < 300` -- that is the transaction code handed to `transact()`. Filter on
the `17` mangled length prefix; `BpSurfaceComposerClient` (`23`) is a different
interface and pollutes the map otherwise.

Caveat: aligning codes fixes *dispatch*. It does not guarantee *payload*
compatibility -- if a shared method's parameter or return struct changed shape
between the two AOSP revisions, that method still misbehaves. Expect to check
the ones the framework calls early during boot.

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
