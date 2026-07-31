# Building our own kernel: what it would take

Short answer: **the SoC half is ordinary work; the display half is the blocker,
and the display is the entire point of this device.**

## What we have

| | |
|---|---|
| kernel | `4.19.157-perf-g3d47a6619220-dirty`, built by `onyx@onyxUbuntu`, clang 10.0.7 (Android NDK) |
| source | none -- Onyx has never published it (long-standing GPL2 violation) |
| config | **recovered** from the Image via `CONFIG_IKCONFIG` -> `firmware/analysis/kernel-config.txt` (170 KB) |
| DTB / DTBO | `prebuilt/dtb/board-{0,1}.dtb`, `prebuilt/dtbo.img` |

The config was extracted by finding the `IKCFG_ST` marker and inflating the gzip
blob after it. That single file answers most questions about this kernel without
guesswork, and is worth consulting before speculating about kernel features.

## The feasible part

SM7225 is `lito`/`bitra`. Qualcomm's `msm-4.19` sources exist publicly, and --
more usefully -- **LineageOS maintains a kernel tree for the Fairphone 4, which
is the same SoC** (`android_kernel_fairphone_sm7225`). Between that, the exact
`.config`, and the DTB/DTBO, a kernel that boots this board and drives storage,
radios and the SoC is realistic work.

## The blocker

Everything Onyx wrote is **built in**, not modular:

```
built-in (=y): 1766        modules (=m): 5
CONFIG_MODULES=y  CONFIG_MODVERSIONS=y
```

```
CONFIG_FB_ONYX_SOFTWARE_EPDC=y          the EPD pipeline itself
CONFIG_ONYX_EPDC_POWER_USE_REGULATOR=y
CONFIG_MFD_TPS6518X=y / REGULATOR_ / SENSORS_    e-ink PMIC
CONFIG_TOUCHSCREEN_ONYX_{WACOM,PARADE,CYTTSP5,CYTTSP6,FTS,ELAN,ISTARIC}=y
CONFIG_ONYX_FINGERPRINT_{CHIPSAILING,FORTSENSE,MICROARRAY}=y
CONFIG_ONYX_TP_{EXTRA,PM_NOTIFIER,DEBUG_ENABLE,REPORT_STYLUS_PEN_TYPE}=y
```

So there is **no `.ko` to salvage**. And even if there were, `CONFIG_MODVERSIONS=y`
means symbol CRCs must match a kernel built from the source we do not have.

A self-built kernel would boot, drive the SoC, storage and radios -- and display
nothing. On an e-reader that is not a partial success.

Note `CONFIG_FB_ONYX_SOFTWARE_EPDC`: the waveform pipeline runs in **software** on
the SoC, not in a dedicated hardware EPDC. That is encouraging for an eventual
clean-room driver -- the algorithm is code rather than an opaque IP block, and
the hardware interface is I2C to a documented TI TPS6518x PMIC plus a firmware
upload to a Lattice TCON. Combined with the ioctl surface already mapped in
`docs/03-ebc-api.md`, a rewrite is large but not mysterious.

## The firmware blobs

`CONFIG_EXTRA_FIRMWARE` compiles these *into* the Image:

```
waveform/eink_waveform.wbf                          e-ink waveform table
mxo/mxo{1300,4300}_nvcm_8{1,2,3,4,6,7}.ied          EPD controller firmware (9)
lfcpnx/lfcpnx100_tcon_fw_{99,9e,9f,a2,a5,a7}.bin    Lattice TCON firmware (6)
```

`lfcpnx` confirms the Lattice TCON identified earlier by other means. These are
the *data* an EPD driver feeds the hardware, so any clean-room driver needs them.

The `.ied` and `.bin` blobs are **not** on any filesystem: searched `system`,
`vendor`-adjacent images, `persist` and `onyxconfig` -- nothing.

**The waveform is the exception, and we already have it.** It is readable on a
running stock system at `/waveform/eink_waveform.wbf` and was pulled long before
this analysis started: `firmware/analysis/eink_waveform.wbf`, 599,622 bytes, with
its header `filesize` field matching the file length exactly and its
`mode_version` / `waveform_version` matching the kernel's own boot-time parse
(see [03-ebc-api.md](03-ebc-api.md)). Curiously it does **not** appear anywhere
in the Image -- searched by header and by four interior chunks, all absent -- so
despite `CONFIG_ONYX_EPDC_FIRMWARE_WAVEFORM_KERNEL=y` the copy the driver
publishes is not a byte-identical built-in one. Unresolved, and not worth
chasing: we have a validated blob either way.

**Only about three of the fifteen matter.** The DTBO gives the TCON node
`fw-product-id = <0x81>`, and the `_XX` suffix on the `.ied` files is that
product ID rather than a version -- so this board uses the `_81` pair plus the
waveform, and the other twelve blobs are for other panels. See
[07-epd-hardware.md](07-epd-hardware.md), which maps the whole EPD chain
(panel `ED061KC1` 1648x824, Lattice CertusPro-NX TCON over DSI, TI TPS65185
rails) out of the DTBO.

### Extraction: attempted, NOT successful

`scripts/extract-builtin-fw.py` gets partway. It locates the table structurally
(a raw `Image` has no symbols or section headers) and resolves the *name*
pointers correctly:

```
located 15/15 name strings
table at 0x34755b0, 9 consecutive entries resolve
virtual-address bias 0xffffff8005165ae8
```

The names come out in `CONFIG_EXTRA_FIRMWARE` order, so the table and the bias
are right. But the *data* pointers do not map into the image:

```
mxo/mxo1300_nvcm_81.ied   name_off=0x3079fd8  data_off=0x47f6948  size=1027
mxo/mxo4300_nvcm_81.ied   name_off=0x307a008  data_off=0x47f6950  size=1027
```

Two things are wrong there: the data pointers are **8 bytes apart** while each
claims 1027 bytes, and they land ~14.7 MB past the end of a 60.7 MB image. So the
second field is not a pointer to the blob -- the `struct builtin_fw` layout
assumed (name/data/size, 24 bytes) does not match this kernel. Possibly an
indirection, possibly a different struct in Onyx's tree.

Two failed approaches are recorded so they are not repeated:

* **voting on the VA bias** -- counting, for every aligned u64, which bias would
  map it onto some name string, then taking the most popular. Pure noise: 354,975
  "agreements" and one bogus 8 MiB extraction. With 15 targets in a 60 MB image,
  popularity means nothing.
* **first structural match wins** -- matching consecutive name-pointer gaps
  against the string layout, then trusting the first hit. Coincidence: a match at
  `0x3468568` whose bias resolved zero entries. Candidates must be *verified* by
  counting how many consecutive entries resolve, which is what the script does
  now.

A **third** dead end, recorded for the same reason: re-deriving the bias by
requiring many *distinct* names to agree (rather than "some name", which was the
original voting flaw) also fails here. All fifteen name strings are packed into
**304 bytes** (`0x2d664c0`..`0x2d665f0`), so any monotonic stride-8 pointer run
can be bias-fitted onto twelve of them. The top five candidate biases all scored
12/15 and differed by only 8 or 32 bytes. Dumping the winner shows why: the
records are 24 bytes of `{u64 1027, ptr, ptr}` where the third field increments
by exactly 8 per record and resolves *mid-string*. Packed strings defeat
pointer-fitting; the constraint is much weaker than it looks.

### The blob region IS located, by content

Going at the data directly worked where the table did not. The Lattice
configuration **sync word `FFFFBDB3`** occurs exactly **6 times** -- and there are
exactly 6 `lfcpnx100_tcon_fw_*.bin` files. For a specific 4-byte pattern in a
56.5 MB image, chance expectation is ~0.01 occurrences, so this is signal:

```
0x1a0f0e2  0x1a189d2  0x1a31eb2  0x1a3b7a2  0x1a54c82  0x1a5e572
gaps:  0x98f0  0x194e0  0x98f0  0x194e0  0x98f0
```

Each is followed by `FFFF3B...`, the normal Lattice preamble. The alternating
gaps mean two size classes. Surrounding data is max entropy (measured 8.00
bits/byte over 1 MB mid-image, against ~2.3 in the tail), consistent with FPGA
bitstreams. Taken with the max-entropy `data` pointers seen earlier at
`0x17f3c20` and `0x1a80c88`, the firmware region is roughly
**`0x17f0000`..`0x1a90000`** (~2.7 MB).

That is enough to carve candidates by sync word without the table at all. What is
still missing is exact blob *boundaries* -- a bitstream starts before its sync
word, after leading `0xFF` padding -- so carving would produce plausible but
**unverified** files. Since nothing in the port currently needs them, and
`fw-product-id = <0x81>` means only about three blobs ever will, this is left
here rather than guessed at.

## Recommendation

Keep the prebuilt kernel. It costs us the Android 15 BPF version check (already
patched around in `NetBpfLoad.cpp`) and any on-screen boot console
(`# CONFIG_VT is not set`, so no framebuffer console is possible), and buys
nothing the port currently needs.

Revisit only if Onyx publishes source, or if the EPD work reaches the point where
owning the driver is the goal rather than a means to a booting device.
