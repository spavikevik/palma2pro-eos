# How this port happened, and what the method was

The other documents describe the device as it is now. This one describes how we
got there — including the routes that failed, because most of the useful
knowledge came from those, and because someone repeating this work should know
which walls are real.

Written in broad strokes. Each phase points at the document with the detail.

---

## Phase 0 — the goal

Get off Onyx's stock firmware and its telemetry, onto /e/OS, on a Boox Palma 2
Pro. An e-reader is a good candidate for this: the hardware is decent, the
software is the objection.

The single most useful fact was found in the first hour: **SM7225 is also the
Fairphone 4's SoC**. Fairphone is GPL-compliant and publishes sources; that
coincidence made unlocking possible and gave us a reference kernel.

## Phase 1 — recon and a way back

Before touching anything: enumerate partitions, confirm EDL (Qualcomm 9008) is
reachable, take a **full backup of every partition**, and then *prove the restore
path by actually restoring one*. A backup you have never restored from is not a
backup.

That discipline paid off repeatedly. Nothing in this project was ever
unrecoverable.

→ `docs/01-recon.md`, `scripts/edl-backup.sh`, `scripts/edl-verify-restore.sh`

## Phase 2 — unlocking

Onyx ships an ABL with the unlock commands stripped. The workaround — published
by others, not us — is to temporarily run the **Fairphone 4's ABL**, which is
signed for the same SoC and still has them.

Where we diverged: the published procedure ends with `fastboot flashing unlock`,
which needs an on-screen confirmation. **This panel cannot display it** — the
bootloader draws to a DSI framebuffer that does not exist here, so the screen
stays blank and the prompt is unanswerable. We finished host-side instead,
writing `is_unlocked` / `is_unlock_critical` into `devinfo` over EDL.

That was the first instance of a theme that ran through the whole project: *on
this device, anything that expects you to look at the screen is unavailable
until the screen works, and the screen is the last thing to work.*

→ `docs/02-unlock.md`, credits in `THIRD_PARTY.md`

## Phase 3 — the GSI attempt, and why it died

The obvious first move: flash a prebuilt /e/OS GSI. It failed, and understanding
*why* reshaped the project.

* Onyx's fastbootd rejects `flash` outright, so images had to go in over EDL,
  written into a logical partition's extents by hand.
* The vendor BSP is **Android 11 (VNDK 30)** under an Android 15 system. /e/OS
  ships no A13 and no vndklite variant.
* A `netbpfload` failure put the device in a reboot loop; suppressing it stopped
  the loop but never produced a usable system.
* The decisive one: **the e-ink refresh policy lives in a patched
  SurfaceFlinger.** A prebuilt GSI ships a stock SurfaceFlinger by definition, so
  it can never drive this panel.

That last point converted the project from "flash a ROM" into "build one".

→ `docs/findings.md`

## Phase 4 — building from source

/e/OS built from source on a remote x86_64 machine (Apple Silicon cannot run
soong's analysis pass natively). First boots produced a device that ran but had
no `/data` and no display.

Two fixes worth remembering, both small and both hard to find:

* **`dirsync`** in the vendor fstab — an option Android 15's fs_mgr no longer
  consumes, which broke the wrapped-key `/data` mount. A 7-byte patch.
* **VNDK APEX** — `PRODUCT_EXTRA_VNDK_VERSIONS := 30`, without which the A11
  vendor libraries had nothing to link against.

After that: a device that booted fully, ran the launcher, answered adb — and
showed nothing at all.

→ `docs/04`, `docs/05`, `docs/09`

## Phase 5 — the blank screen, and four wrong theories

This was the long part. In order, what we believed and why each was wrong:

**"The EPD needs a region protocol we have not implemented."** Half right, but it
sent us looking in the wrong layer for a long time.

**"The Fairphone 4 ABL is breaking the display."** The runtime cmdline contained
`msm_drm.dsi_display0=...rm69299...`, injected by the borrowed FP4 bootloader,
and Onyx's DTBO does contain a dummy `rm69299` panel. Damning-looking, and
false: `dsi_display0` selects the panel for the node labelled `"primary"`, which
*is* the dummy, whose default panel is already that. The real EPD hangs off
`"secondary"` and was bound correctly the whole time. We built a patched boot
image to fix a non-problem.

**"Onyx's SurfaceFlinger will do it for us."** A whole branch went into running
their stock SF on our Android 15 build. It surfaced genuinely useful things —
the AIDL transaction-code drift, the 216-vs-224-byte display event mismatch, the
`/dev/ebc` command numbering — but their binary enables the display, holds
layers, and issues **zero DRM commits**. Ours composites correctly. Abandoned;
the knowledge is kept in `docs/12`.

**"The commit path never runs."** Zero `commit[...]` lines in a whole boot looked
conclusive. Disassembly showed the counter increments and the submit executes
unconditionally — only the *log* is gated on a debug flag with no debugfs and no
module param. **Absence of log lines proved nothing.**

**The actual cause:** the kernel copies pixels into the EPD buffer *per update
rectangle*, and takes the rectangles from two Onyx-added DRM plane properties.
Nothing in an AOSP stack sets them, so the count was structurally zero and the
panel faithfully displayed an empty buffer.

Running through all of this, twice, was a simpler error: **an empty `screencap`
means the display is asleep**, not that compositing is broken. Two separate
conclusions were built on asleep-display captures, including the one that made us
abandon Onyx's SF.

→ `docs/11`

## Phase 6 — the shim

The vendor half of the chain was intact and already on the device: `libsdedrm.so`
exports the property setters, the composer knows how to commit them. Only the
system half was missing.

Rather than reproduce Onyx's private SF↔composer transport, we interposed:
`libepdcshim.so`, `LD_PRELOAD`ed into the composer, adds the two properties to
the atomic commit it already makes every frame. Interposition works because the
relevant libraries resolve `drmModeAtomic*` dynamically.

The panel lit up. Everything since has been quality, not existence.

→ `docs/11`, `src/epdcshim.c`

## Phase 7 — making it usable

Discovering that the display works and discovering that it is *pleasant* were
different projects.

* **Client composition turned out to be mandatory**, not a preference: the kernel
  drops any plane smaller than the panel, so the nav bar, status bar and IME were
  being drawn, hit-tested, and never displayed.
* **`flag` was wrong.** We had been sending `0x21000`; Onyx sends `0x31000`. That
  made icons washed out and barely legible, and it was chased as a ghosting
  problem for several rounds before anyone compared against the value captured
  from stock in the very first trace.
* **`update_mode 0`** stopped the constant full-panel flashing.
* **Unique update markers** — reusing one leaves the panel mid-waveform, which is
  the intermittent blank-after-refresh.
* **Animations are extraordinarily expensive here** — every frame is a panel
  refresh. Turning them off took idle from ~12 refreshes per 10 s to zero.
* **`EPD_AUTO` was tried and rejected**; a fixed GC16 looks better.

→ `docs/17`, `docs/18`

## Phase 8 — where it stands

Working: display, navigation bar, wallpaper, light theme, zero idle refreshes,
setup completed, launcher usable.

Not working / open: updates are still **full-panel**, because SurfaceFlinger
publishes one coarse damage rectangle; the settle thread does not fire; `temp` is
a guessed 0; the frontlight is unmanaged by Android.

→ GitHub issues #1–#9

---

## What actually worked as a method

**Measure the thing you are claiming.** Not the thing next to it. `screencap`
proves the *framework* composited; it says nothing about the panel. Counting the
driver's own `waveform_clean_work_handler` lines proves the panel refreshed.
Conflating those two cost days.

**Disassemble when there is no source.** Onyx ships no kernel source. Every
important constant here — the plane size check, the 320-byte copy, the update
struct field order, `SET_EBC_SEND_UPDATE = 0x700c` — came from reading their
binaries. It is slower than reading source and far faster than guessing.

**Prefer a captured value to a derived one.** The ioctl numbering derived from
upstream Rockchip was off by one above `0x7001`, because Onyx inserted a command.
`flag` was wrong for weeks because a plausible guess went unchallenged while the
real value sat in a trace we had already taken. When a stock value is available,
use it and mark it as captured.

**Absence of evidence is usually a logging artifact.** Debug-gated printks,
ring-buffer wraparound in `dmesg`, and logcat rotation during a service restart
each produced a confident wrong conclusion at least once.

**Optimise the iteration loop before optimising anything else.** A full image
build plus EDL flash is hours; `zig cc` plus `adb push` plus a service restart is
seconds. Almost all of the display work was done without ever flashing an image.

**Write down negative results with the reason.** "GSI is not viable" is worth
little; "GSI is not viable *because the refresh policy lives in a patched
SurfaceFlinger*" redirected the entire project. The same for `EPD_AUTO`, for
Onyx's SF, and for the ABL theory.

**Re-dump before acting on a dump.** A stale `lpdump` led to resizing a partition
that had already been resized, and diagnosing the wrong one.

**When a fix does not apply, suspect precedence before mechanism.** The overlays
that "did not work" were enabled and correct, and simply outranked. Nothing logs
when an override loses.

## Mistakes worth not repeating

* Acting on an empty `screencap` without waking the display — twice.
* Building a boot image to fix a bootloader theory that a single `dmesg` line
  would have disproved.
* Writing a settle pass with a constant `update_marker`, one commit after
  documenting that markers must be unique.
* Putting a literal `--` inside an XML comment three times, at ~45 minutes of
  regeneration each, before adding `scripts/check-device-xml.py`.
* Committing a 58 MB proprietary kernel to git, and only noticing while
  preparing to publish.
