# Third-party material and attributions

What this project reused, from where, and under what licence. Written
deliberately rather than assembled at the end, because most of what was borrowed
here is **knowledge** rather than code, and that is exactly the kind of reuse
that tends to go unattributed.

This project's own licence is **Apache-2.0 OR MIT** for code and
**CC BY-SA 4.0** for `docs/` (see `LICENSE`). Nothing below changes that; these
are other people's terms, recorded so the reuse is visible.

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

**None.** No third-party source file is copied in. Every `.c` / `.h` under
`src/` was written for this project.

The closest calls are `src/epdc_damage.h`, whose *shape* follows the ordinary
seqlock pattern, and `patches/main/0002-*.patch`, which is a diff against AOSP
and therefore inherits AOSP's licence when applied (below).

This section briefly said otherwise. `device/onyx/Palma2_Pro_C/qcrilam/` carried
[sonyxperiadev/QcRilAm](https://github.com/sonyxperiadev/QcRilAm) (Apache-2.0,
`ef51ec6`) as the client for
`vendor.qti.hardware.radio.am@1.0::IQcRilAudio`, without which VoLTE calls
connect silently. It was removed in favour of the stock proprietary equivalent —
reasoning in `docs/23-volte.md` — and remains in git history. Nothing from it
ships today, but it is credited under *Ideas* below, because reading it
confirmed an interface we had otherwise derived by hand.

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

**`sonyxperiadev/QcRilAm`** — Apache-2.0, and
**`phhusson/treble_experimentations`** — for the two `.hal` files it
reconstructed for GSI use. The `IQcRilAudio` / `IQcRilAudioCallback` interface
had already been derived here from the HIDL transport symbols in
`vendor.qti.hardware.radio.am@1.0.so` and from qcrild's own log strings; reading
theirs confirmed it exactly, including the declaration order of `setCallback`
and `setError`, which the device could not have told us. `docs/23-volte.md`.

**QTI `QtiTelephonyService.apk` and `ims.apk`** — Qualcomm proprietary.
Extracted from firmware the user already owns, into gitignored `firmware/`, and
never redistributed by this repository. `scripts/extract-qti-telephony.sh` and
`scripts/install-ims.sh` fetch them locally. Both are required for VoLTE, which
is why no image this project publishes can place a call.

---

## Unlocking and rooting: whose work this is

Neither technique originates here. Both were published by others first, and the
project would have had no starting point without them.

**`Kisuke-CZE/Palma_2_Pro-tips`** — <https://github.com/Kisuke-CZE/Palma_2_Pro-tips>.
No licence stated at time of writing.
**This is where the Fairphone 4 ABL swap for the Palma 2 *Pro* comes from.** The
insight it publishes — "since hardware is similar to Fairphone 4 we will take
Fairphone image to help" — is the whole basis of `docs/02` and
`scripts/fetch-fp4-abl.sh`: Onyx strips the unlock commands out of their ABL, but
the FP4's ABL is signed for the same SM7225 and still has them. It also
documents the Magisk-patched-boot-via-EDL rooting flow we followed.

**`jdkruzr/BooxPalma2RootGuide`** — <https://github.com/jdkruzr/BooxPalma2RootGuide>,
**CC0-1.0**.
The published rooting method for the Palma 2 (non-Pro): pull the boot partitions
over EDL, patch with Magisk, write them back. `docs/02` refers to this as "the
published Boox Palma 2 rooting method" — the one that **bootloops on a Pro**,
which is what forced the ABL route in the first place. Establishing that it does
not transfer to this model was a useful negative result, and it is that guide's
result being tested.

**Renate, MobileRead** — <https://www.temblast.com/edl.htm>.
Credited by the guide above as the source of its EDL material, and the origin of
much of the practical Qualcomm EDL knowledge the Boox community relies on.

**Magisk** (topjohnwu) — **GPL-3.0**.
Root. Used as shipped; nothing modified or redistributed here.

**bkerler/edl** — MIT. The EDL client itself (also listed under Tools).

**Fairphone / e Foundation** — Fairphone publishes GPL-compliant sources and
images, and `scripts/fetch-fp4-abl.sh` points at
<https://images.ecloud.global/community/FP4/> as one place to obtain an FP4 ABL.
The ABL binary itself is Qualcomm proprietary and is **not** redistributed by
this repository — the script fetches it, it is gitignored.

### Where we diverged

Worth recording so the difference is not mistaken for the original method: the
published procedure completes the unlock through `fastboot flashing unlock`,
which requires pressing a confirmation on screen. **On this device that menu is
invisible** — the bootloader renders to a DSI framebuffer that does not exist on
an EPD panel, so the screen stays blank and the prompt cannot be answered.

We finished the unlock host-side instead, writing `is_unlocked` and
`is_unlock_critical` directly into `devinfo` (offsets 13 and 14) over EDL:
`scripts/patch-devinfo-unlock.sh`. That part is ours, and `docs/02` records it
under "How it really went".

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

## Artwork shipped in the image

`device/onyx/Palma2_Pro_C/epdc-screensaver/artwork/01-great-wave.raw` is the
only third-party creative work this repository redistributes.

| | |
|---|---|
| work | *Under the Wave off Kanagawa (Kanagawa oki nami ura)*, also known as *The Great Wave*, from the series *Thirty-six Views of Mount Fuji (Fugaku sanjūrokkei)* |
| artist | Katsushika Hokusai (Japanese, Tokyo (Edo) 1760–1849 Tokyo (Edo)) |
| date | ca. 1830–32 |
| medium | Woodblock print; ink and color on paper |
| holder | The Metropolitan Museum of Art, New York |
| credit line | Rogers Fund, 1914 |
| object | 36491 — <https://www.metmuseum.org/art/collection/search/36491> |
| source image | <https://images.metmuseum.org/CRDImages/as/original/DP141063.jpg> |
| status | public domain; The Met **Open Access**, released under CC0 1.0 |

The underlying work is public domain by age. The Met additionally places its
Open Access images under CC0 1.0, so neither the photograph nor the print
carries a restriction here.

**How this was checked, rather than assumed.** The museum's own API reports
`"isPublicDomain": true` for object 36491, and the source image above is that
object's `primaryImage`:

```sh
curl -s https://collectionapi.metmuseum.org/public/collection/v1/objects/36491 \
  | python3 -m json.tool | grep -E 'isPublicDomain|primaryImage|creditLine'
```

That check is worth keeping, because the first image used during development was
a different Met file (`DP130155.jpg`) whose owning object could not be
identified, and therefore whose rights status could not be confirmed. It was
replaced rather than shipped on an assumption. Not every file under
`images.metmuseum.org/CRDImages/` belongs to an Open Access object.

**Derivation.** The shipped file is not the JPEG. It is an 824x1648 24-bit RGB
plane, cover-cropped and flat-quantised to 16 levels per channel by
`scripts/gen-screensaver.py --color --no-dither`. The recipe is in the repo, so
the derivation is reproducible from the source URL above.

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
* the shipped Hokusai artwork is public domain / CC0 and **may** be redistributed
  — it is the one third-party creative work here that can be
* the CERN-OHL-S on Caster does not reach us: we reimplemented an idea, took no
  gateware
