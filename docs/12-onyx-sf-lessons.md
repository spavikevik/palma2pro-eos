# What Onyx's SurfaceFlinger taught us, and why we stopped using it

For a while the plan was to run Onyx's stock SurfaceFlinger on our Android 15
build: it already knows how to drive the EPD, so borrowing it looked like the
shortest route to a working display. That plan is **abandoned**, and the
proprietary binaries it needed are gone from this tree. This is what the
detour bought, because most of it is what eventually made our own SF work.

## Why it was abandoned

Their binary boots, registers, enables the display and holds 90 layers -- and
issues **zero DRM commits**. `dmesg | grep -c update_epdc` is 0 for an entire
boot, while logging continuously:

```
E SurfaceFlinger: ERROR(Unknown error 2147483640, -2147483640).
                  Failed to call parcel s.read(data)
```

Our SF, by contrast, composites correctly and produced 363 plane commits in the
same situation. It was never the compositing that was broken -- only the update
rectangles, which is a far smaller gap than a whole SurfaceFlinger. Once that
was understood (docs/11), their binary had nothing left to offer.

An earlier revert note claimed their SF "never composites -- screencap empty".
That reasoning was wrong: an empty `screencap` means the **display is asleep**
(`dumpsys display` -> `Display State=OFF`). The conclusion happened to be right,
but it was retested properly with the display held awake before being trusted.

## What the detour actually established

**The EPD is driven from SurfaceFlinger, not from the composer alone.** Their
SF opens `/dev/ebc` directly and logs `hasHwTcon`. Stock AOSP SF never touches
that node, which is why a prebuilt GSI can never light this panel. This is what
turned the project from "flash a GSI" into "build from source".

**The ioctl numbering.** `LD_PRELOAD` tracing their SF (a read-only shim that
logged and forwarded) recovered the real command set, and showed that
`EBC_GET_BUFFER` (0x7000) -- which hung the device three times -- is never used
by their own userspace. The working full-screen refresh command,
`SET_EBC_SEND_UPDATE = 0x700c`, came from disassembling their call site.

**The update struct.** Field order and size were recovered from their binary and
the kernel's printk, and turned out to be exactly the struct the DRM plane
property carries -- 40 bytes, 8 of them, `{rect[4], waveform_mode, update_mode,
update_marker, temp, flag}`. `src/ebcrefresh.c` still uses it, and the shim
writes the same layout.

**Two ABI mismatches worth remembering**, both found by making their binary run
against our framework:

* AIDL assigns transaction codes by declaration order. One extra method in our
  `ISurfaceComposer.aidl` shifted the 45 methods after it by one, so our
  `getCompositionPreference` invoked their `getDisplayedContentSamplingAttributes`.
  It surfaced as `getCompositionColorSpaces()` returning null and killing
  `system_server`. `scripts/aidl-txn-codes.py` recovers the codes from two
  binaries and diffs them.
* Their `libgui` sends 216-byte display events, ours 224 (`numberQueuedBuffers`
  plus padding). Both dialects were genuinely on the wire *per connection within
  one process*, so no fixed size worked -- reading in 8-byte granules and
  demultiplexing on datagram size was the only thing that could.

Neither matters now, but both are the kind of mismatch that reappears whenever
vendor and platform binaries are mixed, and neither was guessable from source.

**`ro.*` properties are first-writer-wins, and vendor beats system.** Setting
`vendor.display.use_smooth_motion=0` via `PRODUCT_SYSTEM_PROPERTIES` silently
lost to Onyx's `/vendor/build.prop`; it had to be set from `on init`.

## What is no longer in the tree

* `surfaceflinger_onyx` and its 130-library closure (proprietary; never
  committed -- they were always gitignored)
* `scripts/onyx-sf/` -- the staging tooling that generated soong prebuilts and
  patched their binaries
* `patches/onyx-sf/` -- the AIDL reorder, the 216/224-byte event shim, the
  launch rc, and the `adb root` patch

The `adb root` patch is deliberately gone rather than moved: it forced adbd's
root restart on debuggable builds, and nothing in the current design needs it.

Still live from that era: `patches/main/0001-*` (the `/dev/ebc` ueventd rule),
`src/ebcrefresh.c`, `src/ebcfb.c`, `scripts/aidl-txn-codes.py` and
`scripts/edl-delta-flash.py`.
