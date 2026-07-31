# EPD hardware map

Recovered entirely from `prebuilt/dtbo.img` by decompiling it with `dtc`. No
guessing and no vendor documentation involved -- the overlay describes every
chip, rail and GPIO in the e-ink path.

The prompt for doing this was an unrelated Onyx port,
[`nproth/android_device_onyx_t68`](https://github.com/nproth/android_device_onyx_t68)
(Boox T68, i.MX 6SoloLite, CyanogenMod 11). Nothing in that tree is reusable
here -- different SoC, different display architecture, Android 4.4 -- but its
author identified their panel (`ED068OG1`) from firmware strings, and the same
technique works on our DTBO. It also confirms Onyx has never published kernel
source for *any* of their devices, not only this one.

## The chain

```
SM7225 MDSS  --MIPI DSI (video mode)-->  Lattice CertusPro-NX  -->  ED061KC1
                                          (TCON, "mxo1300")          E Ink panel
                                                  ^
                                          TPS65185 (I2C 0x68)
                                          VCOM / +14.25V / -V / V3P3 / TMST
```

The panel is attached as an ordinary Qualcomm DSI panel. The DTBO defines both
`qcom,mdss_dsi_epdc_cmd` and `qcom,mdss_dsi_epdc_video`; the kernel config
selects video mode (`CONFIG_ONYX_EPDC_SEND_MODE_VIDEO=y`). So the SoC-side
display pipeline is stock Qualcomm MDSS, and everything e-ink-specific happens
downstream of DSI, in an FPGA.

## Panel: ED061KC1

`eink-timings` node, verbatim:

| property | value | decoded |
|---|---|---|
| `panel_name` | `"ED061KC1"` | E Ink 6.13" |
| `xres` / `yres` | `0x670` / `0x338` | **1648 x 824** |
| `density` | `0xd4` | 212 dpi |
| `frame_rate` | `0x5a` | 90 |
| `sdclk-frequency` | `0x2625a00` | 40 MHz |
| `left/right/upper/lower_margin` | `0x0b`/`0x15`/`0x05`/`0x04` | 11 / 21 / 5 / 4 |
| `hsync_len` / `vsync_len` | `0x11` / `0x02` | 17 / 2 |
| `panel_width` | `0x10` | 16 (bus width, bits) |
| `kernel_init_mode_disable` | `1` | kernel does **not** init the panel |
| `half_empty` | `1` | |

`kernel_init_mode_disable = 1` is worth noting: panel init is not done by the
kernel at probe. Combined with the absence of any boot-time image, that is
consistent with the screen staying blank until userspace drives it -- which is
what we observe on every failed boot.

## TCON: Lattice CertusPro-NX (`mxo1300@40`, I2C 0x40)

`compatible = "onyx,mxo"`. The name is Onyx's; the part is Lattice's. Three
things identify it:

* the firmware filenames are `lfcpnx100_tcon_fw_*.bin` -- **LFCPNX** is the
  Lattice CertusPro-NX device prefix, and `100` is the ~100K-LUT part
* `program_enable_gpio` / `program_init_gpio` / `program_done_gpio` are the
  Lattice configuration handshake (`PROGRAMN` / `INITN` / `DONE`)
* `.ied` is Lattice's NVCM (Non-Volatile Configuration Memory) programming
  format -- `mxo{1300,4300}_nvcm_*.ied`

So the TCON is a **user-programmable FPGA**, not an opaque IP block. That is a
materially better position than a hardware EPDC: the bitstream is data we can
keep and re-upload, and the DSI-side interface is a standard one.

```
fw-product-id = <0x81>
```

This selects the firmware. Of the nine `.ied` blobs
(`mxo{1300,4300}_nvcm_{81,82,83,84,86,87}`), only the `_81` pair applies to this
board -- the `_XX` suffix is a **product ID, not a version**. That narrows what
firmware extraction actually has to recover from 15 blobs to about three.

GPIOs (all `&tlmm`, number then flags):

| line | pin | note |
|---|---|---|
| `fpga_12v_core_en_gpio` | 6 | 1.2 V FPGA core |
| `fpga_25v_en_gpio` | 48 | |
| `fpga_30v_en_gpio` | 100 | |
| `reset_gpio` | 139 | active low |
| `program_enable_gpio` | 38 | PROGRAMN |
| `program_init_gpio` | 9 | INITN |
| `program_done_gpio` | 8 | DONE |

Rails: `vsys` 3.0 V (L8A), `vddi2c` 1.8 V (L14A), `vdd1v8in` 1.8 V (L11A),
`vdd3vin` 3.0 V (L11E), `vdd1v2in` 1.2 V (L15A).

## PMIC: TI TPS65185 (`tps6518x@68`, I2C 0x68)

`compatible = "TI,tps6518x"` -- the standard e-ink rail generator, and it is
publicly documented. Regulators exposed: `DISPLAY`, `VCOM`, `V3P3`, `TMST`
(the panel thermistor, which the waveform selection depends on).

```
vpos-mV  = 0x37aa                        +14.25 V
VCOM min = 0xffbe0178  (signed)           -4.325 V
VCOM max = 0xfff85ee0  (signed)           -0.500 V
```

Power sequencing is in the node and is the part that must be reproduced exactly
by any replacement driver -- getting it wrong on an EPD is not merely a blank
screen:

```
pwr_seq0 = 0xe1   pwr_seq1 = 0x30   pwr_seq2 = 0x33
upseq0   = 0xe4   upseq1   = 0x00
dwnseq0  = 0x1e   dwnseq1  = 0x00
max_wait = 0x18   delay_3v3_highv = 0x03
```

GPIOs: `gpio_pmic_pwrgood` 45, `gpio_pmic_vcom_ctrl` 46, `gpio_pmic_wakeup` 57.

## Waveform

`CONFIG_ONYX_EPDC_INIT_WAVE_FIRMWARE=y` and
`CONFIG_ONYX_EPDC_FIRMWARE_WAVEFORM_KERNEL=y`, with
`CONFIG_ONYX_EPDC_INIT_WAVE_FLASH` **not** set. So the waveform table comes from
firmware rather than from panel flash, making it a hard dependency for any
clean-room driver.

**We already have it**: `firmware/analysis/eink_waveform.wbf`, 599,622 bytes,
read off a running stock system at `/waveform/eink_waveform.wbf` and validated
against the kernel's own boot-time parse; the mode-index to name mapping is
solved in [03-ebc-api.md](03-ebc-api.md). The FPGA blobs are a separate matter --
[06-kernel.md](06-kernel.md) records where they sit in the Image and why they are
not carved out yet.

Other relevant config: `CONFIG_ONYX_EPDC_TCON_TYPE_LCDIF=y`,
`CONFIG_ONYX_EPDC_DISPLAY_BUF_PIXEL_FORMAT_RGBA=y` (framebuffer is RGBA, not
8-bit greyscale), `CONFIG_ONYX_EPDC_HANDWRITE_BUF_MALLOC_FROM_ION=y`,
`CONFIG_ONYX_EPDC_PANEL_DATA_CTRL_END_SWAP=y`.

## What this changes

Nothing for the current boot problem -- the vendor image drives all of this and
we are not rebuilding it. It matters for two later things:

1. **The clean-room driver estimate in [06-kernel.md](06-kernel.md) improves.**
   The two active chips are a documented TI PMIC and a Lattice FPGA with a
   standard config interface, fed by stock Qualcomm DSI. The unknown is reduced
   to the FPGA bitstream and the waveform blob, both of which are data rather
   than logic.
2. **Firmware extraction gets a smaller target**: `fw-product-id = 0x81` plus
   the waveform, not all fifteen blobs.

Regenerate any of this with:

```sh
dd if=device/onyx/Palma2_Pro_C/prebuilt/dtbo.img of=dtbo0.dtb bs=1 skip=64 count=213420
dtc -f -I dtb -O dts -o dtbo0.dts dtbo0.dtb
```
