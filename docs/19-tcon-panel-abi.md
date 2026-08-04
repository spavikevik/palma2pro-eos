# TCON, panel and EPD API/ABI reference

Developer reference for every programmable interface between the SoC and the
e-ink panel. Numbers, struct layouts, semantics, and hazards.

**Confidence is marked on every claim**, because a lot of this was recovered by
disassembly rather than read from a datasheet:

* **[V]** verified on the device — observed working, or read back from hardware
* **[D]** derived from disassembly of Onyx's kernel or binaries
* **[T]** from the device tree, i.e. Onyx's own description of its board
* **[I]** inferred from upstream lineage (Rockchip EBC, i.MX EPDC); **treat as a
  hypothesis**

Related: `docs/03` (how the ioctl numbering was established), `docs/07`
(hardware map), `docs/11` (the DRM path), `MANUAL.md` (operator's view).

---

## 1. Layering

```
  SurfaceFlinger ── composer HAL ── libsdedrm ──┐
                                                │ DRM atomic commit
                                                ▼
                                   SDE / MDSS display pipeline
                                                │  MIPI DSI
                                                ▼
                        Lattice CertusPro-NX TCON  (I2C 0x40, FPGA)
                                                │  source/gate drive
                                                ▼
                              E Ink ED061KC1 panel  (1648x824, 16 grey)
                                                ▲
                                                │ rails, VCOM, thermistor
                                   TI TPS65185 PMIC (I2C 0x68)
```

Two independent control surfaces reach the EPD:

| surface | used for | section |
|---|---|---|
| **DRM plane properties** | per-frame updates from the compositor | §3 |
| **`/dev/ebc` ioctls** | direct submission, diagnostics, waveform control | §4 |

They are not alternatives. The DRM path carries pixels *and* update rectangles;
`/dev/ebc` re-drives what is already in the EPD buffer.

---

## 2. Panel — E Ink ED061KC1 **[T]**

From the `eink-timings` device-tree node:

| property | raw | decoded |
|---|---|---|
| `panel_name` | `"ED061KC1"` | E Ink 6.13" |
| `xres` / `yres` | `0x670` / `0x338` | **1648 × 824** |
| `density` | `0xd4` | 212 dpi |
| `frame_rate` | `0x5a` | 90 |
| `sdclk-frequency` | `0x2625a00` | 40 MHz |
| `left/right/upper/lower_margin` | `0x0b`/`0x15`/`0x05`/`0x04` | 11 / 21 / 5 / 4 |
| `hsync_len` / `vsync_len` | `0x11` / `0x02` | 17 / 2 |
| `panel_width` | `0x10` | 16-bit bus |
| `kernel_init_mode_disable` | `1` | **kernel does not init the panel** |

Greyscale depth is **16 levels**, 8 bits per pixel in the EPD buffer **[V]** —
`EBC_GET_BUFFER_INFO` reports 1648×824 and the mapping is 1 byte per pixel.

`kernel_init_mode_disable = 1` matters: nothing initialises the panel at probe,
so the screen stays blank until userspace drives it. Every "it booted but the
screen is dead" symptom starts here.

### DSI vs panel geometry — do not conflate **[V]**

The DSI link timing is **not** the panel resolution. Two DSI display nodes exist:

| DRM connector | timing | node | role |
|---|---|---|---|
| `card0-DSI-1` | 1648×824 | `dsi_rm69299_visionox_amoled_cmd` | **dummy** panel, label `"primary"` |
| `card0-DSI-2` | 457×835 | `dsi_epdc_cmd` | the **real** EPD, label `"secondary"` |

The epdc panel's own DSI timing is 457×835 because the link feeds the FPGA TCON
in a packed format; the TCON drives the 1648×824 panel. Onyx patches SDE to force
the secondary DSI to be treated as the primary connector:

```
sde_encoder_get_hw_resources(): epdc panle is SECONDARY dsi, so force set
    hw_res.display_type SDE_CONNECTOR_PRIMARY for sde rm req.
```

`msm_drm.dsi_display0=` selects the panel for the node labelled `"primary"` —
the *dummy* — so it is a no-op for the EPD. Several hours were lost to that.

---

## 3. DRM interface **[D][V]**

### Plane properties

| property | type | meaning |
|---|---|---|
| `EPDC_UPDATE_PARMS_ADDR` | u64 | **userspace pointer** to an update array |
| `EPDC_UPDATE_CNT` | u32 | how many entries are valid, 0..8 |

Set by `libsdedrm.so`:

```
sde_drm::DRMPlane::SetEpdcUpdParmsAddr(_drmModeAtomicReq*, unsigned long)
sde_drm::DRMPlane::SetEpdcUpdCnt(_drmModeAtomicReq*, unsigned int)
```

The kernel `copy_from_user`s a **fixed 320 bytes** (8 × 40) from the pointer,
regardless of the count, into `plane_state + 0x7dc`; the count lands at
`plane_state + 0x91c`.

**With `cnt == 0` the submit copies no pixels.** The panel then displays an empty
buffer. This was the blank screen for most of this project.

### Plane size constraint **[D]**

`__sde_plane_atomic_update_epdc` rejects any plane not exactly panel-sized:

```
ldp  w21, w20, [x22, #0x28]   ; fb width, height
ldr  w8,  [x27, #0x1360]      ; panel width
cmp  w21, w8
b.ne <error>
ldr  w8,  [x27, #0x1364]      ; panel height
cmp  w20, w8
b.ne <error>
```

`stride` and `fb_width` are logged but **never compared**, so gralloc's 1664-byte
stride against 1648 visible is irrelevant.

Consequence: **client composition is mandatory.** Any layer promoted to its own
hardware plane — nav bar (53 px), status bar (90 px), IME — is dropped and never
reaches the panel. It is drawn, hit-testable, and invisible.

### Not available

There is **no `FB_DAMAGE_CLIPS`** on any plane **[V]**. The full property
vocabulary is in `docs/11`. Damage must come from elsewhere; see `docs/15`.

---

## 4. `/dev/ebc` character device

Char device, major/minor `10,51` **[V]**. Default mode is `0600 root:root`; a
ueventd rule widens it (`patches/main/0001-*`).

### 4.1 Update struct — 40 bytes **[D][V]**

The one structure that matters. Identical on both the ioctl and the DRM property
paths — the field order was recovered from the kernel's own printk at
`plane_state+0x7dc` and confirmed against Onyx's SurfaceFlinger call site.

```c
struct ebc_send_update {          /* kernel copies exactly 0x28 bytes */
    int32_t rect[4];              /* +0x00  x, y, w, h                */
    int32_t waveform_mode;        /* +0x10  §4.3                       */
    int32_t update_mode;          /* +0x14  0 = partial, 1 = flashing  */
    int32_t update_marker;        /* +0x18  MUST BE UNIQUE — §4.4      */
    int32_t temp;                 /* +0x1c  temperature index          */
    int32_t flag;                 /* +0x20  use 0x31000 — §4.5         */
    int32_t reserved;             /* +0x24                             */
};
```

For the DRM path this is an array of 8, always copied whole.

### 4.2 Command set **[D]**

Eighteen commands exist in the kernel strings. Confirmed numbers:

| command | value | status |
|---|---|---|
| `GET_EBC_BUFFER` | `0x7000` | **[D]** — ⚠ blocks forever, see §6 |
| `SET_EBC_SEND_BUFFER` | `0x7001` | **[D]** |
| `GET_EBC_DRIVER_SN` | `0x7002` | **[V]** returns `ONYX_EBC_DRIVER_VERSION_2.00` |
| `GET_EBC_BUFFER_INFO` | `0x7003` | **[V]** returns geometry |
| `SET_EBC_SEND_UPDATE` | `0x700c` | **[V]** the working submit |

**Onyx diverges from upstream Rockchip at `0x7002`.** Upstream puts
`GET_BUFFER_INFO` there; Onyx inserted `GET_DRIVER_SN`, shifting everything above
`0x7001` by +1. `SET_EBC_SEND_UPDATE = 0x700c` is **not** shifted — it was read
from Onyx's own call site, not extrapolated. Do not derive other numbers from
the upstream header without checking.

Named but unnumbered here: `SET_EBC_WAIT_ALL_UPDATE_COMPLETE`,
`SET_EBC_CLEAR_ALL_UPDATE`, `SET_EBC_FORCE_WAVEFORM`, `SET_EBC_LUT_ENABLE`,
`SET_EBC_GAMMA_TAB`, `SET_EBC_UPDATE_SCHEME`, `SET_EBC_UPD_LIST_SIZE`,
`SET_EBC_EXTBUF_SYNC_FB_ENABLE`, the `CAPTURE_*` family. Full list in
`firmware/analysis/ebc-commands.txt`.

### 4.3 Waveform modes **[D]**

Logical values, as written to `waveform_mode`. Mapping recovered from the
device's own firmware (`docs/03`):

| value | name | notes |
|---|---|---|
| **2** | `gc16` | **[V]** 16 grey, clean, slow. Steady-state default |
| 4 | `glr16` | **[V] accepted but STICKS** — frames stop updating mid-scroll, silently, with no driver error. Regal modes track per-pixel history; whatever that needs is not being maintained for us |
| 5 | `gld16` | **[V] no output** |
| **6** | `a2` | **[V] accepted. Binary (black/white only), fastest, and BIDIRECTIONAL** — unlike `overlay` it lifts ink as well as laying it, so it leaves no trail. The motion mode |
| 8 | `glr16plus` | untested |
| 9 | `glr16nm` | untested — "no measure", plausibly quicker than plain `glr16` |
| — | `gcc16`, `glrc16` | **absent from this unit's waveform file** (index `-1`). These are the Kaleido colour modes; this panel reports `color_panel[0]` and has none |

**Take these from the driver, not from a table of mode names.** The kernel prints
its own index map at boot and it is authoritative:

```
onyx_get_eink_screen_timing(): color_panel[0], timing_version[0], waveform_file_format[0]
get_glr16_mode_index(): gc16[2] glr16[4] gld16[5] a2[6] gcc16[-1] glrc16[-1] glr16nm[9] glr16plus[8].
```

`adb shell dmesg | grep get_glr16_mode_index` recovers it on any unit. The indices
are properties of the **loaded waveform file**, not fixed constants, so a
different `.wbf` may renumber them.

A mode that produces no output is externally indistinguishable from a hung
compositor -- the screen simply stops updating, with nothing logged. If the panel
freezes after a tuning change, look here first.

### Correction, 2026-08-04

An earlier version of this table listed `EPD_A2 = 12`, `EPD_PART_GL16 = 8` and
`EPD_OVERLAY = 1`, and recorded A2 and PART_GL16 as *rejected, produces no
refresh at all*. That was wrong, and it was expensive.

Those numbers came from a mode-name table of unknown provenance rather than from
this device. Mode 12 does not exist in this waveform file, so testing it produced
nothing -- and "nothing" was written down as "the driver rejects this mode",
alongside a passing control, which made it read as measured. The control was
fine. The inputs were fiction.

Everything downstream followed: the conclusion that **there is no fast and
correct waveform on this hardware**, the resulting use of `overlay` (mode 1,
additive, which smears every frame onto the panel), two bugs written to work
around that smearing, and second-long full-drive passes to undo it.

A2 works. It is mode 6, it is bidirectional, and it is what the motion path
should have used from the start.

The lesson is the one already in this document: **prefer a captured value to a
derived one.** The driver printed the correct table at every boot the whole time.

`update_mode` is a **separate axis**: flashing (repaint every pixel in the
region) vs partial (drive only changed pixels). Cross-platform semantics of the
mode names are in `docs/18`.

### 4.4 `update_marker` — uniqueness is mandatory **[V]**

The driver tracks markers and blocks in `onyx_epdc_fb_wait_updates_complete()`
until the one it is waiting on completes. **Reusing a marker makes each update
collide with the previous one, leaving the panel mid-waveform — an intermittent
blank screen.** Symptom:

```
o_e_f_w_u_c(): Waiting for update  marker magic[1] complete ... ...
```

repeating in `dmesg`. Increment per submission.

### 4.5 `flag` — use `0x31000` **[V]**

Onyx's SurfaceFlinger sends `0x31000`. We used `0x21000` for a long time and
icons rendered washed out and barely legible — a drive-voltage problem that
presents as a ghosting/quality problem. The `0x10000` bit is **not decoded**;
`0x31000` is simply what stock does. `0x21000` returns rc=0 and `0x31000`
returns rc=1148 from the ioctl, so the bit demonstrably changes behaviour.

### 4.6 `temp` **[unknown]** -- but see docs/22

NXP's i.MX EPDC uapi, which this struct matches field for field, defines
`TEMP_USE_AMBIENT = 0x1000`. That makes a plain `0` plausibly *0 degrees C* --
the coldest waveform band -- rather than "driver decides". Now tunable via
`persist.epdcshim.temp`; `4096` is accepted. Visual effect unconfirmed.

The field at `+0x24` we recorded as `reserved` is i.MX's **`dither_mode`**
(0 off, 1 Floyd-Steinberg, 2 Atkinson, 3 ordered, 4 quantise-only), now
`persist.epdcshim.dither`.

See `docs/22-kernel-driver-internals.md` for the driver's full ioctl surface,
its sysfs debug controls, and the `extbuf` out-of-band image path.

### 4.6.1 original note

Waveforms are temperature-indexed and the driver exposes
`onyx_epdc_fb_get_temp_index` / `onyx_epdc_read_temperature`. We send **0** in
every update and have never established whether that means "driver decides" or
the coldest band. Behaviour in a cold or hot room is unvalidated. Tracked as
issue #3 — and given how `flag` turned out, do not assume 0 is benign.

---

## 5. TCON — Lattice CertusPro-NX **[T]**

`compatible = "onyx,mxo"`, I2C **0x40**. A user-programmable FPGA, not an opaque
EPDC block — the bitstream is data, and it is re-uploadable.

Identified by three independent signals: firmware named `lfcpnx100_tcon_fw_*.bin`
(**LFCPNX** = CertusPro-NX, `100` = ~100K LUT part); the
`program_enable`/`program_init`/`program_done` GPIO trio, which is Lattice's
`PROGRAMN`/`INITN`/`DONE` configuration handshake; and `.ied` blobs, Lattice's
NVCM programming format.

`fw-product-id = <0x81>` selects the firmware. The `_XX` suffix on
`mxo{1300,4300}_nvcm_XX.ied` is a **product ID, not a version** — only the `_81`
pair applies to this board.

GPIOs (all `&tlmm`):

| line | pin | role |
|---|---|---|
| `fpga_12v_core_en_gpio` | 6 | 1.2 V core |
| `fpga_25v_en_gpio` | 48 | |
| `fpga_30v_en_gpio` | 100 | |
| `reset_gpio` | 139 | active low |
| `program_enable_gpio` | 38 | `PROGRAMN` |
| `program_init_gpio` | 9 | `INITN` |
| `program_done_gpio` | 8 | `DONE` |

Rails: `vsys` 3.0 V (L8A), `vddi2c` 1.8 V (L14A), `vdd1v8in` 1.8 V (L11A),
`vdd3vin` 3.0 V (L11E), `vdd1v2in` 1.2 V (L15A).

The DSI-side interface is standard; the TCON-to-panel side is the proprietary
part. Nothing here documents the source/gate protocol — that is inside the
bitstream.

---

## 6. EPD PMIC — TI TPS65185 **[T]**

`compatible = "TI,tps6518x"`, I2C **0x68**. Publicly documented part. Regulators:
`DISPLAY`, `VCOM`, `V3P3`, `TMST` (panel thermistor — this is what temperature
indexed waveforms depend on).

```
vpos-mV  = 0x37aa                       +14.25 V
VCOM min = 0xffbe0178  (signed)          -4.325 V
VCOM max = 0xfff85ee0  (signed)          -0.500 V

pwr_seq0 = 0xe1   pwr_seq1 = 0x30   pwr_seq2 = 0x33
upseq0   = 0xe4   upseq1   = 0x00
dwnseq0  = 0x1e   dwnseq1  = 0x00
max_wait = 0x18   delay_3v3_highv = 0x03
```

GPIOs: `gpio_pmic_pwrgood` 45, `gpio_pmic_vcom_ctrl` 46, `gpio_pmic_wakeup` 57.

⚠ **The power sequencing above must be reproduced exactly by any replacement
driver.** Getting EPD rail sequencing or VCOM wrong is not a blank screen — it
can damage the panel permanently.

---

## 7. Frontlight **[V]**

Not part of the EPD path, but the other panel-adjacent interface.

| node | range | meaning |
|---|---|---|
| `/sys/class/backlight/onyx_bl_br/brightness` | 0..32 | frontlight level |
| `/sys/class/backlight/onyx_bl_ct/brightness` | 0..32 | 0 = warm, 32 = cold |
| `/sys/class/backlight/panel0-backlight/` | 0..255 | DSI panel node, **no-op on EPD** |

Both onyx nodes read 0 after boot. The stock QTI lights HAL
(`/vendor/lib64/hw/lights.lito.so`) writes `panel0-backlight` and contains no
reference to `onyx_bl`, so Android's brightness slider drives nothing. Nothing
in `/vendor`, `/system`, `/odm`, `/product` or `/system_ext` references
`onyx_bl` at all.

Whether `ct` is a mix ratio under `br` or an independent LED string is **not yet
established** — see issues #6 and #7.

---

## 8. Related sysfs **[V]**

```
/sys/onyx_misc/cytp_lo_filter            touch low-pass filter (SF references it)
                dithering_set_debounce_delta
                dithering_set_debounce_threshold
                epdc_display_timeout
                epdc_power_timeout
```

Full attribute list: `firmware/analysis/kernel-epd-attrs.txt`.

---

## 9. Hazards

Consolidated, because each of these cost real time or a power cycle.

**`GET_EBC_BUFFER` (0x7000) blocks forever.** Proven three times, including with
SurfaceFlinger *and* the composer stopped. Nothing is logged; it is a silent
`wait_event`. Requires a hard power cycle. **Do not call it.** Use `0x7003` for
geometry and `0x700c` to submit.

**Markers must be unique** (§4.4) or the panel blanks mid-waveform.

**Wrong waveform or rail sequencing can damage the panel.** The waveform blob is
calibrated for this panel at specific temperatures; the PMIC sequencing in §6 is
not advisory.

**Plane size is checked, stride is not** (§3) — a plane one pixel off panel size
is dropped silently, and only failures are logged.

**Do not derive ioctl numbers from the upstream Rockchip header** without
checking against the device (§4.2).
