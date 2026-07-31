# Task: per-layer damage for the e-ink panel

**Goal.** Make a change to one small part of the screen refresh only that part of
the panel, instead of all 1648x824 pixels.

Everything downstream of you already works. There is exactly one function to
change. This document is deliberately light on answers -- it tells you what to
read and what to ask, not what to type.

---

## 1. Why this matters here

E-ink is not a raster display you scan out continuously. To change a pixel you
run a *waveform*: a sequence of voltage frames that drags the particles from
their old state to the new one. That takes hundreds of milliseconds and it is
visible. The cost is proportional to the **area** you refresh, not to how much
of that area actually changed.

So a display that repaints everything on every frame is not merely inefficient,
it is unusable: slow, flashing, and it accumulates ghosting across the whole
panel rather than in one corner.

Concretely, on this device right now: the Clock icon on the home screen is drawn
as a live analog clock. Its second hand sweeps through about **30x50 pixels**
once a second. Each of those ticks currently repaints **the entire panel**.

Your job is to close that gap.

---

## 2. The pipeline, end to end

```
  app draws
      |
      v
  SurfaceFlinger composites layers into one output
      |
      |   <-- YOU ARE HERE: which rectangles actually changed?
      v
  /dev/epdc/damage      shared mapping, seqlock (src/epdc_damage.h)
      |
      v
  libepdcshim.so        LD_PRELOAD in the composer (src/epdcshim.c)
      |
      v
  DRM plane properties  EPDC_UPDATE_PARMS_ADDR + EPDC_UPDATE_CNT
      |
      v
  kernel                refreshes up to 8 rectangles per commit
```

Read `docs/11-epd-update-path.md` for how the lower half was worked out. You do
not need to change any of it. If you find yourself editing the shim, stop and
re-read this diagram -- the problem is upstream of it.

---

## 3. Where you are working

**File.** On the builder:
`/aosp/frameworks/native/services/surfaceflinger/CompositionEngine/src/Output.cpp`

**Function.** `collectEpdcDamage(const Output&)`, marked with a `TASK` banner.
It currently returns:

```cpp
outputState.transform.transform(output.getDirtyRegion())
```

That is correct -- it just answers a coarser question than you want.

**The contract you must honour** (everything else is free):

* return the region in **output space**, not layer stack space (see section 6)
* returning too much is slow but safe; returning too little leaves **stale
  pixels on the panel**, which is the failure mode to fear
* the region is merged down to 8 rectangles downstream, so returning 200 tiny
  rectangles gains you nothing over returning their bounds

---

## 4. What to read, in order

Read these before writing anything. They are the mental model.

1. **`Region`** -- `frameworks/native/libs/ui/include/ui/Region.h`.
   A region is a set of rectangles, not one rectangle. Look at what algebra it
   offers: `orSelf`, `andSelf`, `subtractSelf`, `translate`, `getBounds`, and how
   you iterate it. Note `getBounds()` returns the *bounding box* -- the smallest
   rectangle containing everything, which is usually much larger than the union.

2. **`Output`** -- `CompositionEngine/include/compositionengine/Output.h`, and
   the state in `impl/OutputCompositionState.h`. You already use
   `getDirtyRegion()`. Find out **where `dirtyRegion` is written**, and what
   contributes to it. That is the single most useful thing you can learn here:
   it explains why the answer is always the whole screen.

3. **`OutputLayer`** -- `include/compositionengine/OutputLayer.h` and
   `impl/OutputLayerCompositionState.h`. Each layer on an output has its own
   composition state. Look for fields describing *what changed in this layer's
   buffer* as opposed to *where this layer is*.

4. **`LayerFECompositionState`** -- `include/compositionengine/LayerFECompositionState.h`.
   This is the layer's own view of itself, handed up from the client. Look for a
   field with "damage" in the name and work out **what coordinate space it is
   in**. This is the field the whole task turns on.

5. **How to walk the layers of an output.** Look for `getOutputLayerCount()` /
   `getOutputLayerOrderedByZ()` on `Output`. There is an idiomatic loop used all
   over `Output.cpp` -- copy its shape.

---

## 5. Questions to answer before you code

Write down your answers. If you cannot answer one, you are not ready to write
the code for it.

1. What is the difference between a layer's **surface damage** and the output's
   **dirty region**? Which one grows when a window merely *moves*, and which
   grows when its *contents* change?
2. Why is the output dirty region full-screen on this device almost every frame?
   (Hint to look, not the answer: what does a wallpaper or a full-screen app
   window contribute when it redraws?)
3. If a layer supplies **no** damage information, what must you assume about it,
   and why is the safe assumption the expensive one?
4. A layer moves from x=100 to x=300 without redrawing its contents. Its surface
   damage is empty. What does the panel need refreshed, and where does that
   information come from?
5. A layer is destroyed, or becomes hidden. Its damage is gone with it. What
   needs to be refreshed, and how would you even know?

Questions 4 and 5 are where naive implementations break. They are the reason
"just union the surface damage" is not the whole answer.

---

## 6. The coordinate-space trap

This device will punish you here specifically.

* the framework thinks in **layer stack space**: 824x1648, portrait
* the panel is installed rotated, so the kernel blits in **output space**:
  1648x824, landscape
* `outputState.transform` converts between them

A rectangle published in the wrong space still *looks* like a plausible
rectangle. It is the right shape and the right size. It simply refreshes the
wrong part of the screen, and because the aspect ratio is swapped, the error
looks like a mysterious offset rather than an obvious bug.

Per-layer damage is in the layer's own space, which is **not** the same as the
output's. Work out the full chain of transforms from "the app's buffer" to "the
panel", and check each hop. Do not assume any hop is the identity.

---

## 7. How to verify -- do not trust your eyes alone

There is already instrumentation in `publishEpdcDamage`, rate-limited to one in
30 frames:

```
I CompositionEngine: epdc: raw rects=1 bounds=[0 0 1648 824]
```

Watch it with `adb logcat -s CompositionEngine`. Your target is that touching a
small thing produces small bounds. **Baseline to beat:** the Clock second hand
should stop producing `[0 0 1648 824]`.

Then measure, do not guess:

```sh
# how many EPD refreshes actually happened, from the driver's own log
adb shell 'dmesg | grep -c waveform_clean_work_handler'

# what got published, live
adb shell 'od -A n -t d4 -j 8 -N 40 /dev/epdc/damage'
#            ^ skips magic+version; prints seq, count, full, then rect[0]
```

And the honest test: put a static image on screen, leave it for a minute, and
look for regions that never got repainted. Stale pixels are the bug this task
can introduce, and they are invisible in logs.

---

## 8. Build and deploy loop

```sh
scripts/builder.sh build surfaceflinger      # ~50 s once the tree is warm
scripts/builder.sh logs                      # watch it
```

Then pull the binary and push it (the long base64 hop is because there is no
scp on the builder wrapper):

```sh
scripts/builder.sh ssh 'base64 -w0 /aosp/out/target/product/Palma2_Pro_C/system/bin/surfaceflinger' \
  | base64 -d > /tmp/sf.new
adb remount && adb push /tmp/sf.new /system/bin/surfaceflinger
adb shell 'chmod 755 /system/bin/surfaceflinger; chown root:shell /system/bin/surfaceflinger'
adb shell 'setprop ctl.restart surfaceflinger'
```

**After every SurfaceFlinger restart**, client composition must be re-applied or
the nav bar and status bar vanish (they are separate planes, and the kernel
drops any plane smaller than the panel):

```sh
adb shell 'service call SurfaceFlinger 1008 i32 1'
```

`system/etc/init/epdc-clientcomp.rc` does this automatically on boot, with an
8 second delay -- so on a reboot just wait rather than panicking.

If you brick the display, nothing is lost: `adb` still works, and
`/data/local/tmp/surfaceflinger.prev` is the last known-good binary.

---

## 9. Stuck? Escalating hints

Read these one at a time, and only after genuinely trying.

<details><summary>Hint 1 -- you cannot find any per-layer damage field</summary>

Search `frameworks/native/services/surfaceflinger` for `surfaceDamage`. Then
find every place it is assigned, and notice which of those places is on the
per-frame path versus the geometry path.
</details>

<details><summary>Hint 2 -- your rectangles are in the wrong place</summary>

There is more than one transform involved. A layer has its own transform onto
the output, and the output has a transform onto the display. Print both and the
region at each stage; do not reason about it in your head.
</details>

<details><summary>Hint 3 -- some things never refresh (stale pixels)</summary>

Revisit questions 4 and 5. Anything that changes *which pixels a layer covers*,
rather than *what the layer contains*, produces no surface damage at all. You
need the union of the old and new coverage. Where would you get "old"?
</details>

<details><summary>Hint 4 -- it works but is barely faster</summary>

Check what fraction of frames still return full-screen, and which layer is
responsible. One layer that always reports full damage poisons the union for
every frame. Instrument per layer, by name.
</details>

---

## 10. Done means

* the Clock second hand refreshes roughly its own icon, not the panel
* scrolling and typing are visibly quicker than today
* leaving the device on a static screen for a minute leaves **no** stale regions
* `epdc: raw` bounds are small for small changes, full-screen only when
  something genuinely large changed

When it works, delete the instrumentation block in `publishEpdcDamage` (it is
marked "temporary instrumentation") and regenerate the patch:

```sh
scripts/builder.sh ssh 'cd /aosp/frameworks/native && git diff -- \
  services/surfaceflinger/CompositionEngine/src/Output.cpp' \
  > patches/main/0002-frameworks-native-surfaceflinger-publish-epd-damage.patch
```
