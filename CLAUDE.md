# Working on this repo

Instructions for coding agents. Read this before touching anything; it is the
distillation of what cost the most time to learn.

**What this is:** /e/OS on an Onyx Boox Palma 2 Pro — an Android 15 system over
Onyx's Android 11 vendor BSP, driving an e-ink panel whose refresh path is not
in AOSP. `docs/20` is the narrative, `MANUAL.md` is the operator's view,
`docs/19` is the machine-level ABI.

---

## Non-negotiable

**Never commit Onyx binaries.** Kernel, vendor libs, `.wbf` waveform, TCON
bitstream, extracted APKs. They are proprietary, and the kernel is GPL-2.0
without published source. They were purged from git history once already;
`device/onyx/*/prebuilt/` and `firmware/` are gitignored. Users extract their own
(`INSTALL.md` step 3).

**Never commit device identifiers or personal data.** Serials, IMEI, LAN IPs,
absolute `/Users/...` paths, host keys. `edl_config.json` is written by edlclient
on every run and contains a serial — it is gitignored.

**Never flash `vendor` or `odm`.** They are Onyx's Android 11 BSP and own the
entire display stack. Overwriting them produces a device with no display.

**Never call `EBC_GET_BUFFER` (ioctl `0x7000`).** It blocks forever on this
device — proven three times, including with SurfaceFlinger and the composer both
stopped. Nothing is logged. Requires a hard power cycle.

---

## Before you believe a symptom

**Wake the display first.** An empty `screencap` (~9 kB, solid black) means the
display is *asleep*, not broken. Two separate wrong conclusions in this project
were built on asleep-display captures, one of which abandoned a working approach.

```sh
adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'
```

**`screencap` proves the framework composited. It says nothing about the panel.**
Those are different failures with different fixes. To prove the panel refreshed,
count the driver's own `waveform_clean_work_handler` lines in `dmesg`.

**Absence of log lines proves nothing.** Debug-gated printks (there is no
debugfs on this kernel), `dmesg` ring-buffer wraparound — comparing two raw
counts can go *negative* — and logcat rotating during a service restart each
produced a confident wrong conclusion. `adb logcat -c` first, and filter `dmesg`
by kernel timestamp rather than counting lines.

**An enabled overlay is not an effective overlay.** RROs apply in priority order,
last wins, and nothing is logged when one loses. /e/OS ships its launcher overlay
at priority 100; ours needed 1000.

---

## Method that worked

1. **Measure the thing you are claiming**, not the thing next to it.
2. **Prefer a captured stock value to a derived one.** `flag` was wrong for weeks
   (`0x21000` vs stock's `0x31000`) while the correct value sat in a trace we had
   already taken — it looked like a ghosting problem, it was drive voltage. The
   ioctl numbering derived from upstream Rockchip is off by one above `0x7001`
   because Onyx inserted a command.
3. **Disassemble when there is no source.** Onyx ships none. Every important
   constant here came from reading their binaries. Slower than reading source,
   far faster than guessing.
4. **Optimise the iteration loop first.** Full image build + EDL flash is hours;
   `zig cc` + `adb push` + service restart is seconds. Nearly all display work
   was done without flashing an image.
5. **Write negative results with the reason.** "GSI not viable" is worth little;
   "not viable *because the refresh policy lives in a patched SurfaceFlinger*"
   redirected the project.
6. **Re-dump before acting on a dump.** A stale `lpdump` caused a partition that
   had already been resized to be resized again, and the wrong one diagnosed.

---

## Build and deploy

**Fast loop (default).** One soong module or a zig build, `adb push`, restart one
service. Seconds.

```sh
zig cc -target aarch64-linux-none -fPIC -shared -nostdlib -O2 -o out/libepdcshim.so src/epdcshim.c
adb root && adb remount && adb push out/libepdcshim.so /vendor/lib64/
adb shell 'setprop ctl.restart vendor.qti.hardware.display.composer'
```

**Traps:**

* **Editing any `.mk` forces a ~45 min kati regen** before anything compiles. So
  does *adding a new file* to a globbed directory (an overlay drawable did it).
  Editing an existing file is free.
* **A literal `--` inside an XML comment is illegal.** aapt2 reports only
  `not well-formed` with no line or cause. This cost three build cycles. Run
  `scripts/check-device-xml.py` before `scripts/builder.sh push`.
* **Wait for the real completion marker**, not `pgrep ninja` — there are gaps
  between phases. `grep -c "build completed successfully" /aosp/build.log`. Check
  the artifact's mtime before deploying or you will push a stale binary.
* **Partial builds do not regenerate `build.prop`**, so
  `PRODUCT_PROPERTY_OVERRIDES` only lands on a full image build.
* `scripts/builder.sh` needs `BUILDER_HOST` — it is a placeholder in the repo on
  purpose. Set it in the environment; do not commit an address.

**After every SurfaceFlinger restart**, client composition must be re-applied or
the nav bar, status bar and IME are drawn but invisible — the kernel drops any
plane smaller than the panel:

```sh
adb shell 'service call SurfaceFlinger 1008 i32 1'
```

---

## Display facts you will need

* Panel 1648×824, 16 grey levels. Refresh cost is proportional to **area**.
* Known-good: `wf 2` (GC16), `upd 0`, `flag 0x31000`. `EPD_AUTO` (0) and
  `PART_GL16` (8) were tried and look worse.
* `update_marker` **must be unique** per submission, or updates collide and the
  panel blanks mid-waveform (`Waiting for update marker magic[1] complete`).
* Every update is currently **full-panel** because SurfaceFlinger publishes one
  coarse damage rectangle. That is the ceiling on everything; issue #1.
* Tunables are live via `persist.epdcshim.*`, re-read every 30 commits.

---

## Conventions

**Commits.** Explain *why*, not what. Body prose, not bullets-only. Record what
was ruled out and how. End with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

**Docs.** Numbered `docs/NN-topic.md`; `MANUAL.md`, `INSTALL.md`,
`THIRD_PARTY.md`, `LICENSING.md` at root. In `docs/19`, every claim carries a
confidence marker — `[V]` verified on device, `[D]` derived from disassembly,
`[T]` device tree, `[I]` inferred from upstream. **Keep using them**; the
inferred category has already been wrong.

**Corrections belong in the repo.** When a documented conclusion turns out wrong,
correct it in place and say so, with the reasoning that produced the error. Half
of `docs/11` is corrections and that is the most useful part of it.

**Attribution.** `THIRD_PARTY.md` separates code (none copied), facts (constants
and API semantics from others' docs), and ideas (algorithms reimplemented). Most
of what this project borrowed is knowledge, not code. Keep that separation.

**Licence.** Code Apache-2.0 OR MIT; `docs/` CC BY-SA 4.0. `LICENSE` is a
verbatim Apache copy for GitHub's detector; the real terms are `LICENSING.md`.

---

## Collaboration

On large pieces, the owner writes the core logic; the agent scaffolds the seam,
the tests and the write-up, then reviews. Issue #1 is set up that way — the seam
(`collectEpdcDamage()`) exists, `docs/15` is a guided walkthrough with hints
behind `<details>`, and the implementation is deliberately left open.

Prefer offering that shape over delivering a finished implementation, unless
asked otherwise.

---

## State

Working: display, nav bar, wallpaper, light theme, zero idle refreshes, setup
completed. Open work is in GitHub issues, labelled by difficulty; #1 (per-layer
damage) is the one that matters. #5 is security-relevant and device-side:
`ro.adb.secure=0` is still patched into `system_b` and `vendor_b`, so any host
that plugs in gets a root shell with no prompt.
