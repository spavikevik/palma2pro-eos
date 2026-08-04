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
