# Palma 2 Pro / e/OS — operator's manual

What the hardware is, how the display actually works, what we changed, and how to
poke at it without breaking things. Written to be read before touching the
device, and re-read when something behaves oddly.

Deep dives live in `docs/`; this is the map. For the machine-level
contract -- exact ioctl numbers, struct offsets, panel timings, TCON and PMIC
registers, each marked verified/derived/inferred -- see
**`docs/19-tcon-panel-abi.md`**. Where a claim here was established
by measurement or disassembly, the doc that did it is cited.

---

## 1. The device in one page

| | |
|---|---|
| Model | Onyx Boox Palma 2 Pro (`Palma2_Pro_C`) |
| SoC | Qualcomm SM7225 "bitra" / Snapdragon 750G — same as the Fairphone 4, which is why unlocking was possible |
| Storage | UFS, A/B slots, **slot B active**, dynamic partitions inside `super` |
| System | Android 15 (`/e/OS`) over Onyx's **Android 11 vendor BSP** (`ro.vndk.version=30`) |
| Panel | E Ink `ED061KC1`, **1648x824**, 16 grey levels |
| TCON | Lattice CertusPro-NX FPGA, firmware `lfcpnx100_tcon_fw_a*.bin`, fed **MIPI DSI** by the SoC |
| EPD PMIC | TI TPS65185 |
| Verified boot | AVB **disabled** (vbmeta flags 0x3); SELinux **permissive** via cmdline. Both deliberate, both still open (issues #10, #11). See the security posture note in `README.md` before daily use. |

The mixed-generation stack (A15 system, A11 vendor) is the root of a whole class
of problems: vendor libraries expect Android 11 behaviour, and `ro.*` properties
are first-writer-wins with **vendor beating system**.

Recovery is never far away: `adb` survives almost anything because the display is
not on the boot path, and EDL survives the rest. Stock images are in `firmware/`.

---

## 2. How a pixel gets to the panel

This is the part worth understanding before changing anything.

```
  app draws
      │
      ▼
  SurfaceFlinger            composites ALL layers into ONE full-screen buffer
      │                     (client composition — mandatory here, see §3)
      ▼
  composer HAL              vendor.qti.hardware.display.composer-service
      │                     owns DRM master, builds the atomic commit
      ▼
  libsdedrm.so              DRMPlane::SetEpdcUpdParmsAddr / SetEpdcUpdCnt
      │
      ▼
  DRM plane properties      EPDC_UPDATE_PARMS_ADDR  (userspace pointer)
      │                     EPDC_UPDATE_CNT         (how many rects are valid)
      ▼
  kernel: __sde_plane_atomic_update_epdc
      │   · rejects any plane whose size != panel size
      │   · copy_from_user(plane_state+0x7dc, ptr, 320)   ← 8 × 40-byte structs
      │   · submit(vaddr, w, h, stride, upd_data, cnt)
      ▼
  onyx EPDC driver          waveform lookup, temperature, LUT scheduling
      │                     /dev/ebc, epdc_* kernel threads
      ▼
  Lattice TCON (DSI)        drives source/gate drivers
      │
      ▼
  E Ink panel
```

**The one fact that explains most behaviour:** the kernel copies pixels into the
EPD buffer *per update rectangle*. With `cnt == 0` it copies nothing, and the
panel faithfully displays an empty buffer. That was the blank screen for most of
this project (`docs/11`).

---

## 3. Two hard constraints

**Client composition is mandatory, not a preference.**
`__sde_plane_atomic_update_epdc` accepts only planes exactly the size of the
panel. Any layer the composer promotes to its own hardware plane — nav bar
(53 px), status bar (90 px), IME, popups — is silently dropped and never reaches
the e-ink buffer. It is drawn, it is clickable, and it is invisible.

```sh
service call SurfaceFlinger 1008 i32 1     # mDebugDisableHWC
```

Resets on **every** SurfaceFlinger restart. `system/etc/init/epdc-clientcomp.rc`
re-applies it on `property:init.svc.surfaceflinger=running`, with an 8 s delay
because the trigger fires before SF publishes its binder interface.

**Refresh cost is proportional to AREA, not to how much changed.**
Repainting 1.36 M pixels for one changed character is the normal case today,
because SurfaceFlinger publishes one coarse damage rectangle (`docs/15`). No
waveform choice fixes that; only finer damage does.

---

## 4. `/dev/ebc` — the direct path

Bypasses DRM entirely and re-drives whatever is already in the EPD buffer.
This is how `ebcrefresh` works and how the settle pass works.

```c
#define EBC_SEND_UPDATE      0x700c   /* from Onyx SF's own call site   */
#define EBC_GET_BUFFER_INFO  0x7003   /* returns real panel geometry     */

struct ebc_send_update {         /* kernel copies exactly 0x28 = 40 bytes */
    int32_t rect[4];             /* +0x00  x, y, w, h                     */
    int32_t waveform_mode;       /* +0x10  see §5                         */
    int32_t update_mode;         /* +0x14  0 = partial, 1 = full/flashing */
    int32_t update_marker;       /* +0x18  MUST BE UNIQUE — see below     */
    int32_t temp;                /* +0x1c  temperature index              */
    int32_t flag;                /* +0x20  use 0x31000                    */
    int32_t reserved;            /* +0x24                                 */
};
```

Two values that were learned the hard way:

* **`flag` must be `0x31000`.** That is what Onyx's own SurfaceFlinger sends. We
  used `0x21000` for a long time and icons were washed out and barely visible —
  a drive-voltage problem that looked like a ghosting problem.
* **`update_marker` must be unique per submission.** The driver tracks markers
  and blocks in `onyx_epdc_fb_wait_updates_complete()` until the one it is
  waiting on completes. Reusing a marker makes each update collide with the last
  and leaves the panel mid-waveform — an intermittent **blank screen**. The
  symptom in `dmesg` is `Waiting for update marker magic[1] complete` repeating.

**Never call `EBC_GET_BUFFER` (0x7000).** It blocks forever on this device,
proven three separate times including with SurfaceFlinger *and* the composer
stopped. It needs a hard power cycle. `docs/11` has the full account.

---

## 5. Waveform modes

Logical values, as passed in `waveform_mode` (`docs/03` derived the mapping from
the device's own firmware):

| value | name | character |
|---|---|---|
| 0 | `EPD_AUTO` | driver picks. **Tried, rejected** — heavy ghosting, worse than a fixed GC16 |
| 1 | `EPD_OVERLAY` | |
| **2** | **`EPD_FULL_GC16`** | 16 levels, clean. **Our default.** What Onyx uses for whole-screen refreshes |
| 3 | `EPD_FULL_GL16` | 16 levels, softer |
| 5 | `EPD_FULL_GLD16` | |
| 6 | `EPD_FULL_GCC16` | |
| 8 | `EPD_PART_GL16` | partial 16-level. Looked worse here, both steady-state and as a motion mode |
| 12 | `EPD_A2` | binary, fastest. For keyboards/animation on other platforms |
| 14 | `EPD_RESET` | |

`update_mode` is a **separate axis** from the waveform: it selects flashing
(repaint every pixel in the region, including unchanged) versus partial (drive
only changed pixels). `upd 0` is what stopped the constant flashing while
keeping GC16.

Cross-platform mode semantics (DU/A2/GC16/GL16/REAGL) are surveyed in `docs/18`;
the names are shared with Kobo, Kindle, reMarkable and Rockchip.

---

## 6. What we added

### `src/epdcshim.c` → `/vendor/lib64/libepdcshim.so`

`LD_PRELOAD`ed into the composer via
`/vendor/etc/init/vendor.qti.hardware.display.composer-service.rc`. Supplies the
update rectangles nothing else sets. Interposition works because `libsdedrm.so`
has `libdrm.so` as a `NEEDED` entry, so `drmModeAtomic*` resolve through the
global symbol table where a preloaded definition wins.

It hooks `drmModeAtomicAddProperty` **only to record** which object ids the
composer itself put in the request, then adds the epdc properties to exactly
those at commit time — never to a guessed plane id, because pulling an extra
object into an atomic request can fail an otherwise valid commit.

Live tunables, re-read every 30 commits (no restart):

| property | meaning |
|---|---|
| `persist.epdcshim.enable` | master switch |
| `persist.epdcshim.wf` | waveform mode (§5) |
| `persist.epdcshim.upd` | 1 = flashing, 0 = partial |
| `persist.epdcshim.flag` | **use 0x31000** |
| `persist.epdcshim.interval` | ms floor between updates |
| `persist.epdcshim.skipsame` | skip commits presenting the same `FB_ID`s |
| `persist.epdcshim.fastwf` / `fastms` | cheaper waveform while frames arrive quickly |
| `persist.epdcshim.fullevery` | periodic flash every N updates (superseded by settle) |
| `persist.epdcshim.settlems` / `settlewf` | quality pass once the screen goes quiet |

**Known-good configuration:**

```sh
setprop persist.epdcshim.wf        2
setprop persist.epdcshim.upd       0
setprop persist.epdcshim.flag      0x31000
setprop persist.epdcshim.fastwf    0
setprop persist.epdcshim.interval  120
setprop persist.epdcshim.settlems  0     # settle thread not currently firing
setprop persist.epdcshim.fullevery 0
```

### `src/epdc_damage.h` + SurfaceFlinger patch

`patches/main/0002-*.patch` makes SF publish its dirty region into
`/dev/epdc/damage`; the shim reads it. Single writer, single reader, seqlock —
neither side may block the other, both are on the frame path. The sequence
number doubles as a precise change detector.

Rectangles must be in **output space** (1648x824 landscape), not layer stack
space (824x1648 portrait) — the panel is installed rotated.

Currently delivers one coarse full-panel rectangle, because
`Output::getDirtyRegion()` is the union across layers. Making it fine-grained is
`docs/15`.

### Tools (`src/`, build with zig, no NDK needed)

```sh
zig cc -target aarch64-linux-musl -static -O2 -o out/ebcrefresh src/ebcrefresh.c
zig cc -target aarch64-linux-none -fPIC -shared -nostdlib -O2 -o out/libepdcshim.so src/epdcshim.c
```

| tool | what it does |
|---|---|
| `ebcrefresh` | one `SET_EBC_SEND_UPDATE`. The "is the panel alive" test |
| `ebcfb` | mmaps `/dev/ebc` and histograms it. **Caveat:** offset 0 is the *handwriting overlay* buffer, not the display framebuffer — it needs an offset argument before its output means anything |
| `ebcprobe`, `ebcpush`, `ebcinit` | earlier staged probes, kept for reference |

The shim is built **freestanding** (`-nostdlib`) on purpose: it is injected into
a bionic process and must not drag in a libc. Its only imported symbol is
`dlsym`; everything else is looked up at runtime.

### Device-side settings and overlays

See `docs/17` for the full list with reasoning. Summary of what is applied and
how long it survives:

| setting | mechanism | survives |
|---|---|---|
| navigation bar | `qemu.hw.mainkeys=0` (`device.mk`) | reboot |
| client composition | `epdc-clientcomp.rc` | reboot |
| animations off | SettingsProvider defaults overlay | wipe |
| `animator_duration_scale=0` | runtime only | reboot |
| white wallpaper | `/data/system/users/0/wallpaper` + delete `wallpaper_info.xml` | reboot, **not** wipe |
| light theme | `cmd uimode night no` | reboot |
| blur off, high contrast | `build.prop` / `settings` | reboot |

---

## 7. Debugging playbook

**Wake the display before judging anything.** An empty `screencap` (~9 kB, solid
black) means the display is **asleep**, not broken. Two separate wrong
conclusions in this project were built on asleep-display captures.

```sh
adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'
```

| question | how to answer it |
|---|---|
| Did the framework composite? | `screencap` — 60–250 kB is real content. Says **nothing** about the panel |
| Did the panel refresh? | count `waveform_clean_work_handler` in `dmesg` over a window |
| Is the shim loaded? | `grep -c epdcshim /proc/$(pidof vendor.qti.hardware.display.composer-service)/maps` |
| Is SF publishing damage? | `od -A n -t d4 -j 8 -N 40 /dev/epdc/damage` — seq, count, full, rect |
| Is the shim attached to it? | logcat `epdcshim: attached to SurfaceFlinger damage` |
| Is composition client-side? | `dumpsys SurfaceFlinger | grep usesDeviceComposition` — must be **false** |
| Are planes being rejected? | `dmesg | grep update_epdc` — logs only failures |
| Is a marker stuck? | `dmesg | grep "Waiting for update"` |

`dmesg` is a ring buffer and wraps — comparing two raw counts can go *negative*.
Filter by the kernel timestamp in the line instead.

`logcat` rotates fast during a composer restart. Clear it first (`adb logcat -c`)
or you will conclude a log line is missing when it was simply pushed out. That
cost real time twice.

---

## 8. Traps that have already cost hours

* **`.mk` edits force a ~35–45 min kati regen** before anything compiles. So does
  *adding a new file* to a globbed directory. Editing an existing file is free.
* **A literal `--` inside an XML comment is illegal**, and aapt2 reports only
  `not well-formed` with no line or cause. Run `scripts/check-device-xml.py`
  before `builder.sh push`. This cost two build cycles.
* **RRO enabled ≠ RRO effective.** Overlays apply in priority order and the last
  wins. /e/OS ships `foundation.e.blisslauncher.overlay` at priority 100; ours
  needed to exceed it. Nothing is logged when an override loses.
* **Partial builds do not regenerate `build.prop`**, so
  `PRODUCT_PROPERTY_OVERRIDES` only reaches the device on a full image build.
* **Check the artifact's mtime before deploying.** `pgrep ninja` is not a
  reliable completion test — there are gaps between build phases, and a stale
  binary will be pushed happily.
* **Onyx's fastbootd rejects `flash`.** Everything goes through EDL
  (`adb reboot edl`). The screen stays blank in EDL; that is normal, there is no
  bootloader UI on this panel.

---

## 9. Where to change what

| goal | place |
|---|---|
| refresh policy, waveform choice | `persist.epdcshim.*`, live |
| which rectangles are refreshed | SF `collectEpdcDamage()` — `docs/15` |
| how rectangles reach the kernel | `src/epdcshim.c` |
| launcher look/behaviour | RRO in `device/onyx/Palma2_Pro_C/rro/` (prebuilt APK, no source in tree) |
| framework defaults | `device/onyx/Palma2_Pro_C/overlay/` |
| properties | `device/onyx/Palma2_Pro_C/device.mk` (forces a regen) |

---

## 10. Open issues

* **Snappiness is capped** until per-layer damage lands (`docs/15`). Every update
  is full-panel regardless of waveform.
* **Settle pass does not fire.** The timer thread in the shim is inert; the plane
  path keeps producing updates while `SET_EBC_SEND_UPDATE` stays flat. Disabled
  by default until diagnosed.
* **`temp` is always 0.** Waveforms are temperature-indexed and the driver
  exposes `onyx_epdc_fb_get_temp_index`. Given that `flag` turned out to matter
  this much, this is the other field we send a guessed value for.
* **Wallpaper RRO targeting `android` may still not apply** even at high
  priority; the `/data` method works regardless.
* **`ro.adb.secure=0`** is patched into both `system_b` and `vendor_b`. Any host
  that plugs in gets a root-capable shell with no prompt. Undo images are in
  `firmware/analysis/`.
