# Third-party material and attributions

What this project reused, from where, and under what licence. Written
deliberately rather than assembled at the end, because most of what was borrowed
here is **knowledge** rather than code, and that is exactly the kind of reuse
that tends to go unattributed.

Three categories, kept separate on purpose:

* **Code** — source actually copied into this repository
* **Facts** — constants, struct layouts, register values and API semantics taken
  from someone else's documentation or source
* **Ideas** — designs and algorithms we reimplemented after reading theirs

Nothing in category *Facts* or *Ideas* carries the original licence into our
code, but all three deserve credit, and the distinction matters if this is ever
distributed.

---

## Code copied into this repository

**None.** No third-party source file has been copied in. Every `.c` / `.h` under
`src/` was written for this project.

The closest thing is `src/epdc_damage.h`, whose *shape* follows the ordinary
seqlock pattern, and `patches/main/0002-*.patch`, which is a diff against AOSP
and therefore inherits AOSP's licence when applied (below).

---

## Platform we build on

| project | licence | how it is used |
|---|---|---|
| **AOSP** (`frameworks/native`, SurfaceFlinger, Launcher3) | Apache-2.0 | our patches apply to it; `patches/main/0002-*` modifies `CompositionEngine/src/Output.cpp` |
| **LineageOS** | Apache-2.0 (mostly) | build system, device-tree conventions, `vendor/lineage` |
| **/e/OS (e Foundation)** | Apache-2.0 / GPL depending on component | the ROM we build |
| **BlissLauncher3** (e Foundation) | **GPL-3.0** | shipped as a prebuilt APK; we override *resources* via RRO and never modify or redistribute the APK. Note this differs from upstream Launcher3's Apache-2.0 — relevant if a patched launcher is ever distributed |

## Tools

| project | licence | use |
|---|---|---|
| **zig** (`zig cc`) | MIT | cross-compiles `src/*.c` for aarch64. Chosen over the NDK: ~100 MB against ~2 GB |
| **edlclient** (bkerler) | MIT | Sahara/Firehose EDL flashing and dumping, wrapped by `scripts/edl-*.py` |
| **LLVM** (`llvm-objdump`, `llvm-objcopy`, `llvm-readelf`) | Apache-2.0 with LLVM exceptions | disassembling the stock kernel and vendor binaries |
| **dtc** | GPL-2.0 | decompiling `dtbo.img` |

---

## Facts: constants, layouts and semantics learned from others

These are the ones that made the project work. Each is a fact about *this
hardware*, but we would not have found several of them without prior art.

**Rockchip EBC (`ebc_dev.h`, `ebc_dev_v8.S`), and the PineNote
reverse-engineering community** — GPL-2.0, plus the PINE64 wiki.
Onyx's EPD driver is a port of the Rockchip EBC design. The ioctl base `0x7000`
and the general shape of `ebc_buf_info` came from there, and gave us the map for
`/dev/ebc`. Two corrections we had to make for this device, recorded in
`docs/03`:

* Onyx inserted `GET_EBC_DRIVER_SN` at `0x7002`, shifting the upstream numbering
  by +1 above `0x7001`
* `SET_EBC_SEND_UPDATE = 0x700c` is **not** shifted, and was recovered from
  Onyx's own SurfaceFlinger call site rather than from upstream

Also from that lineage: the warning that `EBC_GET_BUFFER` (0x7000) *blocks*,
which we confirmed the hard way before finding it documented.

**FBInk** (NiLuJe) — GPL-3.0.
`fbink.h` is the clearest description anywhere of what the e-ink waveform modes
(`DU`, `A2`, `GC16`, `GL16`, `REAGL`, `GCK16`…) actually mean, with timings and
caveats. The mode vocabulary is shared across Kobo, Kindle, reMarkable, Rockchip
and this Onyx panel. Summarised in `docs/18`; no code taken.

**libremarkable / rm2fb community** — MIT / GPL depending on component.
Confirmed the `mxcfb`-style "rect + waveform mode + update marker" update
structure as a cross-vendor pattern, which is exactly the shape of our 40-byte
`ebc_send_update`.

**inkwave** (fread-ink) — GPL-2.0.
Format reference for the `.wbf` waveform blob pulled from this device
(`firmware/analysis/eink_waveform.wbf`). Referenced in `docs/13`; not yet run.

**Fairphone 4** — the ABL used to unlock this device came from FP4 firmware,
which shares the SM7225 SoC. Qualcomm proprietary; used locally, not
redistributed. `docs/02`.

---

## Ideas: algorithms reimplemented after reading theirs

**Modos Caster / Glider** (Modos Labs) — **CERN-OHL-S v2** (hardware and
gateware).
The settle pass in `src/epdcshim.c` is our reimplementation of Caster's hybrid
mode: drive content in a fast mode while it is changing, then re-render in
greyscale once it stops. Caster does this **per pixel in FPGA gateware** with
2.7 MB of per-pixel state in DDR3; ours is **per screen on a timer** in
userspace. No gateware, HDL or code was taken — porting Caster to this device is
not viable, and `docs/18` explains why (different FPGA vendor, no DSI input,
and the per-pixel state does not fit in the TCON's block RAM).

**KOReader** — AGPL-3.0.
Its `UIManager:setDirty()` refresh-type model (`full` / `partial` / `ui` /
`fast` / `a2`, promotion to a flashing refresh after N updates, explicit
no-merge flags, flashing deliberately when a window appears or disappears) is
the clearest statement of "classify updates by intent rather than inspecting
content". Our `fullevery` counter was arrived at independently and turns out to
be their promotion counter; the analysis in `docs/18` is drawn from their source
comments. No code taken.

**Rockchip EBC DRM driver** (Samuel Holland) — GPL-2.0.
Its "diff mode" — skip drive for pixels whose value did not change, because
GC16 otherwise flashes even unchanged pixels — is the same trade-off as our
`update_mode`, and reading it is what made that field's behaviour make sense.
Design read, nothing copied.

**Kobo / KOReader's "full refresh every N pages"** (`DRCOUNTMAX`, default 6) —
the user-facing form of the same promotion idea, and the reason
`persist.epdcshim.fullevery` exists.

---

## Onyx proprietary material

This is the part to be careful about.

The device's stock firmware — kernel, vendor libraries, `surfaceflinger`,
`libsdedrm.so`, the composer service, DeskClock, waveform blobs and TCON
bitstreams — is **Onyx proprietary** and is **not redistributed by this
repository**. Everything under `firmware/` and `firmware/stock-extract/` is
gitignored and exists only on the local machine, extracted from the user's own
device.

The `onyx-sf` branch, which staged Onyx's SurfaceFlinger and its 130-library
closure, has been **deleted**, and those binaries removed from both the working
tree and the device. What was learned from them is kept in `docs/12` as prose.

Separately worth stating: **Onyx ships no kernel source** for this device
despite shipping a modified Linux kernel, which is a GPL-2.0 violation. That is
why `docs/06` exists as reverse-engineering notes rather than as a source
reference, and why nothing here can be redistributed as a flashable image.

---

## If this is ever distributed

* the SurfaceFlinger patch is a derivative of AOSP — Apache-2.0, keep the headers
* `src/*.c` is ours to license as we choose
* **no Onyx binary may be included** — not the kernel, not vendor, not the
  waveform blob, not the TCON firmware
* a launcher built from BlissLauncher3 source would be **GPL-3.0** and would
  require offering the corresponding source
* the CERN-OHL-S on Caster does not reach us: we reimplemented an idea, took no
  gateware
