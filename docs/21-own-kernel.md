# Building our own kernel

The gating item for everything structural: SELinux enforcing, verified boot with
our own keys, kernel security updates, and any long-term future for this device.
Today we run **Onyx's prebuilt `4.19.157-perf`**, for which no source is
published — so none of those are reachable.

This document is the research; the work is tracked as an investigation issue.
`docs/why-not-linux.md` reached a compatible conclusion from the other
direction, and its verdict is refined rather than contradicted below.

---

## 1. What we run now

| | |
|---|---|
| kernel | `4.19.157-perf-g3d47a6619220-dirty`, clang 10.0.7, built by `onyx@onyxUbuntu` |
| source | **none published** — Onyx ships a modified Linux without corresponding source (GPL-2.0) |
| SoC | SM7225 / "lito" / "lagoon" |
| EPD | `CONFIG_FB_ONYX_SOFTWARE_EPDC=y`, plus Onyx modifications *inside* the msm SDE display driver |

The last row is the one that matters most, and it is easy to underestimate.

---

## 2. The single most important finding

**The Fairphone 4 uses the same SoC and Fairphone publishes complete kernel
sources**, on the same `msm-4.19` base as Onyx's.

* <https://github.com/FairphoneMirrors/android_kernel_fairphone_sm7225>
  (`kernel/11/fp4`, `kernel/12/fp4`)
* also maintained by [LineageOS](https://github.com/LineageOS/android_kernel_fairphone_sm7225)
  and [CalyxOS](https://gitlab.com/CalyxOS/kernel_fairphone_sm7225)
* build: `kernel/msm-4.19`, `fp4_defconfig` / `fp4-perf_defconfig`, clang,
  output `arch/arm64/boot/Image`

So the SoC, the DSI controller, the SDE display pipeline, the regulators, the
GPU, storage and USB all have published, buildable source that matches our
hardware. **The gap is not the SoC. The gap is the EPD.**

This is the same coincidence that made unlocking possible, and it is worth
appreciating how unusual it is: an obscure Chinese e-reader happens to share
silicon with the most GPL-compliant phone vendor in the industry.

---

## 3. What is missing, precisely

Everything Onyx added for e-ink, in two parts:

**a. Standalone drivers** — the EPD framebuffer/driver (`onyx_epdc_fb`,
`/dev/ebc`, waveform loading, LUT scheduling, the `epdc_*` kernel threads), the
Lattice CertusPro-NX TCON (FPGA bitstream load over the `PROGRAMN`/`INITN`/`DONE`
handshake), and TPS65185 PMIC sequencing. `docs/19` specifies the interfaces
these expose; it does **not** specify their internals.

**b. Modifications inside the msm SDE driver** — and this is the part that makes
a naive plan fail. The EPD path is not a bolt-on:

```
__sde_plane_atomic_update_epdc      plane-level blit + submit
sde_plane_set_upd_ext_for_sync      exported, called from elsewhere
sde_crtc_prepare_commit_epdc        CRTC-level commit
__msm_atomic_commit_epdc            atomic path
msm_framebuffer_prepare_epdc        framebuffer path
EPDC_UPDATE_PARMS_ADDR / _CNT       custom DRM plane properties
```

Onyx threaded EPD handling through SDE, MSM atomic commit, framebuffer handling
and the plane property system. Reproducing that means re-adding hooks across
the display driver, not writing one self-contained module.

**c. Vendor kernel modules.** The device loads DLKMs — `wlan`, `wcd937x_dlkm`,
`wcd938x_dlkm`, `machine_dlkm`, `rmnet_*`. These are built against a specific
kernel and will not load against a rebuilt one unless rebuilt too. Fairphone
publishes their techpack sources; whether Onyx's audio/wifi variants match is
unverified.

---

## 4. Three routes

### Route A — rebuild `msm-4.19` from Fairphone sources, port the EPD

Keeps the Android vendor stack (A11 BSP, composer, `libsdedrm`) working, because
the kernel ABI stays in the same family.

* **Buys:** SELinux enforcing becomes tractable, kernel CVE patching, our own
  defconfig, custom AVB keys if paired with issue #10
* **Costs:** must reproduce §3a *and* §3b, and rebuild the DLKMs
* **Risk:** moderate and recoverable — a bad kernel is a `boot` partition
  reflash over EDL, which we do routinely
* **Verification is cheap:** boot FP4's kernel unmodified first. Expect no
  display and confirm everything *else* works (adb, storage, wifi). That single
  experiment separates "the SoC support is fine" from "the EPD is the problem",
  and it is a day's work, not a project

### Route B — mainline, Rockchip-style

The [`sm6350-mainline`](https://github.com/sm6350-mainline) fork targets exactly
SM6350/SM7225 and is tested on the Fairphone 4. As of the FOSDEM 2023 status,
serial, buttons, regulators, RTC, USB, storage, SD, **display with backlight**,
touchscreen and GPU work; DisplayPort landed in 2024.

Here the EPD would be written as a proper DRM driver rather than as hooks in a
vendor display stack — which is what Samuel Holland's
[Rockchip EBC driver](https://lwn.net/Articles/891304/) does for the PineNote,
and that architecture matches ours closely (software-computed waveforms driving
a TCON, same as `CONFIG_FB_ONYX_SOFTWARE_EPDC`). It was still RFC as of 2022;
current upstream status needs checking.

* **Buys:** a clean, maintainable, upstreamable driver; long-term kernel updates
* **Costs:** mainline **cannot run the Android A11 vendor blobs**. This is the
  Linux route, not the Android route — no Onyx composer, no `libsdedrm`, so the
  entire display stack must be written, not just the kernel half
* **Honest scope:** this is the multi-year project `docs/why-not-linux.md`
  described. It is not a way to get a better Android

### Route C — status quo

Prebuilt kernel, permissive SELinux, no verified boot, no CVE patching. What we
have. Fine for a reader; not fine for a daily driver (see README security
posture).

---

## 5. What changes since `docs/why-not-linux.md`

That document concluded the EPD driver was the wall, and it was right. Two
things soften it:

1. **We now have the interface specification** (`docs/19`) — the ioctl set, the
   40-byte update struct, waveform mode table, plane properties, TCON GPIOs and
   PMIC sequencing, all recovered and marked by confidence. Writing a driver
   against a known interface is a different problem from reverse-engineering
   blind.
2. **We know the waveform blob format and have the file.** `inkwave` parses
   `.wbf`; ours is in `firmware/analysis/`.

What has *not* changed: nobody has the TCON's internal protocol, which lives in
the FPGA bitstream, and Onyx still publishes nothing.

So the verdict moves from "multi-year RE project" to "**Route A is a real
project of bounded scope; Route B remains multi-year**".

---

## 6. Recommended order

1. **Boot FP4's kernel unmodified** on this device. Cheap, decisive, and nobody
   has tried it. Expected: boots, no display. If it does *not* boot, everything
   below is moot and we have learned that for a day's work.
2. Diff Onyx's `4.19.157` config against FP4's `fp4_defconfig` (extract ours
   from `/proc/config.gz` if present, or from the prebuilt `Image`).
3. Establish whether the DLKMs load against a rebuilt kernel.
4. Only then decide whether to port the EPD stack (§3a + §3b).

Step 1 is the gate. Do not plan past it.

---

## Sources

* [FairphoneMirrors/android_kernel_fairphone_sm7225](https://github.com/FairphoneMirrors/android_kernel_fairphone_sm7225)
* [Fairphone Open Source — kernel](https://code.fairphone.com/projects/fairphone-4/kernel.html)
* [LineageOS kernel_fairphone_sm7225](https://github.com/LineageOS/android_kernel_fairphone_sm7225) ·
  [CalyxOS](https://gitlab.com/CalyxOS/kernel_fairphone_sm7225)
* [sm6350-mainline](https://github.com/sm6350-mainline)
* [Mainline Linux on recent Qualcomm SoCs: Fairphone 4 (FOSDEM 2023)](https://archive.fosdem.org/2023/schedule/event/mainline_on_the_fairphone4/attachments/slides/5454/export/events/attachments/mainline_on_the_fairphone4/slides/5454/Mainline_Linux_on_recent_Qualcomm_SoCs_Fairphone_4.pdf)
* [drm/rockchip: Rockchip EBC display driver (LWN)](https://lwn.net/Articles/891304/) ·
  [RFC series](https://lore.kernel.org/linux-arm-kernel/20220413221916.50995-7-samuel@sholland.org/)
* [RK3566 EBC reverse-engineering (PINE64)](https://wiki.pine64.org/wiki/RK3566_EBC_Reverse-Engineering)
