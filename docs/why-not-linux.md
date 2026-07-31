# Why not Ubuntu Touch / postmarketOS

Evaluated and rejected. Recording the reasoning so it isn't re-litigated later.

## Ubuntu Touch — blocked at step one

UT runs on Halium: the Android kernel plus Android HALs via libhybris, with Ubuntu
userspace on top. Halium requires **rebuilding the Android kernel** with container and
namespace configs that stock vendor kernels don't ship.

Rebuilding requires kernel source. Onyx has never published theirs — a documented,
long-running GPL2 violation across the whole Boox line. You can read the running config
out of `/proc/config.gz`, but that tells you what's enabled, not how to rebuild it.

No source, no Halium, no Ubuntu Touch.

## postmarketOS — closer than expected, still blocked

The SoC is genuinely fine here:

- SM7225 is the Fairphone 4 SoC, and Fairphone publishes complete GPL kernel sources
  (msm-4.19).
- SM7225 has **upstream mainline support** — initial Fairphone 4 enablement landed in
  `linux-arm-msm`. Mainline boots this silicon: clocks, USB, storage, modem groundwork.

So a mainline kernel would come up. It would also show nothing on screen.

## The wall, in both cases: the EPD driver

Boox's e-ink path is an out-of-tree Onyx panel/waveform driver plus closed waveform data —
the per-panel lookup tables that tell the controller how to flip particles per temperature
and per refresh mode. No source, and the waveforms themselves are binary blobs tied to
the specific panel.

The consequence differs sharply by path:

| Path | Kernel | Display outcome |
|---|---|---|
| Android GSI | stock Onyx vendor kernel | Panel works. Refresh *mode control* is lost with the patched framework → ghosting, poor battery. Degraded but usable. |
| Mainline Linux (pmOS) | self-built | **No display at all.** Nothing drives the EPD controller. |

Writing an EPD driver from scratch means reverse-engineering the controller protocol and
extracting the waveform tables. The only real precedent is the PineNote's Rockchip EBC
driver, which took a dedicated group years — with a cooperative vendor and a documented
controller. Blind, on Onyx hardware, solo, this is a multi-year RE project, not a port.

## What "Linux" can actually mean on this device

| Option | Viable | Notes |
|---|---|---|
| Ubuntu Touch | No | Halium needs kernel source Onyx won't ship |
| postmarketOS, mainline | No display | SoC boots; EPD driver and waveforms don't exist |
| Halium + pmOS on stock kernel | No | Same source problem as UT |
| **Debian chroot on rooted Android** | **Yes, today** | Full apt userspace; Onyx e-ink stack stays intact |
| Android GSI (`/e/OS`) | Yes | Real AOSP; degraded e-ink until the refresh shim exists |

The chroot route is what people actually run on e-readers, and it's worth keeping in mind
as a fallback: it costs nothing in display quality, and the telemetry problem is solved by
removing the Onyx apps and firewalling, not by replacing the kernel.

**Chosen path: `/e/OS`.** Concern about the e-ink regression was raised and accepted.
