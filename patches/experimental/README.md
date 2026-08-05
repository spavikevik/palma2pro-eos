# Abandoned approaches, kept for reference

Nothing here is applied to a build. These are changes that were made in the AOSP
tree, did not work out, and were reverted -- exported first so the reasoning
survives the revert.

They are separate from `patches/main/` precisely so nobody applies them by
accident: `patches/main/` is the build recipe, this directory is a notebook.

## `onyx-sf-abi-shims.patch`

The "onyx-sf branch": run **Onyx's stock SurfaceFlinger** instead of building our
own, on the theory that their binary already knows how to drive the panel.

It got far enough to be instructive. `surfaceflinger.rc` points the service at
`/system/bin/surfaceflinger_onyx` with its own library closure under
`/system/lib64/onyxsf`, and the AIDL change documents a genuinely subtle failure:
AIDL assigns transaction codes **by declaration order**, so a method that exists
in our `ISurfaceComposer` but not in Onyx's shifted the 45 methods after it by
one. Our `getCompositionPreference` (34) then invoked their
`getDisplayedContentSamplingAttributes` (33), which surfaced as
`SurfaceControl.getCompositionColorSpaces() == null` taking down system_server.
Moving the method to the end of the interface realigned all 70 shared codes.

Abandoned because the approach we shipped -- our own SurfaceFlinger plus the
`LD_PRELOAD` composer shim -- works and does not require tracking a vendor
binary's ABI. See `docs/12`.

**This patch is dangerous to apply casually**: it points the service at a binary
that only exists if the rest of that branch is built too, so a tree carrying it
produces an image that does not boot. It was found still applied in the builder's
tree and reverted before the first build that included the screensaver.

## `systemui-screensaver-attempts.patch`

Three attempts at the lock screensaver from inside SystemUI, plus the string
resource for a Quick Settings warmth tile.

All three failed for one reason: **nothing composites at lock time**. Adding a
full-screen window did not help because `mScreenState` is already `OFF`; a
wakelock with `ACQUIRE_CAUSES_WAKEUP` cancelled the sleep it was meant to survive;
and the binder thread that receives `onStartedGoingToSleep()` has no Looper, so
`addView()` had to be posted to the UI thread, by which point the display was
gone.

Superseded by `device/onyx/Palma2_Pro_C/epdc-screensaver/`, which does not
involve the compositor at all and works with the display already asleep. See
`docs/22` section 9.4.

The warmth tile is here because it crashed SystemUI on startup -- a Dagger
`IllegalStateException: End size 0 is less than fixed size 1`, from registering
in the legacy QS registry but not the newer `qs.tiles.base` pipeline. The
frontlight warmth itself works and is driven by `patches/main/0006`; only the
tile is missing.
