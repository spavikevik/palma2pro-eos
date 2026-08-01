# /e/OS on Boox Palma 2 Pro

Porting /e/OS to the Onyx Boox Palma 2 Pro (OPC1410R) to get off the stock firmware
and its telemetry to Chinese servers.

## Scope and disclaimer

This is independent interoperability work on hardware the authors own. It is not
affiliated with, endorsed by, or supported by Onyx International (Boox),
e Foundation, Fairphone, Qualcomm or Google. Product names and trademarks belong
to their respective owners.

**No proprietary binaries are distributed here.** The kernel, vendor libraries,
waveform data and TCON firmware remain Onyx's; `INSTALL.md` requires you to
extract them from your own device. Onyx has published no corresponding source
for the modified Linux kernel this device ships, which is a further reason none
of it is mirrored in this repository.

Disassembly was used only to determine the interfaces needed to make an
independently written display stack work with this hardware — ioctl numbers,
struct layouts, register values. Those are facts about an interface, and this
repository contains no code copied from Onyx.

**This will void your warranty and can permanently break your device.** Unlocking
the bootloader wipes `/data` unconditionally, and incorrect EPD power sequencing
or waveform data can damage the panel. There is no warranty of any kind — see
`LICENSE`. You are responsible for what you run on your own hardware, and for
your own jurisdiction's rules.

## Start here

New here? **[docs/20 — how this port happened](docs/20-history-and-method.md)** is
the narrative: what was tried, which routes were dead ends and why, and the
method that worked. It makes everything below make sense.

| | |
|---|---|
| **[docs/20](docs/20-history-and-method.md)** | how we got here: the phases, the failed routes, the method, and the mistakes worth not repeating |
| **[INSTALL.md](INSTALL.md)** | build it and install it on your own device, start to finish: unlock, backup, blobs, build, flash, boot |
| **[MANUAL.md](MANUAL.md)** | operator's manual: the hardware, how a pixel reaches the panel, the `/dev/ebc` API, the debugging playbook, and the traps |

Reference:

| | |
|---|---|
| [docs/19](docs/19-tcon-panel-abi.md) | developer reference: TCON, panel, EPD ioctls and DRM properties, each claim marked verified/derived/inferred |
| [docs/16](docs/16-build-flash-test.md) | build, flash and test workflow |
| [docs/17](docs/17-eink-device-tuning.md) | e-ink device tuning, with the reasoning |
| [docs/18](docs/18-refresh-algorithms.md) | how other open e-ink projects handle refresh |
| [docs/15](docs/15-task-per-layer-damage.md) | the main open task: per-layer damage |
| [THIRD_PARTY.md](THIRD_PARTY.md) | what was reused from other projects, and under what licence |
| [CLAUDE.md](CLAUDE.md) | working notes for coding agents: the non-negotiables, the traps, the method |

Open work is tracked in [issues](https://github.com/spavikevik/palma2pro-eos/issues),
labelled by difficulty.

## Device

| | |
|---|---|
| Model | OPC1410R, Boox Palma 2 Pro |
| SoC | Qualcomm Snapdragon 750G — SM7225, `lito`/`lagoon` family |
| RAM / Storage | 8 GB / 128 GB (+ microSD) |
| Display | 6.13" colour e-paper (Kaleido), Onyx EPD stack |
| Stock OS | Android 15 **system** (qssi) over an Android 11 **vendor** BSP |
| VNDK | 30 — vendor frozen at API 30 |
| Partitions | A/B (active slot **`_b`**), dynamic partitions (`super` = sda8), Treble-compliant |

The SoC is the single most useful fact in this project: **SM7225 is also the Fairphone 4
SoC**. Fairphone is GPL-compliant and publishes full kernel sources
(`FairphoneMirrors/android_kernel_fairphone_sm7225`, msm-4.19), and SM7225 has upstream
mainline support. Onyx publishes nothing. Every workaround below leans on FP4 in some way.

## Strategy

GSI first, device tree later. Recon is done — see `docs/findings.md`, which drives
everything below.

1. **Zero-risk analysis first.** EDL *reads* work on a locked bootloader, so `super` gets
   dumped and dissected before any bootloader work. This produces the refresh-shim spec
   and the go/no-go, at no risk to the device. (`scripts/dump-and-analyze-super.sh`)
2. **`/e/OS` GSI on stock vendor.** Replaces `system` only, keeping Onyx's vendor blobs and
   kernel — including the EPD driver. Target is the **Android 13** GSI, not 15: vendor is
   VNDK 30 and Android 15 deprecated VNDK.
3. **E-ink refresh controller.** The real deliverable. See below.
4. **Proper device tree port.** Only if 2 works and 3 is tractable.

## The actual hard problem

The bootloader is an annoyance. The e-ink stack is the project.

Onyx's refresh control — Regal/speed/smooth modes, per-app profiles, ghosting clears — is
driven from `/system`, which a GSI replaces. On a stock GSI the panel lights up but drives
itself like an LCD: continuous refresh, heavy ghosting, wrecked battery. So the deliverable
that decides whether this is a daily driver is a **replacement refresh controller**.

**Recon resolved the difficulty question favourably.** The EPD controller is exposed by
the *kernel*, not hidden behind a proprietary HAL:

```
/sys/devices/platform/onyx_epdc_fb.0     EPDC framebuffer driver
/sys/class/sepdc                          EPD controller class
/sys/bus/platform/drivers/onyx_epdc_mfd
/sys/module/onyxdsi
```

and `lshal` lists **zero** `vendor.onyx.*` services — every display HAL is stock Qualcomm.
The chain is Onyx Java → `libonyx_epd_listener.so` (JNI) → ioctl/sysfs on `onyx_epdc_fb`.
An `epdc_fb` driver is the classic i.MX-style E-ink API, so the transport is ours to drive.

Remaining unknown: whether Onyx also patched `SurfaceFlinger`/`services.jar` in place under
stock filenames. That changes how much *policy* we reimplement, not whether we can. Step 1
answers it.

## Why not Linux

Asked and answered — see `docs/why-not-linux.md`. Short version: Ubuntu Touch needs Halium
needs a rebuildable kernel, and Onyx has never shipped kernel source (6+ years of GPL2
violation). postmarketOS on mainline would boot the SoC and show nothing, because no EPD
driver or waveform data exists outside Onyx's blobs. Every path that keeps the screen
usable keeps the Onyx kernel.

## Layout

```
scripts/    device-side and host-side tooling
docs/       procedures, findings, decisions
backup/     EDL partition dumps      (gitignored — device-specific, contains IMEI/keys)
firmware/   extracted stock images   (gitignored — proprietary Onyx blobs)
out/        built images             (gitignored)
```

## Licensing

Onyx ships no kernel source, so anything we build reuses their proprietary vendor blobs
and a prebuilt kernel pulled from stock `boot.img`. Fine for a device you own. **Not
redistributable.** If this is ever published it has to be scripts and patches that build
against the user's own firmware dump — never a flashable image containing Onyx blobs.

Fairphone ABL and kernel sources are GPL-2.0 and separately licensed; using FP4's ABL to
unlock your own hardware is fine, redistributing a Boox image containing it is not.

## Risk

The Fairphone-4-ABL swap is the step that bricks devices. Onyx sells no unbrick service
and there is no public Palma 2 Pro firehose recovery package. EDL with a working loader is
the entire safety net, so it gets verified — dump *and* restore — before ABL is touched.
See `docs/02-unlock.md`.

## Licence

Code is dual licensed **Apache-2.0 OR MIT**; documentation under `docs/` is
**CC BY-SA 4.0**. See [LICENSING.md](LICENSING.md) for the terms; `LICENSE` is
a verbatim Apache-2.0 copy for automated detection.

No Onyx binaries are included or licensed here — the kernel, vendor libraries,
waveform blob and TCON firmware are extracted by each user from their own device
(`INSTALL.md` step 3) and remain Onyx's. See [THIRD_PARTY.md](THIRD_PARTY.md)
for what was reused from other projects and under what terms.
