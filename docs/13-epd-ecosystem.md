# EPD ecosystem research: what other projects already solved

Survey of e-ink work on other hardware, filtered for what is *actually usable*
here. The headline: **Onyx's `/dev/ebc` driver is derived from Rockchip's, even
though this is a Qualcomm SoC** -- which gives us a published reference for an
interface we had been treating as wholly proprietary.

## 1. Rockchip EBC -- the direct ancestor of Onyx's driver

Rockchip's RK3566 has an "EBC" (E-Book Controller) with a `/dev/ebc` character
device and an ioctl set whose names match ours **exactly**: `EBC_GET_BUFFER`,
`EBC_SEND_BUFFER`, `EBC_GET_BUFFER_INFO`, plus `struct ebc_buf_info`. Onyx runs
this on a Qualcomm SM7225 with a Lattice TCON, so they clearly ported Rockchip's
`ebc-dev` rather than writing one.

The upstream header (`smaeul/linux`, `drivers/gpu/drm/rockchip/ebc-dev/ebc_dev.h`):

| code | Rockchip | this device (confirmed live) |
|---|---|---|
| 0x7000 | `EBC_GET_BUFFER` | `GET_EBC_BUFFER` |
| 0x7001 | `EBC_SEND_BUFFER` | -- |
| **0x7002** | **`EBC_GET_BUFFER_INFO`** | **`GET_EBC_DRIVER_SN`** |
| **0x7003** | `EBC_SET_FULL_MODE_NUM` | **`GET_EBC_BUFFER_INFO`** |
| 0x7004 | `EBC_ENABLE_OVERLAY` | |
| 0x7005 | `EBC_DISABLE_OVERLAY` | |
| 0x7006/7 | `EBC_{GET,SEND}_OSD_BUFFER` | |
| 0x7008-b | `EBC_GET_AUTO_{OLD,NEW,BG,CUR}_BUFFER` | |

**Onyx inserted `GET_EBC_DRIVER_SN` at 0x7002**, shifting everything after it by
+1. That is why `GET_EBC_BUFFER_INFO` answers at 0x7003 here but 0x7002 upstream
-- both confirmed on-device. It is the same off-by-one insertion pattern that
broke the AIDL interface on the `onyx-sf` branch; apparently a habit.

Two immediately useful consequences:

* **It explains both device hangs.** In Rockchip's design `EBC_GET_BUFFER`
  *blocks* waiting for a free buffer from the driver's queue. Calling it while
  the vendor stack owns every buffer waits forever, which is exactly what we saw
  -- a silent lockup with nothing in `dmesg`. Not a malformed argument, by
  design. `docs/11` records "do not call 0x7000"; this is *why*.
* **`struct ebc_buf_info` is confirmed**, field for field, matching what
  `ebctool`/`ebcprobe` already assume:
  `offset, epd_mode, height, width, panel_color, win_x1, win_y1, win_x2, win_y2,
  width_mm, height_mm`.

Rockchip's list stops at 0x700b. The four commands Onyx's SurfaceFlinger
actually calls (`0x701e`, `0x7021`, `0x7022`, `0x7029`) are therefore **Onyx
additions above the upstream range**, and no public source will name them. The
19 `GET_EBC_*`/`SET_EBC_*` strings in our kernel are the candidate pool.

## 2. PineNote -- the best open reference implementation

The PineNote (RK3566) has a genuine from-scratch DRM driver: Samuel Holland's
`drm/rockchip: Rockchip EBC` RFC series (LWN, April 2022), plus community
reverse-engineering of the BSP blob (which Rockchip shipped as a *gcc assembly
dump*, `ebc_dev_v8.S`, retaining enough debug info to reverse).

Why it matters here specifically: that driver **computes waveform LUTs in
software on the CPU and hands frame buffers to the TCON**. Our kernel is
`CONFIG_FB_ONYX_SOFTWARE_EPDC=y` with `CONFIG_ONYX_EPDC_TCON_TYPE_LCDIF` -- the
same architecture. If we ever write our own EPD driver (`docs/06`), this is the
closest working model, and it is GPL, readable, and was written by someone
solving our exact problem one SoC over.

## 3. inkwave -- parses the waveform blob we already have

`fread-ink/inkwave` (GPLv2) reads `.wbf`, the format E Ink stores on the flash
chip on the panel's ribbon cable, and converts to `.wrf` (the i.MX EPDC input
format). It prints mode/temperature metadata in human-readable form.

We have `firmware/analysis/eink_waveform.wbf`, 599,622 bytes, pulled from a
running stock system and validated against the kernel's own boot-time parse
(`docs/03`). **inkwave should decode it directly** -- giving us the mode table,
temperature ranges and per-mode waveform data without further disassembly. That
is a concrete, zero-risk next step that needs no device.

Caveat from the project's own issues: some vendor `.wbf` files are not fully
handled (the PineNote's among them), and there are `PVI` vs `RKF` variants. Ours
parsed cleanly enough for the kernel, so it is worth trying.

## 4. Kobo / Kindle -- same waveforms, different controller

Kobo and Kindle use i.MX SoCs with the Freescale/NXP **EPDC** block and the
`mxcfb` interface -- a hardware EPD controller, unlike our software EPDC driving
a Lattice FPGA over DSI. So their *driver* code does not transfer.

What does transfer is the waveform ecosystem: `.wbf`/`.wrf`, the mode
vocabulary (INIT / DU / GC16 / A2 / REGAL), and the general shape of
"rect + waveform mode + temperature" updates -- which is precisely the shape of
`hwc_epdc_llist` (`docs/11`). The panel families overlap too (ED060xx there,
ED061KC1 here).

## 5. Modos Glider -- open FPGA e-ink controller

`Modos-Labs/Glider` is an open-source e-ink monitor built on an **FPGA
controller**. Relevant because our TCON is a Lattice CertusPro-NX FPGA
(`docs/07`) loaded from `lfcpnx100_tcon_fw_*.bin` bitstreams. If a clean-room
driver ever needs to understand what the TCON expects on its source/gate driver
side, this is the only open project working at that layer.

Not useful for the current port -- our FPGA already has vendor firmware and works.

## 6. Onyx and the GPL

Publicly documented and long-standing: Onyx ships a modified Linux kernel and
does not publish the source. Their GitHub org (`onyx-intl/boox-opensource`)
carries applications and libraries, **not** the kernel. Community requests on
their own help centre and forum have gone unanswered for years.

So `docs/06`'s conclusion holds and is not specific to this model: there is no
kernel source coming, for any Boox device. Everything kernel-side must be
reverse-engineered or inferred from the Rockchip ancestor.

## 7. PinePhone -- not applicable

No e-ink. The relevant Pine64 device is the PineNote (section 2).

## What to actually do with this

1. **Run `inkwave` on our `.wbf`.** Offline, no device, decodes the waveform
   metadata we currently only half-understand.
2. **Read the PineNote EBC driver before writing any EPD code.** It is the
   nearest working implementation of the same software-EPDC architecture.
3. **Treat the Rockchip header as the map for the low ioctl range**, but note it
   ends at 0x700b -- Onyx's own commands sit above it and remain unnamed.
4. **Correct `docs/03`**: its Rockchip-derived numbering is right for 0x7000/1
   and then shifts by +1 from 0x7002 because of Onyx's inserted
   `GET_EBC_DRIVER_SN`.

## Sources

* RK3566 EBC reverse-engineering -- <https://wiki.pine64.org/wiki/RK3566_EBC_Reverse-Engineering>
* Rockchip `ebc_dev.h` (ioctl values, `ebc_buf_info`) -- <https://github.com/smaeul/linux/blob/26a761b44caa31fa36774686f27e68e0da3bacc0/drivers/gpu/drm/rockchip/ebc-dev/ebc_dev.h>
* `drm/rockchip: Rockchip EBC display driver` (LWN) -- <https://lwn.net/Articles/891304/>
* RFC patch series -- <https://lore.kernel.org/linux-arm-kernel/20220413221916.50995-7-samuel@sholland.org/>
* EBC reverse-engineering notes -- <https://github.com/Ralim/ebc-dev-reverse-engineering/>
* inkwave (`.wbf` parser, GPLv2) -- <https://github.com/fread-ink/inkwave>
* Modos Glider (open FPGA e-ink controller) -- <https://github.com/Modos-Labs/Glider>
* Onyx GPL non-compliance -- <https://help.boox.com/hc/en-us/community/posts/4405646929812-Violation-of-GPL-GPL2-kernel-source->
* Onyx open-source org (apps, not kernel) -- <https://github.com/onyx-intl/boox-opensource>
