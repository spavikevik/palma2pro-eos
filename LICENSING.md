# Licensing

`LICENSE` is a verbatim copy of the Apache License 2.0 so that automated
licence detection classifies this repository. The actual terms are below: the
code is dual licensed and the documentation is not under Apache at all.

Copyright 2026 Stefan Pavikjevikj.

This repository is licensed in two parts.

## Code — Apache-2.0 OR MIT, at your option

Everything except `docs/` — `src/`, `scripts/`, `patches/`, `device/`,
`build/`, `tests/`, and the top-level Markdown files — is dual licensed:

* Apache License 2.0 — [`LICENSE-APACHE`](LICENSE-APACHE) (identical to `LICENSE`)
* MIT License — [`LICENSE-MIT`](LICENSE-MIT)

Use whichever you prefer. SPDX: `Apache-2.0 OR MIT`.

The dual form exists so this drops cleanly into either world: Apache-2.0 is what
AOSP, LineageOS and /e/OS use and carries an explicit patent grant, while MIT
suits projects that prefer the shorter, more permissive form.

## Documentation — CC BY-SA 4.0

Everything under `docs/` is licensed under the Creative Commons
Attribution-ShareAlike 4.0 International License —
[`docs/LICENSE-CC-BY-SA-4.0`](docs/LICENSE-CC-BY-SA-4.0).
SPDX: `CC-BY-SA-4.0`.

Those files are the reverse-engineering write-ups: the EBC ioctl API, the EPD
update path, the refresh-algorithm survey, the hardware notes. Share-alike keeps
that work open if it is republished or built upon.

`MANUAL.md`, `INSTALL.md`, `README.md` and `THIRD_PARTY.md` are at the top level
and fall under the code licence, so they can be copied into a build system,
wiki or downstream repository without the share-alike obligation.

---

## What this does NOT cover

**Onyx proprietary material.** This repository contains no Onyx binaries and
none can be licensed here. The kernel `Image`, device trees, vendor libraries,
waveform blob (`.wbf`) and Lattice TCON firmware are Onyx's, are extracted by
each user from their own device (see `INSTALL.md` step 3), and remain under
whatever terms Onyx applies to them. Nothing above grants any right to them.

Note also that the kernel is a modified Linux for which Onyx publishes no
source, which is a GPL-2.0 violation on their part. That is a reason those
binaries are not redistributed here, and it is not cured by anything in this
repository.

**Upstream projects.** Patches under `patches/` are diffs against AOSP. Applying
them produces a derivative of AOSP, which is Apache-2.0 — our licence covers the
patch text, not the resulting combined work.

**Third-party work we learned from.** `THIRD_PARTY.md` records what was reused
and under what terms, separating code (none copied), facts (constants and API
semantics taken from others' documentation), and ideas (algorithms
reimplemented). Those projects' licences — GPL-2.0 for the Rockchip EBC driver,
GPL-3.0 for FBInk, AGPL-3.0 for KOReader, CERN-OHL-S for Modos Caster — apply to
their work, not to ours, but they are credited because that reuse is real.

---

## Reverse engineering: purpose and limits

Recorded so the intent is unambiguous.

The disassembly in this project served one purpose: determining the interfaces
required to make independently written software interoperate with this device's
display hardware. What was recovered is **interface information** — ioctl command
numbers, structure layouts and field offsets, DRM property names, register and
GPIO assignments, panel timings. `docs/19` is the resulting specification and
`docs/20` records how it was obtained.

Concretely, and verifiably from the tree:

* **no code was copied** from Onyx or any other proprietary source; every file
  under `src/` was written for this project
* **no proprietary binary is distributed**; the kernel and blobs were removed
  from git history before this repository was published anywhere, and each user
  extracts their own under `INSTALL.md` step 3
* techniques originating with others — notably the bootloader unlock — are
  credited to their authors in `THIRD_PARTY.md` rather than presented as ours

Nothing here is a legal opinion. Interoperability provisions differ by
jurisdiction, and anyone intending to redistribute images, ship a product, or
otherwise go beyond running this on their own hardware should take their own
advice first. That step would also mean distributing material this repository
deliberately does not.
