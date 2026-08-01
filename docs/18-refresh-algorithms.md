# E-ink refresh algorithms: what other open projects do

Research for the refresh policy in `src/epdcshim.c` and the per-layer damage
work (`docs/15`). Everything here is from projects whose source is public;
`docs/13` covers the hardware/ecosystem side, this covers the *algorithms*.

The single fact that drives every design below: **refresh cost is proportional
to the area updated and to the waveform's frame count, not to how much of the
content actually changed.** Every project converges on the same three levers:

1. update the smallest region you can
2. pick the cheapest waveform that is good enough for *this* content
3. periodically pay for a full flash to clear the debt the cheap ones accumulate

---

## 1. Waveform vocabulary, and when each is right

The most useful single reference is FBInk's `fbink.h`, which documents the i.MX
EPDC modes with timings and caveats. Reproduced here because it is the clearest
statement of intent anywhere, and the mode *names* are shared across Kobo,
Kindle, reMarkable, Rockchip and our Onyx panel.

| mode | cost | fidelity | use for |
|---|---|---|---|
| `A2` | ~120 ms | B&W only, never flashes | keyboards, animation, pen tracing. Needs "bracketing with white screens" for clean transitions |
| `DU` | ~260 ms | any -> B&W, light ghosting, never flashes | UI highlights, touch tracking. Leaves non-B&W pixels untouched |
| `GC4` / `DU4` | ~290 ms | 4 levels, ghosting | cheap middle ground |
| `GL16` | ~450 ms | 16 levels, some ghosting | "typically optimized for text on a white background" |
| `REAGL`/`REGAL` | ~450 ms | 16 levels, reduced ghosting *and* flashing | "when available, best option for text (in place of GL16)" |
| `GC16` | ~450 ms | 16 levels, clean | images, and the periodic clearing flash |
| `AUTO` | varies | driver decides | EPDC picks by **histogram analysis of the refresh region** |

Two things worth stealing directly:

* **`AUTO` exists because content classification is genuinely hard.** The i.MX
  EPDC does a histogram of the region and picks GC16 if it sees real greyscale.
  Our panel exposes `EPD_AUTO` as logical mode 0 (`docs/03`), and we have never
  tried it. That is a cheap experiment with a real chance of beating any
  hand-written heuristic.
* **"Flashing" and "full" are different axes.** A flashing update repaints every
  pixel in the region including unchanged ones; a partial update only drives
  changed pixels. Our `update_mode` field is exactly this axis, which is why
  `upd 0` stopped the constant flashing while `wf 2` (GC16) stayed.

Sources: [FBInk `fbink.h`](https://raw.githubusercontent.com/NiLuJe/FBInk/master/fbink.h),
[libremarkable framebuffer wiki](https://github.com/canselcik/libremarkable/wiki/Framebuffer-Overview).

---

## 2. KOReader: classify every update by intent

KOReader is the most directly transferable design, because like us it is a
*compositor-side* policy sitting above a dumb "rect + mode" kernel API. It does
not try to analyse content. Instead **every UI element declares what kind of
update it is**, via `UIManager:setDirty(widget, refresh_type, region)`.

Its refresh types, from its own comments:

| type | meaning |
|---|---|
| `full` | high fidelity flashing (large images). Highest quality, highest latency. "Avoid abusing it if you only want a flash" |
| `partial` | medium fidelity (text on white). **Promoted to flashing after `FULL_REFRESH_COUNT` refreshes** |
| `ui` | medium fidelity, mixed content. "Should apply to most UI elements. When in doubt, use this" |
| `fast` | low fidelity, monochrome. Highlights, inversion effects |
| `a2` | lowest fidelity, B&W->B&W only. "Should be limited to very specific use-cases (e.g. keyboard)" |
| `flashui` / `flashpartial` | flashing variants, used when *showing or closing* a UI element, to pre-empt ghosting |
| `[ui]` / `[partial]` | bracketed = **do not merge** this update with its neighbours |

Four ideas here we do not have:

1. **Intent beats inspection.** The producer knows whether it drew a keyboard or
   a photo; the compositor does not. This maps onto our per-layer damage work:
   the layer, not the shim, is the right place to attach a mode hint.
2. **Automatic promotion.** A counter of partial refreshes, promoted to a flash
   at a threshold. Kobo's user-facing setting is literally "full refresh every N
   pages" (`DRCOUNTMAX`, default 6). Our `persist.epdcshim.fullevery` is the same
   idea, arrived at independently.
3. **Flash on appear/disappear.** Ghosting is worst where a window was and no
   longer is. KOReader deliberately spends a flash when a dialog opens or closes
   rather than waiting for the promotion counter.
4. **An explicit no-merge flag.** Sometimes merging two updates into their union
   is worse than doing two updates, and only the caller knows.

KOReader also merges queued dirty regions into "minimal refresh rectangles" at
paint time, which is exactly the 8-rect budget problem we have.

Sources: [KOReader `uimanager.lua`](https://github.com/koreader/koreader/blob/master/frontend/ui/uimanager.lua),
[refresh-rate issue thread](https://github.com/koreader/koreader/issues/12218).

---

## 3. Rockchip EBC / PineNote: the driver-side view

Samuel Holland's `drm/rockchip: ebc` RFC series is the closest open analogue to
our kernel path, and the PineNote is the closest open analogue to our hardware
(software-computed waveforms driving a TCON, same as
`CONFIG_FB_ONYX_SOFTWARE_EPDC`).

Relevant mechanics:

* **A refresh thread decoupled from the frame path.** Atomic commits do not
  block on the panel; the driver fakes vblank and lets a worker drive the
  waveform. Our shim rides the commit thread, which is fine only because the
  kernel submit is asynchronous.
* **Per-pixel waveform state across frames.** A helper library tracks where each
  pixel is in its waveform, because a transition takes many frames and the
  content may change mid-flight.
* **"Diff mode".** A hardware option, *enabled by default*, to send zero drive
  for pixels whose value did not change, instead of consulting the LUT. This
  exists specifically because "some waveforms, such as GC16, cause the display
  to flash even when the previous and next pixel values are the same. This can
  be helpful, because it produces more consistent brightness, but usually it is
  more distracting." That is the same trade-off as our `update_mode`.

Sources: [LWN: Rockchip EBC driver](https://lwn.net/Articles/891304/),
[diff mode patch](https://patchwork.kernel.org/project/dri-devel/patch/20220413221916.50995-12-samuel@sholland.org/),
[RK3566 EBC reverse-engineering](https://wiki.pine64.org/wiki/RK3566_EBC_Reverse-Engineering).

---

## 4. Modos Caster: the most advanced open algorithm

Caster is an open FPGA controller (Glider / Modos Paper Monitor). It is worth
studying because it does in gateware what we would have to approximate in
policy, and it shows what "good" looks like:

* **Per-pixel mode switching.** It treats "every pixel as an individual update
  region", holding 16 bits of state per pixel: two sets of old values plus
  per-pixel timers. There are no update *regions* at all in the usual sense.
* **Hybrid automatic binary/greyscale.** Content that is changing is driven in
  fast binary mode; once it stops changing, the same pixels are re-rendered in
  16-level greyscale. The user gets responsiveness while moving and quality when
  still, with no mode selection anywhere.
* **Automatic motion detection.** It "automatically switches to a faster black
  and white mode during scrolling, then back to a slower grayscale mode when
  scrolling has stopped."
* **Early cancellation.** If a pixel's target changes mid-transition, it is
  re-aimed at the new value instead of finishing the old one.
* **Dithering in the pipeline.** Bayer, blue-noise and error-diffusion, applied
  when reducing to 1-bit or 4-bit, at no latency cost.

The hybrid settle idea is the most valuable thing in this document and is
implementable in our shim without any kernel change: **use a fast waveform while
frames keep arriving, and when they stop, re-submit the same region once in
GC16.** Our `fastwf`/`fastms` knobs are half of it; the missing half is the
settle pass.

Sources: [Modos-Labs/Glider](https://github.com/Modos-Labs/Glider),
[Modos Paper Monitor](https://www.crowdsupply.com/modos-tech/modos-paper-monitor),
[CNX Software writeup](https://www.cnx-software.com/2025/08/06/fpga-modos-paper-dev-kit-supports-e-ink-displays-75-hz-refresh-rate/).

---

## 5. What this means for us, concretely

Ordered by value against effort, given where `epdcshim` and the damage work are.

**a. Try `EPD_AUTO` (logical mode 0).** One `setprop`. The driver may already do
histogram-style selection better than our fixed `wf 2`. Untested and free.

**b. Settle pass (Caster's hybrid, KOReader's promotion).** While updates keep
arriving within `fastms`, submit a cheap waveform; when the stream stops, submit
the last region once more in GC16. This is strictly better than the current
`fullevery` counter, which fires on a count regardless of whether the screen is
busy or idle — the worst case being a flash *during* scrolling.

**c. Per-rect modes.** The kernel array is 8 *independent* update structs, each
with its own `waveform_mode`. We currently write one mode into all of them. A
keyboard region could go A2 while a text region goes GL16 in the same commit.

**d. Mode hints from the layer, not the shim.** Once per-layer damage lands
(`docs/15`), the natural extension is a per-layer mode hint carried alongside the
rectangle — KOReader's core insight that intent beats inspection. The IME is
always `a2`; a photo viewer is always `full`; the status bar is `fast`.

**e. Flash on window appear/disappear.** Cheap to detect at the SF layer
(a layer added or removed), and it is where ghosting is worst.

**f. Temperature.** Our update struct has a `temp` field which we always send as
0, and the driver exposes `onyx_epdc_fb_get_temp_index`. Waveforms are
temperature-indexed; a wrong index means wrong voltages and visible artefacts.
Worth checking whether 0 means "driver decides" or literally 0 degrees.

**g. Update collisions.** EPD controllers have a limited number of concurrent
LUT slots, and overlapping in-flight updates to the same pixels conflict. Our
driver has `update_marker` and `onyx_epdc_marker_release_wait`, so it can be
tracked. We currently fire and forget. Kobo/Kindle userspace waits on a marker
after a flashing update specifically so the next update is not corrupted by it.

**h. Dithering.** The panel is 16-level greyscale being fed from a 32-bit
composited buffer. Whoever reduces it is choosing a dithering algorithm by
default. Caster gets visibly better results with blue-noise/error-diffusion than
naive quantisation. We have not looked at what our path does at all.
