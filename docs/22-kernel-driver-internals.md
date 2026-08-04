# The Onyx EPD kernel driver, from the outside

Onyx publishes no source for their `4.19.157-perf` kernel. Everything here was
recovered from the shipped binary and from the driver's own runtime surfaces.

`docs/19` is the ABI you need to *drive* the panel. This document is about the
driver itself: where it came from, what else it can do, and which of its
capabilities we are not using.

---

## 1. How to get at it

The kernel is inside the boot image, uncompressed:

```sh
python3 - <<'EOF'
import struct
d = open("firmware/boot_b.img", "rb").read()
ksize, _, _, _, _, _, _, pagesize = struct.unpack("<8I", d[8:40])
open("kernel.bin", "wb").write(d[pagesize:pagesize + ksize])
EOF
strings -a kernel.bin | grep -oE "onyx_epdc[a-z_0-9]*" | sort -u
```

There is a gzip signature at `0x2b8c` inside it, but that is embedded data --
the image itself is a raw arm64 `Image` (ARM64 magic at offset `0x38`), so do
not try to gunzip it. 58 MiB, ~121 EPDC-related strings.

Symbol names survive because the driver logs with `__func__`. That makes the
printk strings an accidental symbol table, which is why so much is legible
without any disassembly at all.

---

## 2. Lineage: it is a hybrid

This matters, because it tells you which upstream project to read as
documentation for any given part.

| layer | origin | evidence |
|---|---|---|
| update struct | **NXP i.MX EPDC** | field-for-field match with `mxcfb_update_data`; `GLR16=4`, `GLD16=5`, `UPDATE_MODE` 0/1 |
| internals | **NXP i.MX EPDC** | symbol `epdc_LCDIF_init` -- LCDIF is i.MX's display controller |
| ioctl namespace | **Rockchip EBC** | bare `0x7000`/`0x7001`/`0x700c`, not i.MX's `_IOW('F', ...)` |

So Onyx took i.MX EPDC internals and wrapped them in a Rockchip-style character
device. Practical consequence:

> **`include/uapi/linux/mxcfb.h` from NXP's `linux-imx` is legitimate
> documentation for the struct and its semantics. It is NOT documentation for
> ioctl numbers or waveform mode indices** -- those follow Rockchip and Onyx's
> own waveform file respectively.

Fetch it with:

```sh
curl -O https://raw.githubusercontent.com/nxp-imx/linux-imx/lf-6.6.y/include/uapi/linux/mxcfb.h
```

### 2.1 What the i.MX header settles

Our reverse-engineered 40-byte struct maps exactly onto the first 40 bytes of
`mxcfb_update_data`:

```c
struct mxcfb_update_data {
    struct mxcfb_rect update_region;   /* our rect[4]                    */
    __u32 waveform_mode;
    __u32 update_mode;                 /* PARTIAL 0, FULL 1              */
    __u32 update_marker;
    int   temp;
    unsigned int flags;                /* our "flag"                     */
    int   dither_mode;                 /* WE CALLED THIS "reserved"      */
    int   quant_bit;                   /* beyond Onyx's 40 bytes         */
    struct mxcfb_alt_buffer_data alt_buffer_data;
};
```

Onyx trimmed the struct at 40 bytes -- exactly through `dither_mode`.

**Two fields we were getting wrong:**

* **`temp`.** We send `0`. i.MX defines `TEMP_USE_AMBIENT = 0x1000`, so `0` is
  plausibly *0 degrees C*, the coldest waveform band, rather than "driver
  decides". E-ink waveforms are strongly temperature compensated. Now exposed as
  `persist.epdcshim.temp`; `4096` is accepted by the driver. Visual effect
  unconfirmed.
* **`dither_mode`.** The field we called `reserved` and always wrote as 0.
  i.MX values: `0 PASSTHROUGH, 1 FLOYD_STEINBERG, 2 ATKINSON, 3 ORDERED,
  4 QUANT_ONLY`. Zero means dithering off. Now `persist.epdcshim.dither`.
  Hardware dithering, free, if Onyx kept the semantics.

`flags` does **not** decode against i.MX's set. Ours is `0x31000`; the documented
flags occupy `0x01`..`0x8000` and none of `0x1000`, `0x10000`, `0x20000` match.
The only Onyx flag name found in the binary is `EPDC_FLAG_HANDWRITE`. So Onyx
extended the flag space and `0x31000` remains undecoded -- it is simply what
stock sends.

---

## 3. The ioctl surface

Full set of names in the binary. **Numbers are known for only a few** -- the rest
need the ioctl switch disassembled.

```
EBC_BUFFER                     EBC_GAMMA_TAB
EBC_BUFFER_INFO                EBC_LUT_ENABLE
EBC_CAPTURE_ALL_BUFFER         EBC_SEND_BUFFER
EBC_CAPTURE_ALL_NAME           EBC_SEND_UPDATE          0x700c  [V]
EBC_CAPTURE_ALL_START          EBC_UPDATE_SCHEME
EBC_CAPTURE_SRART   (sic)      EBC_UPD_LIST_SIZE
EBC_CAPTURE_STOP               EBC_WAIT_ALL_UPDATE_COMPLETE
EBC_CLEAR_ALL_UPDATE           EBC_EXTBUF_SYNC_FB_ENABLE
EBC_DRIVER_SN       0x7002 [V] EBC_FORCE_WAVEFORM
EBC_DRIVER_VERSION_
```

Known numbers from `docs/19`: `GET_EBC_BUFFER 0x7000` (**never call it -- blocks
forever**), `SET_EBC_SEND_BUFFER 0x7001`, `GET_EBC_DRIVER_SN 0x7002`,
`GET_EBC_BUFFER_INFO 0x7003`, `SET_EBC_SEND_UPDATE 0x700c`.

`EBC_UPDATE_SCHEME` matches i.MX's `UPDATE_SCHEME_SNAPSHOT/QUEUE/QUEUE_AND_MERGE`.
Boot logs report `upd_scheme[2]` -- **QUEUE_AND_MERGE** -- so the driver already
merges overlapping updates. Onyx added a fourth, `UPDATE_SCHEME_HANDWRITE`,
paired with `EPDC_FLAG_HANDWRITE`.

---

## 4. Runtime surfaces we did not know existed

### 4.1 `/sys/devices/virtual/sepdc/debug/`

```
cut_frame_num   debug_level    dump_list      night_mode
panel_clean     panel_init     panel_last     power
reset_test      status         submit_upd_work
```

Permissions matter: `panel_clean`, `panel_init`, `panel_last` are **read-only
with `show_` handlers, so READING them performs the action** and returns `ok`.
`night_mode` and `submit_upd_work` are write-only.

**`debug_level` corrects `docs/11`.** That document states the driver's commit
logging is "gated on a debug flag with no debugfs and no module param". There is
a sysfs knob:

```sh
adb shell 'echo 4 > /sys/devices/virtual/sepdc/debug/debug_level'
```

At level 4 the driver emits internals such as
`_o_e_p_w_s(): epdc_free_luts[0x0][0x0][0x0][0x1]`. We spent a long time
reasoning about a path we could have watched directly.

`status` is a good one-shot health dump:

```
epdctask_status[0] wf_status[99] wftask_status[0] wb_status[30]
epdc_active_luts[0x0][0x0][0x0][0x0] all_frames_completed[0]
frame[88925:88925:88925]
```

`night_mode` does **not** touch the frontlight LEDs -- tested, `onyx_bl_br` and
`onyx_bl_ct` unchanged. It is a display-side mode.

### 4.2 `waveform_version`

`/sys/devices/platform/onyx_epdc_fb.0/waveform_version`.

### 4.3 The waveform mode table is printed at boot

```
get_glr16_mode_index(): gc16[2] glr16[4] gld16[5] a2[6]
                        gcc16[-1] glrc16[-1] glr16nm[9] glr16plus[8]
```

Indices belong to the **loaded `.wbf`**, not to the hardware. `-1` means the mode
is absent from this unit's waveform file. See `docs/19` for measured behaviour.

---

## 5. `extbuf` -- an out-of-band image path

The most consequential finding, and the least explored.

```
onyx_tcon_display_extbuf
onyx_tcon_display_extbuf_backup_from_fb
onyx_epdc_ext_buf_sync_with_fb
_onyx_epdc_extbuf_convert_gray
EBC_EXTBUF_SYNC_FB_ENABLE

"extbuf[%p] width[%d] height[%d] convert_gray[%d]"
"commit extbuf sync frame."
"sync extbuf tcon_fb to tcon"
"last update is extbuf, so skip queue_work sync_submit_work!"
"SET_EBC_EXTBUF_SYNC_FB_ENABLE set fb_update_time[%lld]."
```

A caller appears able to hand the driver a buffer with dimensions, have it
converted to greyscale, and displayed on the TCON -- with no compositor
involved.

**This may overturn a constraint we have treated as fundamental.** Both
`docs/11` and `epdcd/docs/ARCHITECTURE.md` state that out-of-band panel writes
are impossible because `/dev/ebc` refreshes from a framebuffer nothing in our
stack writes -- which is true, and is what blanked the panel when the settle pass
was enabled (issue #2). But the conclusion drawn from it was too broad. The
problem was writing the *wrong buffer*; `extbuf` looks like the buffer a client
is supposed to supply.

If it works it would give us:

1. a lock screensaver with no compositing race and no wakelock (issue #14),
2. a correct settle pass (issue #2),
3. a daemon that can drive the panel directly, contradicting the "policy only"
   split in `epdcd`'s architecture document.

Unknown: the ioctl numbers, the buffer format and stride, and whether
`SYNC_FB_ENABLE` must be set first. All of it needs the ioctl switch in
`onyx_epdc_fb` disassembled -- the same technique that produced the numbers we
already have.

---

## 6. Other capabilities we are not using

* **`EBC_FORCE_WAVEFORM`** -- force a mode independent of the per-update field.
* **`EBC_LUT_ENABLE`**, **`EBC_GAMMA_TAB`** -- LUT and gamma control.
* **`EBC_CAPTURE_ALL_*`** -- capture what the panel is actually showing. This is
  the instrument we lacked all along: `screencap` proves the framework
  composited, never what reached the glass.
* **`EBC_CLEAR_ALL_UPDATE`**, **`EBC_WAIT_ALL_UPDATE_COMPLETE`**,
  **`EBC_UPD_LIST_SIZE`** -- queue management, relevant to the throttling the
  shim currently does by wall-clock guesswork.
* **`onyx_epdc_set_pwrdown_delay`** -- panel power-down delay, i.MX's
  `MXCFB_SET_PWRDOWN_DELAY`. Directly relevant to the screensaver: a longer delay
  may keep the panel powered long enough to composite a frame without any
  wakelock.
* **`onyx_epdc_put_last_image`** / `panel_last` -- redisplays the driver's own
  last image. A restore mechanism, not a way to supply one.
* **`onyx_epdc_read_temperature`** / **`onyx_epdc_set_temp`** -- the temperature
  path behind issue #3.

---

## 7. Open questions

1. `extbuf` ioctl numbers and buffer format (section 5).
2. What `flag = 0x31000` means. Undecoded against i.MX; `EPDC_FLAG_HANDWRITE` is
   the only Onyx flag name recovered.
3. Whether `temp = TEMP_USE_AMBIENT` improves anything visually.
4. Whether `dither_mode` is honoured.
5. Why `glr16` (mode 4) is accepted but stalls, while `a2` (6) works. Adding
   i.MX's `EPDC_FLAG_USE_REGAL` (`0x8000`) did not fix it -- tested.
6. `EBC_CAPTURE_ALL_*` as a way to verify panel contents directly.

---

## 8. Locating the ioctl handler (partial)

The handler is at **`0x0057a000`-`0x0057e000`** in `kernel.bin` (file offsets, raw
arm64 Image extracted per section 1). Every case logs its own name, so the code
is self-labelling:

```
code@0x0057c194 -> "%s(): SET_EBC_SEND_UPDATE"
code@0x0057c1a4 -> "%s(): GET_EBC_BUFFER"
code@0x0057c224 -> "%s(): SET_EBC_SEND_BUFFER"
code@0x0057c3c4 -> "%s(): GET_EBC_DRIVER_SN"
code@0x0057c43c -> "%s(): GET_EBC_BUFFER_INFO"
code@0x0057c4f4 -> "%s(): SET_EBC_LUT_ENABLE"
code@0x0057c510 -> "%s(): -- SET_EBC_CLEAR_ALL_UPDATE"
code@0x0057c5a4 -> "%s(): -- SET_EBC_WAIT_ALL_UPDATE_COMPLETE"
code@0x0057c6b4 -> "%s(): SET_EBC_CAPTURE_STOP"
code@0x0057cd9c -> "%s(): SET_EBC_GAMMA_TAB"
code@0x0057cf8c -> "%s(): SET_EBC_CAPTURE_SRART"
code@0x0057da44 -> "%s(): SET_EBC_UPDATE_SCHEME"
```

### How these were found

Format strings are referenced by `ADRP` + `ADD` pairs. Compute the target in
**file-offset space** -- PC-relative arithmetic is invariant under the fixed
file-offset-to-VA shift, so no load address is needed:

```python
# ADRP
imm = ((instr >> 5) & 0x7FFFF) << 2 | ((instr >> 29) & 3)
if imm & (1 << 20): imm -= (1 << 21)
base = (offset & ~0xFFF) + (imm << 12)
# ADD (imm, 64-bit, sh=0):  target = base + imm12
```

**Match the START of the containing C string, not the `EBC_...` substring.** The
code references `"%s(): SET_EBC_SEND_UPDATE"`, so searching for `EBC_` offsets
finds nothing -- walk back to the preceding non-printable byte first. That
mistake cost a full scan.

### What is still missing

The ioctl **numbers**. Only two `MOVZ #0x70xx` immediates appear in the handler
range, far fewer than there are cases, so the compiler normalised the switch --
almost certainly `sub w, w, #0x7000` followed by a jump table on the small
remainder. Recovering the mapping means decoding that dispatch, not pattern
matching immediates.

Known numbers remain those in `docs/19`: `0x7000` (**never call -- hangs**),
`0x7001`, `0x7002`, `0x7003`, `0x700c`.

**Do not guess and probe.** `0x7000` blocks forever and needs a hard power cycle,
and several unknown commands (`CLEAR_ALL_UPDATE`, `LUT_ENABLE`, `GAMMA_TAB`,
`panel_init`) could disturb or misconfigure the panel. Read the jump table.

### 8.1 The jump table, decoded

The switch dispatch is at `0x0057a9b4`:

```
0x0057a9b4  sub  w8, w1, #0x7000        ; normalise cmd
0x0057a9b8  cmp  w8, #0x11d             ; 286 slots
0x0057a9c4  b.hi 0x0057aa74             ; default
0x0057a9c8  adrp x9, 0x01923000
0x0057a9cc  add  x9, x9, #0x918         ; table @ 0x01923918
0x0057a9d0  adr  x10, 0x0057a9e0        ; branch base
0x0057a9d4  ldrh w11, [x9, x8, lsl #1]  ; 16-bit entries
0x0057a9d8  add  x10, x10, x11, lsl #2
0x0057a9dc  br   x10
```

So, in file-offset space:

```python
target = 0x0057a9e0 + u16_at(0x01923918 + (cmd - 0x7000) * 2) * 4
```

**46 real cases**; the other 240 slots point at the default (`0x0057e654`).
Valid command numbers are **`0x7000`-`0x7029`** and **`0x7118`-`0x711d`**
(`0x7005` and `0x7028` are absent).

Confirmed correct -- these four reproduce the numbers `docs/19` already had from
independent disassembly, which validates the method:

| ioctl | target | name |
|---|---|---|
| `0x7000` | `0x0057c19c` | `GET_EBC_BUFFER` -- **never call, hangs** |
| `0x7001` | `0x0057c21c` | `SET_EBC_SEND_BUFFER` |
| `0x7002` | `0x0057c3bc` | `GET_EBC_DRIVER_SN` |
| `0x7003` | `0x0057c434` | `GET_EBC_BUFFER_INFO` |
| **`0x7004`** | `0x0057c4ec` | **`SET_EBC_LUT_ENABLE`** (new) |

The remaining 41 case targets are known but **not yet mapped to names**, because
most case blocks do not log a name at their entry point -- the printk sits deeper
inside a branch. Finishing the job means disassembling each block from its target
address; the addresses are the hard part and they are now in hand.

Do **not** infer numbers from the order in which name strings appear in the
binary: `GET_EBC_DRIVER_SN` (`0x7002`) appears *after* `GET_EBC_BUFFER_INFO`
(`0x7003`) in rodata, so string order does not follow the enum.

One caution on a tempting result: the block at `0x0057bb40` (`0x711d`) contains a
`SET_EBC_SEND_UPDATE` reference, but `docs/19` records `SEND_UPDATE` as `0x700c`
from disassembly, and the shim uses `0x700c` and works. The last block has no
successor to bound it, so that association is probably an artefact of the block
running past its real end. Treat it as unresolved rather than a correction.

### 8.2 Case targets, unnamed

```
0x7006 0x0057a9e0   0x7013 0x0057c5c8   0x7020 0x0057b4ac
0x7007 0x0057ab0c   0x7014 0x0057af38   0x7021 0x0057b538
0x7008 0x0057ab74   0x7015 0x0057afb0   0x7022 0x0057b5c4
0x7009 0x0057abf4   0x7016 0x0057c668   0x7023 0x0057b62c
0x700a 0x0057ac18   0x7017 0x0057b030   0x7024 0x0057b6bc
0x700b 0x0057ac98   0x7018 0x0057b0bc   0x7025 0x0057b73c
0x700c 0x0057ad18   0x7019 0x0057b13c   0x7026 0x0057b7bc
0x700d 0x0057ad30   0x701a 0x0057b25c   0x7027 0x0057b83c
0x700e 0x0057adac   0x701b 0x0057c6ac   0x7029 0x0057b8ac
0x700f 0x0057c508   0x701c 0x0057b32c   0x7118 0x0057b8d0
0x7010 0x0057c588   0x701d 0x0057b33c   0x7119 0x0057b9c0
0x7011 0x0057ae2c   0x701e 0x0057b398   0x711a 0x0057b9d8
0x7012 0x0057aeac   0x701f 0x0057b418   0x711b 0x0057ba44
                                        0x711c 0x0057bac4
                                        0x711d 0x0057bb40
```

`0x700c` is `SET_EBC_SEND_UPDATE` per `docs/19`, so its block is `0x0057ad18`.
That is a useful anchor: the neighbouring blocks in the `0x0057axxx` range are
its siblings in the source, which is where `EXTBUF_SYNC_FB_ENABLE`,
`FORCE_WAVEFORM`, `UPDATE_SCHEME` and `UPD_LIST_SIZE` most likely live.

### 8.3 Resolved ioctl numbers (PARTLY WRONG -- see 8.5)

Case blocks are **prologues that branch into shared implementation code**, which
is why they carry no name string at their entry point -- `0x700c` sets up state
and then `b 0x0057bda0`. Mapping them therefore needs a reachability trace, not a
proximity guess: walk forward from each case target following `b`, `b.cond`,
`cbz/cbnz`, `tbz/tbnz` and fallthrough, and record any `ADRP`+`ADD` that
references a `SET_EBC_*` / `GET_EBC_*` string.

| ioctl | name | |
|---|---|---|
| `0x7000` | `GET_EBC_BUFFER` | **never call -- blocks forever** |
| `0x7001` | `SET_EBC_SEND_BUFFER` | |
| `0x7002` | `GET_EBC_DRIVER_SN` | |
| `0x7003` | `GET_EBC_BUFFER_INFO` | |
| `0x7004` | `SET_EBC_LUT_ENABLE` | |
| `0x7006` | `SET_EBC_UPDATE_SCHEME` | i.MX schemes + Onyx's HANDWRITE |
| `0x700c` | `SET_EBC_SEND_UPDATE` | the working submit |
| `0x700f` | `SET_EBC_CLEAR_ALL_UPDATE` | |
| `0x7010` | `SET_EBC_WAIT_ALL_UPDATE_COMPLETE` | |
| `0x7014` | `SET_EBC_GAMMA_TAB` | |
| `0x7016` | `SET_EBC_UPD_LIST_SIZE` | queue depth |
| `0x7018` | `SET_EBC_CAPTURE_SRART` | (sic) capture start |
| `0x701b` | `SET_EBC_CAPTURE_STOP` | |
| **`0x701f`** | **`SET_EBC_EXTBUF_SYNC_FB_ENABLE`** | **the out-of-band path, section 5** |
| `0x711b` | `GET_EBC_CAPTURE_ALL_NAME` | |
| `0x711c` | `GET_EBC_CAPTURE_ALL_BUFFER` | read back what the panel shows |

**Validation.** Five of these -- `0x7000`, `0x7001`, `0x7002`, `0x7003` and
`0x700c` -- reproduce numbers `docs/19` obtained independently by disassembly.
`0x700c` is the strongest check: the shim uses it every frame and the display
works.

This also resolves the caution in section 8.1: `SEND_UPDATE` is `0x700c`, not
`0x711d`. The `0x711d` association was an artefact of the final block having no
successor to bound it, exactly as suspected. **`0x711d` remains unidentified.**

`EBC_FORCE_WAVEFORM` did not resolve -- its name string is referenced from code
no case block reaches within the trace budget, so it is probably called from a
different entry point (a sysfs store, or an internal caller) rather than from the
ioctl switch.

Remaining unnamed cases: `0x7007`-`0x700b`, `0x700d`, `0x700e`, `0x7011`-`0x7013`,
`0x7015`, `0x7017`, `0x7019`, `0x701a`, `0x701c`-`0x701e`, `0x7020`-`0x7027`,
`0x7029`, `0x7118`-`0x711a`, `0x711d`. Their targets are listed in section 8.2.

### 8.4 What to try next with `0x701f`

`SET_EBC_EXTBUF_SYNC_FB_ENABLE` is a *setter*, so it presumably takes a flag or a
small struct rather than an image. The likely sequence is: enable sync, then hand
over a buffer via `SET_EBC_SEND_BUFFER` (`0x7001`) or the extbuf path, then
submit. The printk `"extbuf[%p] width[%d] height[%d] convert_gray[%d]"` shows the
driver expects pointer, dimensions and a greyscale-conversion flag.

If enabling it makes `/dev/ebc` reflect the real framebuffer, that alone would
fix the settle pass (issue #2), which blanked the panel precisely because the EBC
buffer held nothing.

Probe carefully and one ioctl at a time, with `debug_level 4` set so the driver
narrates what it receives. Do not call `0x7000`.

### 8.5 Ground truth: ask the driver

**Supersedes the reachability results in 8.3.** At `debug_level 2` the driver
names every ioctl it receives:

```sh
adb shell 'echo 2 > /sys/devices/virtual/sepdc/debug/debug_level'
# then, per command:  dmesg -c; <call>; dmesg | grep epdc_ioctl
```

That beats any static analysis, and it corrected the reachability mapping: of the
six numbers checked against it, four held and **two were wrong**. Reachability
follows branches into shared implementation code that many cases reach, so a name
found along the way is not necessarily *this* case's name.

Confirmed by the driver itself:

| ioctl | driver says |
|---|---|
| `0x7002` | `GET_EBC_DRIVER_SN` -> `ONYX_EBC_DRIVER_VERSION_2.00` |
| `0x7003` | `GET_EBC_BUFFER_INFO` -> geometry 1648x824 |
| `0x7004` | `SET_EBC_LUT_ENABLE` |
| `0x7008` | `set waiting_for_all_lut_free` |
| **`0x700a`** | **`set reagl_enable[N]`** -- REAGL, the Regal feature |
| **`0x700b`** | **`set force_waveform = N`** -- `EBC_FORCE_WAVEFORM` |
| `0x700c` | `SET_EBC_SEND_UPDATE` (matches `docs/19`) |
| `0x700f` | `SET_EBC_CLEAR_ALL_UPDATE` |
| `0x7010` | `SET_EBC_WAIT_ALL_UPDATE_COMPLETE` |
| `0x7013` | `capture from buf_gray[...]` |
| **`0x7016`** | `SET_EBC_UPD_LIST_SIZE val=N` **and `pwrdown_delay=N`** |
| `0x7018` | `SET_EBC_CAPTURE_SRART` -- allocates 12 capture buffers |
| `0x701b` | `SET_EBC_CAPTURE_STOP` |
| **`0x7026`** | **`enable cfa mode`** -- Colour Filter Array |

**~~Disproved:~~ WRONG -- retracted, see section 9.2.** This section claimed
`0x7006` is not `UPDATE_SCHEME` and `0x701f` is not `EXTBUF_SYNC_FB_ENABLE`,
because neither logged anything at `debug_level 2`. Both claims are false.
`0x7006` **is** `SET_EBC_UPDATE_SCHEME`, verified on the device: it logs
`o_e_f_s_u_s(): Setting upd scheme level to 3! ... OK!` and the driver's
behaviour changes accordingly.

The error was in the method, not the reading. Two things defeat it:

* The confirmation is printed by **`onyx_epdc_fb_set_upd_scheme()`**, which logs
  under the abbreviated name `o_e_f_s_u_s()`. Filtering `dmesg` for `epdc_ioctl`
  -- as 8.5's recipe says to -- cannot see it.
* `debug_level` is **a multi-byte bitmask, not a level.** `SET_EBC_UPDATE_SCHEME`'s
  second message is gated on bit 0 of the byte at `epdc_debug_level`; the
  `HANDWRITE_UPDATE` message is gated on bit 4 of `epdc_debug_level + 1`. Writing
  `2` sets neither. [D]

So "no output at `debug_level 2`" never proved a command was unimplemented, and
should not have been allowed to override a static result. The lesson is the one
in `CLAUDE.md` -- *absence of log lines proves nothing* -- applied here to a
method that had been introduced precisely to be ground truth.

Silent numbers (no log, may still be implemented): `0x7001`, `0x7006`, `0x7007`,
`0x7009`, `0x700d`, `0x700e`, `0x7011`, `0x7012`, `0x7014`, `0x7015`, `0x7017`,
`0x7019`, `0x701a`, `0x701c`-`0x7025`, `0x7027`, `0x7029`, `0x7118`-`0x711d`.

Three of these are worth pursuing:

* **`0x700a reagl_enable`** -- `glr16` (mode 4) is accepted but stalls (`docs/19`).
  REAGL is exactly the feature Regal waveforms need, so this may be the missing
  piece, and would give a 16-grey fast mode instead of A2's binary flicker.
* **`0x700b force_waveform`** -- forces a mode independent of the per-update field.
* **`0x7016 pwrdown_delay`** -- the panel power-down delay. The SystemUI
  screensaver failed because `mScreenState=OFF` before anything composited; this
  is the knob that governs that, and it is an ioctl, not a framework API.

### 8.6 Two ways this crashes the device

Both were hit while probing, both recoverable, both worth avoiding.

1. **Passing a small argument to a setter.** `long v; ioctl(fd, cmd, &v)`
   **rebooted the device**. These commands expect sizeable structs and
   `copy_from_user` reads whatever follows an 8-byte local -- stack garbage
   interpreted as pointers and lengths. Always hand over a **zeroed page**. After
   that change roughly forty probes ran clean.
2. **`reagl_enable=1` followed by driving `glr16`** left the device unresponsive
   over adb and needing a power cycle. Change one of these at a time, and expect
   to power-cycle when experimenting with Regal.

3. **Probing with a non-zero payload corrupts display state.** Sweeping
   unidentified commands with `4321` in slot 0 -- to find which one moved
   `pwrdown_delay` -- left the panel rendering **inverted**, black for white.
   `0x7014` (a `GAMMA_TAB` candidate) and `0x7026` (`enable cfa mode`) are the
   likely culprits: garbage in a gamma table, or a colour-filter remap on a panel
   with no colour filter, will both scramble the level mapping.

   Recovered completely by a reboot. Driver state -- gamma, LUTs, `reagl_enable`,
   `cfa` -- is **not** persistent, which makes reboot the reliable undo for
   anything probing breaks.

   Probe with **zero** unless there is a reason not to. A zero payload still
   reaches the case and still gets logged, which is all the identification needs.

And still: **never call `0x7000`**. It blocks forever.

### 8.6.1 Commands known to change display state

Identify these from the log, do not experiment with them casually:
`0x7004` `LUT_ENABLE`, `0x700a` `reagl_enable`, `0x700b` `force_waveform`,
`0x7014` (gamma candidate), `0x7026` `enable cfa mode`. Also `0x7018`
`CAPTURE_SRART`, which allocates twelve capture buffers -- pair it with `0x701b`
`CAPTURE_STOP`.

### 8.7 `pwrdown_delay` and `extbuf`: both dead ends via ioctl

Two leads from section 6 were chased to the end and did not pay off. Recording
them so nobody spends the time again.

**`pwrdown_delay` is readable but not settable.** `0x7016` logs
`SET_EBC_UPD_LIST_SIZE val = N!pwrdown_delay = N!`, which reads like it carries
both. It does not. Poking a distinctive value into each 32-bit slot of the
argument in turn shows only slot 0 is consumed -- it is `val`, the list size --
and `pwrdown_delay` is merely *printed* alongside. Its value on this device is
**0**.

That log line is a useful read-back channel, though: call `0x7016` after any
other command to see whether the delay moved. Sweeping every unidentified number
in `0x7006`-`0x7029` that way changed it from 0 exactly never. So no ioctl in the
switch sets it, despite `onyx_epdc_set_pwrdown_delay` existing as a symbol, and
no sysfs file exposes it either (`find /sys -iname "*pwrdown*"` finds only an
unrelated DVB parameter).

**~~`extbuf` is not reachable by ioctl at all.~~ Superseded by section 9.4.** The
conclusion rested on the same broken evidence as 8.5 -- silence at `debug_level 2`
-- so it does not stand. More importantly it no longer matters: `extbuf` was only
ever wanted as *a way to draw without the compositor*, and there is a better one.
`/dev/ebc` has an `mmap`, it hands back a full-size writable panel buffer, and
`0x7006` switches the driver into the mode that reads it. Section 9 documents
that path end to end.

**Consequence for the lock screensaver (issue #14).** No longer blocked on the
driver. The remaining question is a framework one -- getting something to run at
the right moment during the going-to-sleep transition -- not a "there is no way
to put pixels on the panel" one.

---

## 9. Symbolising the running kernel

Sections 1-8 worked in raw file offsets, because the kernel `Image` carries no
symbol table. That constraint was self-imposed: the symbol table is available,
just not in the file.

### 9.1 The two halves

`/proc/kallsyms` on the running device names every kernel address. It reads as
all-zeros by default; `kptr_restrict` gates it and root can lower the gate.

```sh
adb root
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
adb shell 'cat /proc/kallsyms' > kallsyms.txt      # ~144k symbols
```

`_text` lands at `0xffffffa3f5e80000`, and the raw arm64 `Image` maps `_text` to
file offset 0, so:

```
file_offset = kallsyms_address - 0xffffffa3f5e80000
```

**Check the base rather than trusting it.** `epdc_ioctl` resolves to `0x57a988`;
disassembling there gives a clean prologue (`sub sp, sp, #0x110`) and, `0x2c`
later, exactly the jump-table dispatch section 8.1 found by hand. Two independent
derivations landing on the same byte is what makes the mapping trustworthy. [V]

### 9.2 The kernel in `firmware/analysis/` is the wrong build

The base above *fails* against `firmware/analysis/kernel.Image` -- `epdc_ioctl`
lands mid-function, `0x80` off, and call targets resolve to nonsense like
`max17135_resume+0x48`. That drift is not a bad base. It is two different
kernels:

| | git | build | date |
|---|---|---|---|
| running on the device | `g3d47a6619220` | **#245** | 2026-04-10 |
| `firmware/analysis/kernel.Image` | `g8b1b2dc01cc9` | **#147** | 2025-12-26 |

Compare `/proc/version` against `strings -a <image> | grep 'Linux version'`
before doing anything with an extracted kernel. Two builds of the same driver
have most functions at almost the same place, which is exactly what makes the
mismatch hard to notice and easy to build wrong conclusions on.

Extract the one that is actually running:

```sh
adb shell 'dd if=/dev/block/by-name/boot_b of=/data/local/tmp/boot_b.img bs=1M count=96'
adb pull /data/local/tmp/boot_b.img && adb shell 'rm /data/local/tmp/boot_b.img'
# header v2: kernel_size at +8, page_size at +36, kernel starts at page_size
```

`scripts/kdis.py` does the disassembly, resolving branch targets and `ADRP`+`ADD`
pairs to names. It also has `-s <regex>` to search symbols and `-w <symbol>` to
find callers.

### 9.3 The complete ioctl table

With exact offsets the jump table decodes without ambiguity:

```
sub  w8, w1, #0x7000
cmp  w8, #0x11d              ; 286 entries
adrp x9, 0x1923000 ; add x9, x9, #0x918
adr  x10, 0x57a9e0
ldrh w11, [x9, x8, lsl #1]
add  x10, x10, x11, lsl #2 ; br x10

target = 0x57a9e0 + u16_at(0x1923918 + (cmd - 0x7000) * 2) * 4
```

286 entries, 47 distinct targets, one of which is the default case shared by 240
commands -- so **46 real commands**, in two ranges: `0x7000`-`0x7029` and
`0x7118`-`0x711d`. The second range was missed entirely by the runtime probe. [D]

Names recovered by walking each case's control-flow graph and collecting the
message strings it can reach:

| ioctl | name | notes |
|---|---|---|
| `0x7000` | `GET_EBC_BUFFER` | **never call -- blocks forever** |
| `0x7001` | `SET_EBC_SEND_BUFFER` | |
| `0x7002` | `GET_EBC_DRIVER_SN` | `ONYX_EBC_DRIVER_VERSION_2.00` |
| `0x7003` | `GET_EBC_BUFFER_INFO` | |
| `0x7004` | `SET_EBC_LUT_ENABLE` | changes display state |
| `0x7006` | `SET_EBC_UPDATE_SCHEME` | **[V]** -- see 9.4 |
| `0x7008` | `set waiting_for_all_lut_free` | |
| `0x700a` | `set reagl_enable` | changes display state |
| `0x700b` | `set force_waveform` | changes display state |
| `0x700c` | `SET_EBC_SEND_UPDATE` | the working submit; also `HANDWRITE_UPDATE` |
| `0x700f` | `SET_EBC_CLEAR_ALL_UPDATE` | |
| `0x7010` | `SET_EBC_WAIT_ALL_UPDATE_COMPLETE` | |
| `0x7013` | capture read (`from epd_buffer` / `from buf_gray`) | |
| `0x7014` | `SET_EBC_GAMMA_TAB` | changes display state |
| `0x7016` | `SET_EBC_UPD_LIST_SIZE` | prints `pwrdown_delay`, does not set it |
| `0x7018` | `SET_EBC_CAPTURE_SRART` | (sic) allocates capture buffers |
| `0x701b` | `SET_EBC_CAPTURE_STOP` | |
| `0x701f` | `SET_EBC_EXTBUF_SYNC_FB_ENABLE` | [D] |
| `0x7024` | `cut_frame_num` | must be 3..5; also in sysfs |
| `0x7025` | transform / rotation | |
| `0x7026` | `enable cfa mode` | changes display state |
| `0x711b` | `GET_EBC_CAPTURE_ALL_NAME` | |
| `0x711c` | `GET_EBC_CAPTURE_ALL_BUFFER` | read back what the panel shows |

Still unnamed: `0x7007`, `0x7009`, `0x700d`, `0x700e`, `0x7011`, `0x7012`,
`0x7015`, `0x7017`, `0x7019`, `0x701a`, `0x701c`-`0x701e`, `0x7020`-`0x7023`,
`0x7027`, `0x7029`, `0x7118`-`0x711a`, `0x711d`. Their case bodies are reachable
but print nothing that names them.

### 9.4 Drawing without the compositor

This is what sections 5, 8.4 and 8.7 were reaching for, and it works.

**`/dev/ebc` has an mmap.** [V]

```
epdc_mmap @ 0x57e690:
    vma->vm_flags &= ~0x3c ; |= 0x80000
    if (g[0x2bb8] == NULL) { printk("no virt_buf_handwrite!"); return -1; }
    return dma_buf_mmap(g[0x2bc8], vma, 0)
```

On the device it maps **5431808 bytes = 1648 x 824 x 4**, the driver logs
`[virt_buf_handwrite] [system ion] size: 0x52f000`, the contents start as all
`0xff`, and the memory is **writable from userspace**. It is the handwriting
fast path's buffer, which is why nothing on the normal display path touches it.

**The driver only reads it in scheme 3.** `onyx_epdc_scheme_is_handwrite()` at
`0x5799f8` is exactly `g[0x2c50] == 3`, and the boot log says the driver starts
at `upd_scheme[2]`. Switch with `0x7006`, passing a pointer to an `int`. While
scheme 3 is set the driver **rejects ordinary updates**, so the compositor cannot
paint -- switch back as soon as the frame is submitted.

**An update must opt in via flags bit 18.** From `epdc_ioctl`, right after the
struct is copied in:

```
bl   __arch_copy_from_user   ; dst = sp+0x40, len = 0x28   (40 bytes)
ldr  w8, [sp, #0x60]         ; sp+0x40 + 0x20 -> byte 32 -> flags
tbz  w8, #0x12, <reject>     ; bit 18 clear -> "reject non HANDWRITE update"
```

Byte 32 lands exactly on `flags` in the 40-byte layout, which independently
confirms the struct. Without bit 18 the driver takes the ordinary path, sees
scheme 3, and refuses -- observed verbatim on the first attempt:

```
epdc_ioctl(): ERROR! Now is SCHEME_HANDWRITE, reject non HANDWRITE update!!
  SET_EBC_SEND_UPDATE -- magic[18519] [x=0 y=0 w=1648 h=824]!waveform[2] flags[0x31000]
```

With `flags = 0x31000 | 0x40000` the rejection stops and the driver advances its
frame counter. `src/ebchandwrite.c` is the whole sequence; it restores the scheme
on every exit path.

**The buffer is in output space, and is not rotated.** [V] Filling it with bands
that vary along buffer-`y` produces bands that read as horizontal with the device
held in **landscape**. So the mapping is one-to-one onto the panel as 1648 wide
by 824 tall, with no transform of the driver's own.

Everything else in this project authors content in **layer-stack space**, which
is portrait 824 x 1648 (`docs/19`) -- including `scripts/gen-screensaver.py`. So
content written through this path has to be turned a quarter turn on the way in.
`src/ebcshow.c` does that; the correct angle is **270**, established by looking
at the panel. [V]

Both 90 and 270 produce a correctly proportioned frame that fills the panel, so
nothing about the geometry distinguishes them and no amount of reasoning about
buffer strides will -- 90 simply comes out upside down. This is the opposite of
the usual trap: the compositor path hides the rotation entirely, and this one
does not.

### 9.4.2 The first handwrite update always ghosts

A single GC16 pass leaves the previous screen clearly visible through the new
one. Confirmed on the panel, and it is not a coverage problem -- the driver
reports the update it ran as `[l=0 t=0 w=1648 h=824]` (section 9.4.1). Nor is it
the compositor repainting: it persists for as long as scheme 3 is held, with
ordinary updates rejected the whole time.

The cause is state tracking: the driver drives each pixel as a **transition from
what it believes is currently displayed**, and after the compositor has been
drawing, its belief is wrong.

**The fix is to flash the panel, and only that works.** [V] Drive every pixel to
full black, then to full white, then to the image -- three full-panel passes
inside one hold of scheme 3. `src/ebcshow.c` does this by default and it removes
the ghosting completely. Cost is roughly 1.1s and it is visibly ugly, which is
fine at screen-off and wrong for anything frequent.

Three cheaper things were tried on the panel and **all three still ghost**:

| attempt | what it touches | result |
|---|---|---|
| `0x701d` sync from framebuffer | the source buffer | ghosts |
| `panel_clean` sysfs | cleans via the normal path | ghosts |
| `cut_frame_num` 3 -> 5 | waveform length | ghosts, 33 frames either way |

The sync result is the informative one, because it is not a case of the ioctl
doing nothing. Stamping the whole mapping with `0xaa`, calling `0x701d`, and
reading back shows **0% of the stamp survives** -- the driver genuinely rewrites
the entire buffer from the live framebuffer. So before the update, the buffer and
the glass agreed, and it ghosted anyway.

**That rules out the obvious explanation.** The driver's transition source is
*not* the buffer we mmap, so seeding that buffer cannot help however correct it
is. An earlier revision of this section blamed the mmap'd buffer's stale contents
and recommended the flash on that basis; the recommendation was right and the
reasoning was wrong.

What fits all four results is a **handwrite-specific record** of the displayed
image, refreshed only by handwrite updates. Compositor drawing maintains a
different one, `panel_clean` cleans through the normal path, and the sync writes
the source rather than the record -- none of them reach it. Driving both rails
*through the handwrite path itself* is the only thing that does, which is why the
flash is not a workaround here but the actual mechanism.

**The prediction that follows from it holds.** [V] If the record is
handwrite-specific and only handwrite updates refresh it, then one flash should
be enough and everything after it should be clean. Drawing one image with the
flash and then a *different* image with `mode 0` -- no flash, no sync, no clean
-- gives a clean second image with no trace of the first.

So the flash is a **once-per-session** cost, not a per-frame one:

* first handwrite draw after the compositor has been running -> flash (~1.1s,
  visibly ugly, unavoidable)
* every draw after that -> one pass, ~450ms, no flicker

which is what makes this usable for anything that updates periodically rather
than only for a single screensaver frame.

**Consequences.** This is the missing primitive for the lock screensaver (#14),
for a settle pass after motion, and for anything `epdcd` wants to draw on its
own. It also explains issue #2 completely: `EBC_SEND_UPDATE` blanked the panel
because the buffer it paints from was never written -- and now it can be.

**Proof that the update is ours, not ambient activity.** The `frame[]` counter in
`sysfs` gives a clean three-way control: [V]

| condition | frames driven |
|---|---|
| idle, no update, 3s | 0 |
| `flags = 0x31000` (bit 18 clear) | 0 |
| `flags = 0x71000` (bit 18 set) | 33 |

The idle row is what makes the other two mean anything -- without it, "33 frames"
could have been the launcher redrawing.

**Tools.** `src/ebcmmap.c` probes the mapping read-only. `src/ebchandwrite.c` is
the minimal experiment. `src/ebcshow.c` is the usable form: it takes the 8-bit
greyscale plane that `gen-screensaver.py OUT.raw` emits, rotates it, and shows
it.

### 9.4.1 `debug_level` is an integer of bit flags

`echo 1..32` into `debug_level` does **not** enable the handwrite logging; the
gate is bit 4 of the byte at `epdc_debug_level + 1`, so the value needed is
`0x10 << 8`:

```sh
adb shell 'echo 4096 > /sys/devices/virtual/sepdc/debug/debug_level'
```

which produces the line that settles what the driver actually ran: [V]

```
epdc_ioctl(): HANDWRITE_UPDATE magic[68090369] handwrite_time[...]
  waveform[2] flags[0x71000] [l=0 t=0 w=1648 h=824] !
```

Two things fall out of it. The rect is the **whole panel**, so the handwrite path
is not clamping the update -- when the image looks like it is mixed with the old
screen, that is the compositor repainting after scheme 2 is restored, not a
coverage failure. And `magic` comes back as `68090369`, not the marker that was
submitted: handwrite updates get `0x3e80000` added to the marker, matching
`add w8, w8, #0x3e80000` in the case body. Anything waiting on a marker for a
handwrite update has to expect the offset one.

This is the same trap as section 8.5 seen from the other side. `debug_level` is
named like a level and read like a level, and it is a **bit field**. Every
"the driver logs nothing for this" conclusion in this document was reached by
writing small numbers into it.

### 9.5 Live pipeline state

`/sys/devices/virtual/sepdc/debug/status` reports the pipeline directly:

```
epdctask_status[0] wf_status[99] wftask_wf_status[99] wftask_status[0]
wb_status[30] wb_wf_status[0] cb_state[99] epdc_active_luts[0x0][0x0][0x0][0x0]
all_frames_completed[0] frame[2075:2075:2075]
```

The three `frame[]` counters being equal means settled; they diverge while an
update is in flight. That makes this both a health check and a way to prove an
update was actually driven -- the handwrite probe moved it by 33-37 frames per
full-panel GC16, which is how we know the update was accepted rather than
silently dropped.

`cut_frame_num` (default 3, valid 3..5) is writable here as well as via `0x7024`
-- a waveform-length knob reachable without any ioctl at all, and an untried
lever on the A2 flicker.

---

## 10. Crash recovery, and why the watchdog does not help

Probing this driver has taken the device down repeatedly. One case rebooted
itself; one sat unresponsive for **220 seconds**.

That 220s has an explanation, and it is not "the watchdog is slow". The SoC
watchdog is configured and working -- devicetree gives `qcom,bark-time = 0x2af8`
(11000 ms) and `qcom,pet-time = 0x2490` (9360 ms) [T], so a genuinely dead kernel
is reset in about 14 seconds. It took 220 because **the kernel was not dead**:
only the display pipeline was stuck, and the petting thread kept running.

Nothing in this kernel catches that shape of hang:

| option | state |
|---|---|
| `CONFIG_DETECT_HUNG_TASK` | not set |
| `CONFIG_SOFTLOCKUP_DETECTOR` | not set |
| `CONFIG_WQ_WATCHDOG` | not set |
| `CONFIG_WATCHDOG` | not set -- so no `/dev/watchdog` for userspace |
| `CONFIG_MAGIC_SYSRQ` | **set**, runtime gate 0 |
| `CONFIG_PSTORE_RAM` | set, `dump_oops=1` |

None of the first four can be enabled at runtime. Two things can be done instead.

**Turn on sysrq.** `echo 1 > /proc/sys/kernel/sysrq` gives crash-on-demand
(`echo c`, which panics -> ramoops -> reboot in 5s since `panic=5`) and, more
useful, `echo w` to dump every task in `D` state. The three EPD threads sit in
`down()` when idle:

```
mdss_fb_epdc     D  515   mdss_mdp_epdc_thread+0x1cc
epdc_refresh_wa  D  517   epdc_refresh_waveform_task+0xa4
commit_epdc      D  521   mdss_commit_epdc_thread+0x90
```

Different offsets during a hang say which thread is stuck and where -- the
diagnostic that was missing for the 220s incident.

**Arm a userspace deadman.** `scripts/epd-deadman.sh arm 30` starts a detached
timer that reboots unless disarmed; run the risky call between arm and disarm.
It is `setsid`-detached, so losing the adb shell does not disarm it, and the
disarm is a file check rather than a signal, so a failed `kill` cannot leave it
armed by accident. Verified by letting it fire: uptime 1589s -> 22.8s.

`scripts/epd-debug-arm.sh` sets all of this up; run it once per boot. Note
`adb root` is needed and does **not** survive a reboot -- adbd comes back as
`shell`, and several probe results were initially misread as permission failures
because of it.

**pstore already works.** `/sys/fs/pstore/console-ramoops-0` holds the previous
boot's console across a reboot, and `dmesg-ramoops-0` appears after an oops. The
console record is not ECC-protected (`ramoops.ecc=0`) and comes back with
scattered single-bit corruption, so read it as mostly-legible text rather than
something to grep exactly.

### 10.1 `/dev/ebc` is world-writable

```
crw-rw-rw- 1 root root u:object_r:ebc_device:s0 10, 51 /dev/ebc
```

Any installed app can drive the panel, switch it into handwrite scheme, or hang
it with `0x7000`. SELinux is permissive on this build, so the `ebc_device` label
constrains nothing. Belongs with issue #5 (`ro.adb.secure=0`) as bring-up debt to
pay down before this is a daily driver.

---

## 11. Colour: the CFA path

`0x7026` is `enable cfa mode`, and **its argument is inverted**. [V][D] From the
case body:

```
cmp  w8, #0
cset w8, ne                        ; w8 = (arg != 0)
csel x2, "disable", "enable", ne   ; ne -> "disable"
strb w8, [x9, #0x54]               ; the stored flag is "cfa DISABLED"
```

So `ioctl(fd, 0x7026, &zero)` **enables** it and a non-zero argument disables it.
Passing `1` logs `disable cfa mode!`, which is the opposite of what anyone would
predict from the command's name. The stored byte is a *disabled* flag, which is
presumably where the inversion comes from.

Driver state is not persistent, so a reboot returns the panel to its default
regardless of what was set.

### What the hardware evidence says

| evidence | reading |
|---|---|
| `[ED061KC1 timing]` | the panel part |
| `onyx_epdc_parse_dt(): cfa_mode[1017]` | a colour filter array **is** configured [T] |
| `_onyx_epdc_extbuf_convert_gray_for_cfa`, `onyx_image_rect_adjust_for_cfa` | the driver has CFA-specific conversion |
| `get_glr16_mode_index(): gcc16[-1] glrc16[-1]` | both **colour waveform modes are absent** from the loaded `.wbf` |
| `onyx_get_eink_screen_timing(): get color_panel failed! set default val 0!` | `color_panel[0]` is a **fallback**, not a real answer -- the DT read failed |

The last row matters: `color_panel[0]` looks like "this is not a colour panel"
and is actually "nobody told us", so it is not evidence either way. The
`gcc16[-1] glrc16[-1]` line is the real constraint -- a Kaleido panel renders
colour through colour-specific waveforms, and this unit's waveform file does not
contain them.

### The rotation, independently confirmed

The same devicetree line gives `sf_rotation[270]`, which matches the rotation
established in section 9.4 by looking at the panel. Two independent sources, and
the DT one was found afterwards -- worth noting because 90 and 270 are
indistinguishable from geometry alone.

### Artwork

`scripts/gen-screensaver.py --color` keeps RGB and diffuses each channel
independently rather than converting to luma. That is the right model for a CFA
panel: the filter array puts separate R, G and B filters over neighbouring cells,
so each channel really is quantised on its own.

It also now **cover-crops** rather than fitting and padding. Fitting preserved the
whole image and padded the short axis, which on a lock screen means white bands
held at full contrast for hours; covering fills the panel and loses the overflow.

---

## 12. `0x701a` panics the kernel, and anyone can call it

A blind sweep of the unidentified commands took the device down hard -- USB gone,
adb gone. It recovered on its own in about five seconds, which is worth stating
first because it is the payoff from section 10: this was a genuine kernel panic,
and `panic_on_oops=1` with `panic=5` rebooted it without human intervention.
`sys.boot.reason` reads `kernel_panic,bug`.

The console record survived in pstore. Reconstructed from it: [V]

```
kernel BUG at mm/usercopy.c
Internal error: Oops - BUG: 0 [#1] PREEMPT SMP
Process ebcsweep (pid: 10459)
pc : usercopy_abort+0x8c/0x90
Call trace:
  usercopy_abort+0x8c/0x90
  __check_object_size+0x3dc/0x440
  epdc_ioctl+0x914/0x3d08
  do_vfs_ioctl / __arm64_sys_ioctl / el0_svc_common / el0_svc
Kernel panic - not syncing: Fatal exception
```

`epdc_ioctl+0x914` is file offset `0x57b29c`, which is `0x40` into the case body
at `0x57b25c` -- **command `0x701a`**. The offset in the backtrace is what
identifies it; nothing else in the batch would have.

### What the command does

```
x9  = (s32)g[0x3464]         ; capture buffer index
w10 = g[0x3470]              ; a flag
w11, w12 = g[0xe0], g[0xe4]  ; panel width, height
x21 = [g + x9*8 + 0x2e50]    ; buffer = array[index]
w8  = (w * h) << (flag ? 1 : 0)
__check_object_size(x21, w8, 1)   ; 1 = copy TO user
```

So `0x701a` hands a **capture buffer** to userspace, sized `w*h` or `2*w*h`
(1.3 MB or 2.7 MB at 1648x824). Those buffers are allocated by
`SET_EBC_CAPTURE_SRART` (`0x7018`) and freed by `SET_EBC_CAPTURE_STOP`
(`0x701b`). Called without a preceding start, `array[index]` is not a valid
kernel object, hardened usercopy refuses it, and `BUG()` takes the machine down.

There is no validation. The driver does not check that capture is running, that
the index is in range, or that the pointer is non-NULL.

### Security consequence

```
crw-rw-rw- 1 root root u:object_r:ebc_device:s0 10, 51 /dev/ebc
```

`/dev/ebc` is world read/write and SELinux is permissive on this build, so **any
installed application can panic the device with a single ioctl and no
permission at all.** No root, no special group. That is an unprivileged local
denial of service, and it needs no exploit -- the correct call sequence simply
omitted.

Tracked with issue #5 (`ro.adb.secure=0`) as bring-up debt. Tightening the node's
permissions is the practical fix; the driver bug itself is in a kernel Onyx does
not publish source for.

### Method note

The sweep put fourteen unknown commands in one shell loop. When it died there was
no output at all, so it was not possible to say from the sweep itself which
command was responsible -- the backtrace offset settled it afterwards, and only
because pstore preserved the console.

**One command per invocation, with the result recorded on the host before the
next one, costs a minute more and identifies the culprit directly.** The
per-process `timeout` used here protects against a userspace hang and does
nothing whatever about a kernel BUG.

---

## 13. Which update fields the driver actually reads

`docs/19` and section 2.1 above treat the 40-byte update struct as though every
field matters, and record hopeful notes about `temp` and `dither_mode`. Both are
worth re-reading with this in hand.

Method: the struct is copied to `sp+0x40` in `epdc_ioctl`, so each field has a
known stack offset. Counting loads at those offsets says what is consumed. The
struct's address also escapes as **argument 5 to `__onyx_epdc_buf_put_queue()`**,
so that function was scanned too, tracking the pointer through its register
aliases.

| field | offset | reads in `epdc_ioctl` | reads in `buf_put_queue` | verdict |
|---|---|---|---|---|
| `rect[0..3]` | +0x00 | 5 | via callee | live |
| `waveform_mode` | +0x10 | 6 | 12 | **live** |
| `update_mode` | +0x14 | 0 | 0 | **no read found** |
| `update_marker` | +0x18 | 7 | 18 | **live** |
| `temp` | +0x1c | 0 | 0 | **no read found** |
| `flags` | +0x20 | 9 | 8 | **live** |
| `dither_mode` | +0x24 | 0 | 1, conditional | effectively dead |

[D] -- this is static reachability, not an experiment.

### What this means for two documented tunables

* **`temp` is not read.** Section 2.1 says i.MX defines `TEMP_USE_AMBIENT` as
  `0x1000`, that sending `0` might mean 0 degrees C, and that `4096` "is accepted
  by the driver". It is accepted because it is **ignored**. That also explains
  why the visual effect was never confirmed -- there is none.
  `persist.epdcshim.temp` is almost certainly a no-op.

* **`dither_mode` is read exactly once, behind a condition our updates never
  satisfy.** The single site is guarded by `flags == 2`:

  ```
  ldr w10, [x25, #0x20]     ; flags
  cmp w10, #2
  b.ne <skip>               ; anything else -> dither_mode never loaded
  ldr w10, [x25, #0x24]     ; dither_mode
  ```

  We send `flags = 0x31000`, so the branch is never taken.
  `persist.epdcshim.dither` therefore does nothing on our path, and section 2.1's
  "hardware dithering, free, if Onyx kept the semantics" should be read as: they
  did not keep them in any form we can reach.

* **`update_mode` is not read either**, so the i.MX `PARTIAL`/`FULL` distinction
  does not exist here. Everything this driver does is decided by
  `waveform_mode` and `flags`.

### The limit of this analysis, stated

Tracking the struct pointer through `__onyx_epdc_buf_put_queue` follows `mov`
aliases, and that is not sound: a `mov` may retarget a register at a different
object with a similar layout. There is a concrete hint of exactly that -- at the
`dither_mode` site, `flags` is compared against `0xff`, `2` and `0xf`, which are
not plausible values for a field we send as `0x31000`. So `x25` there may be an
internal queue entry rather than the user's struct.

The strong claims are the negative ones for `temp` and `update_mode`: no read at
either level, under any aliasing. The `dither_mode` result should be treated as
"not reachable on our path" rather than as a full account of the field.

Both are cheap to falsify on the device -- send `dither_mode` 1..4 and `temp` 0
against `0x1000` and look -- and that experiment has not been run.
