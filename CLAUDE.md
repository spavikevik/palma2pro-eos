# Working on this repo

Instructions for coding agents. Read before touching anything. Distillation of
what cost most time to learn.

**What this is:** /e/OS on Onyx Boox Palma 2 Pro — Android 15 over Onyx Android
11 vendor BSP, driving e-ink panel whose refresh path not in AOSP. `docs/20` =
narrative, `MANUAL.md` = operator view, `docs/19` = machine-level ABI.

---

## Non-negotiable

**Never commit Onyx binaries.** Kernel, vendor libs, `.wbf` waveform, TCON
bitstream, extracted APKs. Proprietary, kernel GPL-2.0 with no published source.
Purged from git history once already; `device/onyx/*/prebuilt/` and `firmware/`
gitignored. Users extract own (`INSTALL.md` step 3).

**Never commit device identifiers or personal data.** Serials, IMEI, LAN IPs,
absolute `/Users/...` paths, host keys. `edl_config.json` written by edlclient
every run, contains serial — gitignored.

**Never flash `vendor` or `odm`.** They are Onyx Android 11 BSP and own whole
display stack. Overwrite = device with no display.

**Device currently accepts adb root with no prompt.** `ro.adb.secure=0` patched
into both `system_b` and `vendor_b`, so any host that plugs in gets root-capable
shell. Deliberate for bring-up, tracked as issue #5. Know this before plugging
into anything you do not control.

**Never call `EBC_GET_BUFFER` (ioctl `0x7000`).** Blocks forever on this device
— proven three times, including with SurfaceFlinger and composer both stopped.
Nothing logged. Needs hard power cycle.

**Never sweep unknown ioctls in a batch.** `0x701a` panics kernel — reads capture
buffer that only exists after `CAPTURE_START` (`0x7018`); hardened usercopy
`BUG()`s on invalid object. Fourteen commands in one loop died with no output;
only pstore backtrace identified culprit. **One command per invocation, result
recorded on host before next.** Per-process `timeout` protects userspace hang,
does nothing about kernel BUG. Probe with **zero** payload, never distinctive
value — `4321` sweep inverted panel.

**`/dev/ebc` is `crw-rw-rw-`, SELinux permissive.** Any installed app can drive
panel, switch it to handwrite scheme, or panic device with one ioctl and no
permission. Unprivileged local DoS. Tracked with issue #5.

---

## Before you believe a symptom

**Wake display first.** Empty `screencap` (~9 kB, solid black) means display
*asleep*, not broken. Two wrong conclusions in this project built on
asleep-display captures; one abandoned working approach.

```sh
adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'
```

**Undo `stayon` when done.** `svc power stayon true` writes
`stay_on_while_plugged_in=15` (AC|USB|WIRELESS|DOCK) to settings — persistent
across reboots, and nothing clears it. Screen then never sleeps while plugged,
so the device never suspends at all: `/sys/power/suspend_stats/success` stays 0
and `PM: suspend entry` never appears. It flattens the battery and reboots
itself overnight with `ro.boot.bootreason=shutdown,battery`. Teardown:

```sh
adb shell 'settings put global stay_on_while_plugged_in 0; settings put system screen_off_timeout 60000'
```

**`screencap` proves framework composited. Says nothing about panel.** Different
failures, different fixes. To prove panel refreshed, count driver's own
`waveform_clean_work_handler` lines in `dmesg`.

**Absence of log lines proves nothing.** Debug-gated printks (no debugfs on this
kernel), `dmesg` ring-buffer wraparound — comparing two raw counts can go
*negative* — and logcat rotating during service restart each produced confident
wrong conclusion. `adb logcat -c` first, and filter `dmesg` by kernel timestamp,
not line count.

**Enabled overlay ≠ effective overlay.** RROs apply in priority order, last
wins, nothing logged when one loses. /e/OS ships launcher overlay at priority
100; ours needed 1000.

---

## When device wedges

**Panic reboots work.** `panic=5` + `panic_on_oops=1` set by init, survive
reboot. Kernel panic self-recovers in ~5 s; `sys.boot.reason` reads
`kernel_panic,bug`. Do not tell user to power-cycle before checking — device
usually comes back.

**pstore keeps the evidence.** `/sys/fs/pstore/console-ramoops-0` holds previous
boot's console across reboot. Bit-corrupted (`ramoops.ecc=0`) but legible; how
`0x701a` was identified. `dmesg-ramoops-0` appears after an oops.

**SoC watchdog does not help display hangs.** bark 11 s, bite ~14 s, but a stuck
display pipeline keeps petting it — one probe hung 220 s. `DETECT_HUNG_TASK`,
`SOFTLOCKUP_DETECTOR`, `WQ_WATCHDOG`, `WATCHDOG` all compiled **out**; cannot be
enabled at runtime.

```sh
scripts/epd-debug-arm.sh            # sysrq on, kptr_restrict off — run per boot
scripts/epd-deadman.sh arm 30       # detached reboot unless disarmed
echo w > /proc/sysrq-trigger        # which EPD thread is stuck, and where
```

**`adb root` does not survive reboot** — adbd returns as `shell`. Several probe
results were first misread as permission failures because of it.

## Method that worked

1. **Measure thing you claim**, not thing next to it.
2. **Prefer captured stock value over derived one.** `flag` wrong for weeks
   (`0x21000` vs stock `0x31000`) while correct value sat in trace already taken
   — looked like ghosting, was drive voltage. Ioctl numbering derived from
   upstream Rockchip off by one above `0x7001` because Onyx inserted a command.
3. **Disassemble when no source.** Onyx ships none. Every important constant
   here came from reading their binaries. Slower than reading source, far faster
   than guessing.
4. **Optimise iteration loop first.** Full image build + EDL flash = hours; `zig
   cc` + `adb push` + service restart = seconds. Nearly all display work done
   without flashing image.
5. **Write negative results with reason.** "GSI not viable" worth little; "not
   viable *because refresh policy lives in patched SurfaceFlinger*" redirected
   project.
6. **Re-dump before acting on dump.** Stale `lpdump` caused already-resized
   partition to be resized again, and wrong one diagnosed.

---

## Build and deploy

**Fast loop (default).** One soong module or zig build, `adb push`, restart one
service. Seconds.

```sh
zig cc -target aarch64-linux-none -fPIC -shared -nostdlib -O2 -o out/libepdcshim.so src/epdcshim.c
adb root && adb remount && adb push out/libepdcshim.so /vendor/lib64/
adb shell 'setprop ctl.restart vendor.qti.hardware.display.composer'
```

**Traps:**

* **Editing any `.mk` forces ~45 min kati regen** before anything compiles. So
  does *adding new file* to globbed directory (an overlay drawable did it).
  Editing existing file free.
* **Literal `--` inside XML comment is illegal.** aapt2 reports only `not
  well-formed`, no line, no cause. Cost three build cycles. Run
  `scripts/check-device-xml.py` before `scripts/builder.sh push`.
* **Wait for real completion marker**, not `pgrep ninja` — gaps between phases.
  `grep -c "build completed successfully" /aosp/build.log`. Check artifact mtime
  before deploying or you push stale binary.
* **Partial builds do not regenerate `build.prop`**, so
  `PRODUCT_PROPERTY_OVERRIDES` only lands on full image build.
* `scripts/builder.sh` needs `BUILDER_HOST` — placeholder in repo on purpose.
  Set in environment; do not commit address.

**After every SurfaceFlinger restart**, client composition must be re-applied or
nav bar, status bar and IME drawn but invisible — kernel drops any plane smaller
than panel:

```sh
adb shell 'service call SurfaceFlinger 1008 i32 1'
```

---

## Display facts you will need

* Panel 1648×824, 16 grey levels. Refresh cost proportional to **area**.
* Known-good: `wf 2` (GC16), `upd 0`, `flag 0x31000`, `interval 150`, everything
  else 0. No flash, glide present in Kindle but tolerable. Return here after any
  refresh-policy experiment.
* **`temp` and `dither_mode` are not read by the driver** — `persist.epdcshim.temp`
  and `.dither` do nothing. `update_mode` is not read either. Only `waveform_mode`,
  `update_marker` and `flags` matter. docs/19 §4.6, docs/22 §13.
* **`a2` (waveform 6) is ADDITIVE** — lays each frame over the last without
  clearing, so motion leaves several frames legible at once. Needs a full-drive
  clean, or `fastwf 0` to avoid entirely.
* Panel has Kaleido CFA hardware (`cfa_mode[1017]` in DT; enabling it tints the
  flash green), but the loaded waveform lacks the colour modes: `gcc16[-1]
  glrc16[-1]`. CFA enable is ioctl `0x7026` and its argument is **inverted** —
  0 enables.
* Content is authored portrait 824×1648; the panel buffer is landscape output
  space. Rotate **270** (DT agrees: `sf_rotation[270]`).
* `update_marker` **must be unique** per submission, or updates collide and
  panel blanks mid-waveform (`Waiting for update marker magic[1] complete`).
* Every update currently **full-panel** because SurfaceFlinger publishes one
  coarse damage rectangle. That is ceiling on everything; issue #1.
* Tunables live via `persist.epdcshim.*`, re-read every 30 commits.

---

## Keep tool output small

This repo makes enormous tool output — `dmesg`, `aapt2 dump`, disassembly, `gh
api`, partition dumps. Unbounded output is main way sessions here burn context,
and it spent the moment it lands: no later discipline reclaims it.

* **Always bound Bash output.** `| tail -20`, `| head -30`, `grep -c` when count
  answers question. `dmesg | grep X | tail -5`, never bare `dmesg`.
* **Never `cat` large file.** Use Read with `offset`/`limit`, or `sed -n 'A,Bp'`
  for known range.
* **Ask for answer, not data.** `grep -c "avc: denied"` beats printing denials;
  `wc -c` beats `cat`; `ls -l | awk '{print $5,$9}'` beats `ls -la`.
* **`gh api` returns full file content as base64** — always `--jq` the field you
  want, never bare object.
* **Disassembly and hex dumps: pipe through filter that extracts specific
  instruction or offset**, not whole region.
* Re-reading file already read this session = pure waste — earlier read still in
  context.

## Conventions

**Commits.** Explain *why*, not what. Body prose, not bullets-only. Record what
was ruled out and how. End with `Co-Authored-By: Claude Opus 5
<noreply@anthropic.com>`.

**Docs.** Numbered `docs/NN-topic.md`; `MANUAL.md`, `INSTALL.md`,
`THIRD_PARTY.md`, `LICENSING.md` at root. In `docs/19`, every claim carries
confidence marker — `[V]` verified on device, `[D]` derived from disassembly,
`[T]` device tree, `[I]` inferred from upstream. **Keep using them**; inferred
category already been wrong.

**Corrections belong in repo.** When documented conclusion turns out wrong,
correct in place and say so, with reasoning that produced error. Half of
`docs/11` is corrections and that is most useful part of it.

**Attribution.** `THIRD_PARTY.md` separates code (none copied), facts (constants
and API semantics from others' docs), and ideas (algorithms reimplemented). Most
of what this project borrowed is knowledge, not code. Keep that separation.

**Licence.** Code Apache-2.0 OR MIT; `docs/` CC BY-SA 4.0. `LICENSE` is verbatim
Apache copy for GitHub detector; real terms are `LICENSING.md`.

---

## Note on issue #1

Issue #1 currently written as guided task: seam (`collectEpdcDamage()`) exists,
and `docs/15` is walkthrough with hints behind `<details>`, not implementation.
That was owner's choice for that issue, not standing convention.

Do not silently implement it and remove exercise. Equally, do not assume same
shape applies elsewhere — how much to hand over versus do outright is owner's
call, per task. Ask if not obvious.
