# The EPD update path: what the traces actually show

Two independent observations, both from a running device, that between them
relocate this problem.

## 1. Onyx's SurfaceFlinger drives /dev/ebc itself

Their stock SF, run on our Android 15 build, logs:

```
E/SurfaceFlinger: Going to open /dev/ebc
E/SurfaceFlinger: could not open fd /dev/ebc        <- when the node is 0600
I/SurfaceFlinger: hasHwTcon: 0
```

So the EPD control path lives in **SurfaceFlinger**, not solely in the vendor
composer. Stock AOSP SF never opens that node, which is why the panel stays dead
no matter how healthy the composer is. `docs/03-ebc-api.md` had this as
inference; this is the binary saying it.

## 2. The commands they use are NOT the ones we assumed

`libebctrace.so` (LD_PRELOAD, read-only, logs and forwards) attached to their SF
for 30 s of startup captured every `/dev/ebc` ioctl it makes:

| request | rc | note |
|---|---|---|
| `0x7029` | 0 | argument buffer unchanged |
| `0x7021` | 0 | **driver writes back**: first int32 0 -> `1017` |
| `0x701e` | 0 | |
| `0x7022` | 0 | called with no argument |

**`0x7000` (`GET_EBC_BUFFER`) is never called.** That is the command that hung
this device twice -- once via `ebctool refresh --go`, once via `ebcprobe 1` -- and
it hangs silently: the captured `dmesg` covering the hang contains no EBC line at
all, consistent with a `wait_event` that never completes rather than a fault.

The numbering in `docs/03-ebc-api.md` was extrapolated from upstream Rockchip,
where `0x7000..0x7003` are the buffer calls. Onyx's driver answers `0x7002` and
`0x7003` (both confirmed live), but their own userspace drives it through
`0x701e`-`0x7029`, which upstream does not define. **Do not call `0x7000`.**

Mapping those four numbers to the 19 command names present in the kernel
(`GET_EBC_*`, `SET_EBC_*`) is still open. Scanning for `MOVZ #0x70xx` immediates
finds nothing for them -- but also nothing for `0x7003`, which demonstrably
works, so the dispatch is a `sub w?, w0, #0x7000` plus a dense switch and the
immediates are small. It needs real disassembly around `0x57c000`, not a pattern
search.

## 3. The kernel's EPDC plane hook is already being reached -- and rejects

Under **our** SurfaceFlinger, with the vendor composer doing the atomic commits:

```
create framebuffer: (64x824@AB24) pixel_format[ABGR8888] stride[256]
__sde_plane_atomic_update_epdc(): error! FB[190] vaddr[...] width[53] height[824] stride[64] fb_width[64]
ONYX: Pending Wakeup Sources: drm_epdc_update ...
```

70 such errors in one capture. Not only small surfaces -- full-panel commits fail
identically:

```
width[1648] height[823] stride[1664] fb_width[1664]
width[1648] height[820] stride[1664] fb_width[1664]
```

So the plumbing is intact: the composer commits to the EPDC plane, the kernel
enters its EPDC update hook, and the hook bails. It has a framebuffer and a
valid `vaddr`; what it does not have is update parameters. That matches the
`EPDC_UPDATE_PARMS_ADDR` / `EPDC_UPDATE_CNT` plane properties documented in
`docs/03-ebc-api.md` -- Onyx's SF supplies them, ours does not.

## PROVEN BY ELIMINATION: update parameters are REQUIRED, not a hint

Both halves were run on hardware, separately, and neither works alone.

| | Onyx's SurfaceFlinger | our SurfaceFlinger |
|---|---|---|
| composites? | **no** -- `layerHistory active=0`, zero EPDC plane commits, `screencap` returns 0 bytes | **yes** -- `active=1`, commits flowing |
| supplies EPD update params? | yes, it has `EpdcManager` / `EpdcWrapper` / `transferEpdc` | **no** -- our libgui has no `epdc` symbols at all |
| result on the panel | blank | blank |

With our SF running, **every single** plane commit is rejected:

```
__sde_plane_atomic_update_epdc(): error! FB[187] vaddr[...] width[53] height[824] stride[64] fb_width[64]
```

not one succeeds. So no composited pixel ever reaches the buffer the EPD scans
out, and `ebcrefresh` faithfully redraws an empty buffer -- which is exactly what
is seen: the panel flashes black then settles grey, with no content.

**CORRECTION -- that inference was wrong.** Disassembling the kernel's own reject
path settles what the precondition actually is. `__sde_plane_atomic_update_epdc`
begins:

```
ldp  w21, w20, [x22, #0x28]    ; plane width, height
cbz  x23, <error>              ; vaddr must be non-NULL
ldr  w8, [x27, #0x1360]
cmp  w21, w8
b.ne <error>                   ; width must EQUAL a global
ldr  w8, [x27, #0x1364]
cmp  w20, w8
b.ne <error>                   ; height must EQUAL a global
```

The globals are the panel dimensions, and the observed failures fit exactly:

* `width[53] height[824]` -- height matches 824, width 53 != 1648 -> rejected
* `width[1648] height[823]` -- width matches, height 823 != 824 -> rejected

So the commit is refused for **plane geometry**, not for missing update
parameters. Nothing in this function reads `EPDC_UPDATE_PARMS_ADDR`. Whether
those properties are needed *later* in the pipeline is untested and now
unsupported by any evidence we have.

### What is actually happening under our SF

Only one plane is ever committed, over and over, with a constant and strange
geometry: `width[53] height[824] stride[64] fb_width[64]` -- a 64-pixel-wide
buffer, full panel height, two alternating `drm_plane_state` pointers. That is
not the UI. Our SurfaceFlinger is compositing (`layerHistory active=1`) but is
never handing the display a full-panel plane.

Forcing GPU/client composition (`service call SurfaceFlinger 1008 i32 1`, which
succeeds as root) does not change it -- the same 53x824 plane keeps failing.

**The open question is therefore what that 53x824 plane is and why no
full-screen plane is committed**, not how to supply update parameters. Worth
checking next: the display mode SF selected versus the panel's native mode, and
whether `dsi_display0=qcom,mdss_dsi_rm69299_visionox_amoled_cmd` in the kernel
cmdline (an AMOLED panel name, on an e-ink device) means the wrong panel
configuration is active.

Onyx's SF has the parameter machinery but sits idle because the regions
originate ABOVE it (`Surface::transferEpdc`), and our framework never calls it.
Ours composites but supplies nothing. The missing piece is identical in both
cases: `EpdcWrapper` regions flowing from the app/framework layer into
SurfaceFlinger.

That makes option 2 below the only route, and it is all our own code.

### Already de-risked on hardware

* `hwc_epdc_llist` -- LTRB + mode, 20 bytes, confirmed from producer AND consumer
* the flatten wire format -- `[batch][word_count][words]`
* the 22-rect cap, and why `mergeByMode` exists
* `SET_EBC_SEND_UPDATE = 0x700c`, and `ebcrefresh` visibly driving the panel
* root, `adb remount` overlayfs hot-swap, and `edl-delta-flash.py`

## CORRECTION #2 (supersedes the one below): SET_EBC_SEND_UPDATE *is* the path

With Onyx's SurfaceFlinger running under a fully booted /e/OS (onyx-sf branch),
the kernel logs their SF driving the panel directly:

```
SWEpdcManager: ### FW, mode -1
epdc_ioctl(): -- SET_EBC_CLEAR_ALL_UPDATE !
epdc_ioctl(): set force_waveform = -1!
epdc_ioctl(): SET_EBC_SEND_UPDATE -- magic[1] [x=0 y=0 w=1648 h=824]! flags = 0x31000!
epdc_ioctl(): SET_EBC_SEND_UPDATE -- magic[2] [x=0 y=0 w=1648 h=824]! flags = 0x21000!
SurfaceFlinger: refresh screen (0, 0 - 1648, 824) waveform_mode 2 flags 0x31000 marker 1
```

and the vendor composer doing the same on its own path:

```
SDM: update_to_display[1/0] -- marker[1] waveform_mode = 12, update_mode = 1,
     Rect[0 0 1648 824], flags = 1000
```

The earlier conclusion that `/dev/ebc` carries no per-frame traffic was an
artefact of tracing their SF with **no clients attached** -- it had nothing to
composite, so it sent nothing. With a real framework above it, SF submits
`SET_EBC_SEND_UPDATE` itself.

Note the parameters match what `ebctool`'s dry run predicted long ago:
full-screen rect, `waveform_mode 2` (the vendor's ordinary composition mode from
docs/03), `flags 0x21000`.

### The panel WORKS -- proven

Those two updates fire at `Setting power mode 0`, i.e. the standard e-ink
clear-on-screen-off. The panel accepted them. So the whole hardware chain --
waveform, TCON, PMIC, EPD pipeline -- is functional under our build. There is no
hardware or driver problem left to solve.

### What is actually missing

Only **two** `SET_EBC_SEND_UPDATE` calls happen in an entire session, both from
the power-off clear. Input, launcher activity and `powerMode=On` produce none.
SF refreshes on content change, and it is never told content changed, because
EPD update regions originate ABOVE SurfaceFlinger: apps call
`Surface::transferEpdc`, the regions ride to SF inside `BufferData`, and SF
forwards them. Our /e/OS framework never calls it -- our libgui has no `epdc`
symbols at all.

So the display is dark not because the EPD is broken, but because nothing is
asking for a refresh.

### Two ways forward

1. **A forced-refresh daemon.** `SET_EBC_SEND_UPDATE` is proven working with
   known-good parameters, and unlike `GET_EBC_BUFFER` it does not hang. A small
   service issuing periodic full-screen updates would make the panel usable
   immediately. Needs the ioctl NUMBER, which is best obtained by tracing their
   SF now that it actively sends (docs/03's `0x700c` is unconfirmed and the
   numbering is +1-shifted above 0x7001).
2. **Implement `transferEpdc` properly** in our libgui plus a caller in the
   framework draw path. Correct, incremental, redistributable -- and the design
   is fully recovered already (`hwc_epdc_llist`, the flatten format, the 22-rect
   cap, `mergeByMode`).

(1) gets a working screen fastest; (2) is the real fix and the thing `main`
ultimately needs.

## SUPERSEDED: /dev/ebc is init-time config only

An earlier revision of this document concluded that driving `/dev/ebc` from our
SF was the promising route. **A second trace disproved that.** With Onyx's SF
registered and `bootanimation` actively compositing, the tracer captured the same
four ioctls and *nothing else* -- no per-frame traffic at all. `/dev/ebc` is
opened once and configured once; the update path is elsewhere.

Corroborating, from `dmesg` while their SF ran:

```
epdc_open(): OK!
epdc_mmap(): [virt_buf_handwrite] [system ion] vma start: 0x78270ce000, size: 0x52f000
__sde_plane_atomic_update_epdc(): error!      x0   (was 70 under our SF)
```

Zero plane-hook errors under their SF versus 70 under ours, with no extra
`/dev/ebc` traffic. So per-frame updates go through the composer's DRM atomic
commit, and what differs is the *parameters* SF hands the composer.

## Where the parameters come from: Onyx extended libgui

Diffing their `libgui.so` against ours (3049 vs 3126 exported symbols, 353
differing) found a private EPD API that AOSP has no trace of. Our libgui exports
**zero** `epdc` symbols; theirs exports 25:

```
EpdcWrapper::addEpdc(int, int, int, int, int)      rect + mode
EpdcWrapper::addEpdcList(vector<hwc_epdc_llist> const&, bool)
EpdcWrapper::mergeByMode(vector<hwc_epdc_llist> const&, vector<...>, ...)
EpdcWrapper::setBatch(int) / getBatch() / getEpdcCount() / isEmpty() / clear()
EpdcWrapper::flatten / unflatten / getFlattenedSize / flattenEpdcList
Surface::transferEpdc(vector<hwc_epdc_llist>&)
Surface::clearEpdcList()
SurfaceComposerClient::Transaction::transferEpdc(sp<SurfaceControl> const&, EpdcWrapper&)
BufferData::readEpdc(Parcel const*) / writeEpdc(Parcel*)
```

That is the whole design, readable from the symbol names:

* the element type is **`hwc_epdc_llist`** -- an `hwc_`-prefixed struct, i.e. the
  composer HAL's own type, so this is the exact shape the vendor composer expects;
* update regions are attached per-surface (`Surface::transferEpdc`) and ride to
  SF **inside `BufferData`** (`readEpdc`/`writeEpdc`), not as a side channel;
* `mergeByMode` confirms the region-merging behaviour long suspected in
  `docs/03-ebc-api.md` -- regions are coalesced per waveform mode before submission;
* `setBatch`/`getBatch` implies updates are grouped into batches.

So the EPD update originates **above** SurfaceFlinger, in whatever draws, and SF
forwards it. A stock AOSP client never calls `transferEpdc`, so SF has nothing to
forward, so the composer commits without update parameters, so the kernel's
plane hook errors. Every observation we have fits that chain.

## What this means for the port

Two options, and the measurement above settles which is realistic.

**Replacing our libgui with theirs: not viable.** Our libgui exports 215 symbols
theirs lacks -- `setLuts`, `setPictureProfileHandle`, `setEdgeExtensionEffect`,
`setBufferReleaseChannel`, `getMaxLayerPictureProfiles`, `setActivePictureListener`,
`JankDataListener::flushJankData` and more. Our framework's JNI
(`libandroid_runtime`) is linked against those; swapping the library breaks the
framework at load. The two are different AOSP revisions, not just AOSP-plus-EPD.

**Porting the EPD API into our libgui: viable, and the recommended route.** It is
a self-contained addition -- one class, two `Surface` methods, one `Transaction`
method, two `BufferData` parcel fields; about 25 symbols. We would own both ends
(libgui and SF), so the only external contract is `hwc_epdc_llist` toward the
vendor composer, plus whatever call SF makes to hand it over. It stays
redistributable, because it is our code implementing a known interface rather
than shipping Onyx binaries.

## `hwc_epdc_llist` -- RECOVERED

From `EpdcWrapper::addEpdc(int,int,int,int,int)` at `libgui.so+0xa2e80`:

```
stp  w1, w2, [x20]          fields at +0, +4
stp  w3, w4, [x20, #0x8]    fields at +8, +12
str  w5, [x20, #0x10]       field  at +16
add  x22, x20, #0x14        element stride 0x14
mov  w8,  #0x14             stride again, in the realloc path
```

Five contiguous `int32`, 20 bytes, stored in argument order. `EpdcWrapper::dump()`
names them -- it logs `f0, f1, f2-f0, f3-f1, f4` against

```
tag: "EpdcWrapper"
fmt: "=====epdc wrapper  %d %d %d %d mode: %d"
```

so fields 0..3 are a rect in left/top/right/bottom form (the subtractions yield
width and height) and field 4 is the waveform mode:

```c
struct hwc_epdc_llist {   /* 20 bytes */
    int32_t left;         /* +0  */
    int32_t top;          /* +4  */
    int32_t right;        /* +8  */
    int32_t bottom;       /* +12 */
    int32_t mode;         /* +16  waveform mode; see the mode table in 03-ebc-api.md */
};
```

That is consistent with everything else: `mergeByMode()` coalesces rects sharing
a mode, and `docs/03-ebc-api.md` already established that mode 2 is what the
vendor stack uses for ordinary composition.

## The SF -> composer handoff: QtiLayerCommand (CONFIRMED)

**The per-frame-metadata-blob theory below was WRONG and is kept only as a record
of a disproved hypothesis.** Onyx's SF contains no reference to
`setLayerPerFrameMetadataBlobs` at all -- a direct symbol check disproves it.

What their SF actually imports:

```
aidl::vendor::qti::hardware::display::composer3::IQtiComposer3Client
aidl::vendor::qti::hardware::display::config::IDisplayConfig
```

and `vendor.qti.hardware.display.composer3-V1-ndk.so` exposes exactly two calls:

```
qtiExecuteCommands(vector<QtiDisplayCommand>, ...)
qtiTryDrawMethod(long, QtiDrawMethod)
```

with the types `QtiDisplayCommand` and `QtiLayerCommand` -- QTI's supersets of
composer3's standard `DisplayCommand`/`LayerCommand`. So the EPD list travels as
a field of `QtiLayerCommand` through `qtiExecuteCommands`, i.e. the QTI extension
of the normal composer command stream, not a metadata blob and not `/dev/ebc`.

Their SF's own EPD machinery is visible in its strings:

```
EpdcManager   HWEpdcManager   SWEpdcManager   EpdcSchemaManager
### sf epdc region received: %d %d %d %d mode: %d
### add full screen epdc, mVisibleRegionsDirty %d mGeometryDirty %d
### create epdc by update entry.
### getTransformedEpdcWrapper, create full epdc %s
### warning: commit epdc in handwriting mode.
```

`HWEpdcManager` vs `SWEpdcManager` matches the kernel's
`CONFIG_FB_ONYX_SOFTWARE_EPDC=y` and the `hasHwTcon: 0` this device reports --
it takes the software path. "add full screen epdc" when
`mVisibleRegionsDirty || mGeometryDirty` shows the fallback policy: when SF
cannot compute a precise damage region, it submits one full-screen rect.

### The command structs

`QtiLayerCommand::writeToParcel` (`+0xe014`) writes, after the standard AIDL
size header:

```
AParcel_writeInt64   from [this + 0x00]
AParcel_writeInt32   from [this + 0x08]
AParcel_writeInt64   from [this + 0x10]
```

Three fields only: `int64`, `int32`, `int64`.

`QtiDisplayCommand::writeToParcel` (`+0xdd30`) writes an `int64` from
`[this + 0x00]`, then an `AParcel_writeParcelableArray` over a vector at
`[this + 0x08]` (the `QtiLayerCommand` list), then further fields including a
byte at `+0x90` and an `int64` at `+0x98`. The struct is at least 0xA0 bytes.

### Working hypothesis for the EPD carrier

No byte-array or blob field appears in `QtiLayerCommand` -- but the DRM property
we have known about since `docs/03-ebc-api.md` is called
**`EPDC_UPDATE_PARMS_ADDR`**, an *address*, paired with `EPDC_UPDATE_CNT`, a
*count*. `QtiLayerCommand`'s `(int64, int32, int64)` fits that shape exactly, and
the kernel log independently shows the EPD buffer being mapped:

```
epdc_mmap(): [virt_buf_handwrite] [system ion] vma start: 0x78270ce000, size: 0x52f000
```

So the likely chain is: SF flattens the `EpdcWrapper` into an ION buffer, passes
its handle/address and entry count in a `QtiLayerCommand`, and the composer
writes those straight into `EPDC_UPDATE_PARMS_ADDR` / `EPDC_UPDATE_CNT` on the
plane. That would also explain why our SF's commits fail: the properties stay 0,
which is exactly what `drmprops` reads on every plane.

This is **inference from field shapes**, not yet confirmed. Confirming it means
identifying which of the three fields is the address -- e.g. by disassembling the
composer around its `CommitEpdc` string, or by finding SF's construction site for
`QtiLayerCommand`. Given three earlier hypotheses on this path were wrong, treat
it accordingly.

### CORRECTION: the AIDL QtiLayerCommand is probably the wrong interface

The composer binary that contains **all** the EPD code
(`/vendor/bin/hw/vendor.qti.hardware.display.composer-service`: `CommitEpdc`,
`onyx_epdc_update_to_display`, the 20-byte stride, the 22-entry cap) exports
**no** `QtiLayerCommand` and **no** `BnQtiComposer3Client` symbols. The AIDL
composer3 service is a different binary. So the EPD data does not travel through
`QtiLayerCommand` after all, and analysing its three fields is chasing the wrong
interface.

What it almost certainly uses is the **HIDL** `IQtiComposerClient` -- which is
exactly what Onyx's SF was reaching for when it logged `mClient_3_1 is null`, and
what `vendor.qti.hardware.display.composer@3.1.so` implements. HIDL composer
clients do not expose typed per-feature methods: they serialise commands as
**opcodes into a shared FMQ** via `executeCommands_3_1`. A vendor EPD opcode
therefore leaves no symbol anywhere -- which finally explains why no library in
the whole stack exports an `epdc` symbol despite the feature obviously existing.

**The real remaining unknown is the vendor opcode number and its payload layout
in the command stream**, recoverable only by disassembling the composer's command
parser around the EPD code at `0x3d0c0`. Everything below about the AIDL command
structs is retained as analysis of a neighbouring interface, not the live path.

### Composer-side constraints (from disassembly)

The composer's EPD path lives around `0x3d0c0`-`0x3d240` (both the
`Epdc list not matched` and `CommitEpdc` string references land there). Two hard
numbers fall out:

```
mov  w27, #0x14   /  mov w24, #0x14      element stride 20
mov  x22, #-0x3333333333333334 (+0xcccd) the /20 division magic
ldr  x21, [x25, #0x48]                   entry count, read from the display object
cmp  x21, #0x16                          bounds-checked against 22
```

The stride independently confirms `hwc_epdc_llist` is 20 bytes on the *consumer*
side too, so producer and consumer agree.

**The count limit is 22.** That matches the composer's own
`onyx_epdc_update_to_display(): upd_data_cnt is more than %d!` and explains why
`EpdcWrapper::mergeByMode()` exists at all: the hardware takes at most ~22 update
rectangles per commit, so overlapping/adjacent rects sharing a waveform mode have
to be coalesced before submission or the commit is rejected. Any implementation
we write needs that merge step, not just a rect list.

This also gives a cheap first target: submit **one full-screen rect** (which is
what Onyx's SF itself falls back to when `mVisibleRegionsDirty || mGeometryDirty`)
rather than trying to reproduce their damage tracking on day one.

## DISPROVED: per-frame metadata blobs

Neither `libcomposerextn.qti.so`, `libdisplayconfig.system.qti.so` nor
`vendor.qti.hardware.display.composer@3.1.so` exports a single `epdc` symbol, and
Onyx's SF imports `EpdcWrapper` only from `libgui`. So the handoff is not a
private extension entry point.

The vendor composer binary (`/vendor/bin/hw/vendor.qti.hardware.display.composer-service`,
extracted) contains the receiving side:

```
CommitEpdc
Epdc list not matched, use item count: %d %d
onyx_epdc_update_to_display invalid %d %d %d %d
onyx_epdc_update_to_display(): upd_data_cnt is more than %d!
onyx_epdc_update_to_display(): waveform_mode  wrong
```

with no exported EPDC symbols -- they are internal. It does export
`SetLayerPerFrameMetadataBlobs`, the **standard** composer 2.3+ per-layer blob
API. That fits the rest exactly: `EpdcWrapper` is parcelable and has
`flatten`/`getFlattenedSize`, the list rides per-layer, and
`Epdc list not matched, use item count` is the composer complaining that the
number of blob entries disagrees with the number of layers.

If that is right, **no private interface is needed**: our SurfaceFlinger already
speaks `setLayerPerFrameMetadataBlobs`. What is still unknown is the
`PerFrameMetadataKey` value Onyx uses (vendor keys live above the AOSP-defined
range) and the exact blob encoding produced by `EpdcWrapper::flatten`.

### The blob encoding -- RECOVERED

`getFlattenedSize` at `libgui.so+0xa3090`:

```
ldp  x9, x8, [x0]      vector begin, end
sub  x8, x8, x9        byte length of the element vector
add  x0, x8, #0x8      + 8
```

so the blob is `count * 20 + 8` bytes. `flatten` at `+0xa30a4`:

```
ldr  w8, [x0, #0x18]   member at +0x18  (batch)
str  w8, [x1]          -> buf[0]
bl   flattenEpdcList(vector<int>&)
lsr  x8, x8, #2        number of int32 words produced
str  w8, [x19, #0x4]   -> buf[1]
add  x9, x19, #0x8     payload begins at +8
loop: str w10, [x9], #0x4     copy each word
```

giving

```
offset 0   int32  batch          (EpdcWrapper::setBatch/getBatch)
offset 4   int32  word_count
offset 8   int32  words[word_count]
```

`getFlattenedSize` fixes `word_count = count * 5`, i.e. one `hwc_epdc_llist` per
five words in `left, top, right, bottom, mode` order -- `flatten` bounds-checks
against `getFlattenedSize` before writing, so it cannot be anything larger.
(`flattenEpdcList` is 2164 bytes at `+0xa3170`, far more code than a copy, so it
likely normalises or merges rects on the way out; the *size* relation constrains
the result regardless. Worth reading before relying on ordering.)

So the whole wire format is:

```c
struct epdc_blob {          /* count*20 + 8 bytes */
    int32_t batch;
    int32_t word_count;     /* == count * 5 */
    int32_t words[];        /* {left, top, right, bottom, mode} * count */
};
```

### Still unknown

The `PerFrameMetadataKey` value. Vendor keys sit above the AOSP-defined range;
it should fall out of disassembling the composer near its `CommitEpdc` string, or
Onyx's SF where it calls `setLayerPerFrameMetadataBlobs`.

Note the blob-metadata route is **inference**, well supported but not yet
verified: `EpdcWrapper` is flattenable, the composer exports
`SetLayerPerFrameMetadataBlobs` and complains that the
`Epdc list not matched, use item count`, and no private EPDC entry point exists
in any QTI library. Two earlier conclusions on this path were wrong (`/dev/ebc`
as the update route, and the Rockchip ioctl numbering), so treat this as a strong
hypothesis until the key is confirmed and a blob round-trips.

## Recommended implementation

1. Add `EpdcWrapper` + `hwc_epdc_llist` to our `libgui` (our own code, ~25
   symbols, matching the API above).
2. Have our SurfaceFlinger attach the flattened list to the layer via
   `setLayerPerFrameMetadataBlobs` under Onyx's vendor key.
3. Feed it from the damage region SF already computes, choosing the waveform
   mode per surface.

Nothing in that ships an Onyx binary, so it stays redistributable.

## The wholesale SF swap is a dead end

Running their SF as the real compositor got further than expected and then hit a
wall worth recording so it is not retried.

Their SF **does** register once it uses *our* binder libraries. Onyx's
`libbinder.so` / `libbinder_ndk.so` speak a different `IServiceManager` AIDL
revision than our servicemanager, so every `addService` failed silently -- SF
ignores the return value -- and the only visible symptom was
`Failed to get isDeclared ...: EX_TRANSACTION_FAILED 'BAD_TYPE'`. Moving those
two libraries out of the preload directory, keeping Onyx's `libgui`/`libui`/QTI
stack, made both `SurfaceFlinger` and `SurfaceFlingerAIDL` appear.

`bootanimation` then started and the EPDC plane errors went to zero. But
`system_server` dies immediately after:

```
java.lang.NullPointerException: Attempt to get length of null array
    at android.view.SurfaceControl.getCompositionColorSpaces(SurfaceControl.java:2589)
    at com.android.server.display.DisplayManagerService.<init>(DisplayManagerService.java:660)
*** FATAL EXCEPTION IN SYSTEM PROCESS
Exit zygote because system server has terminated
```

The framework talks to SF over the wire format defined by `libgui`. Our
`system_server` uses our `libgui`; their SF uses theirs; the two disagree. Their
SF binary cannot use our `libgui` (it needs the `android::JankData` vtable ours
does not export), and our framework cannot use theirs (215 missing symbols). The
mismatch is structural, not a missing declaration.

## Live test: the init sequence alone does NOT fix the commits

`scripts/../src/ebcinit.c` replays exactly the four startup ioctls, in Onyx's
order, with zeroed arguments, against a device running **our** SurfaceFlinger.
All four return `rc=0` and the device stays up. `0x7021` writes back `1017` --
byte-identical to what Onyx's SF received -- so the replay is faithful, not a
degraded imitation.

```
EPDC plane errors before replay : 363
EPDC plane errors after replay  : 363     (the ioctls themselves are harmless)
after forcing composition       : 381     (still climbing, same rate)
```

**Conclusion: the per-frame update parameters are required.** There is no init
handshake that puts the driver into a self-sufficient mode. This rules out the
cheap fix and leaves the `QtiLayerCommand` path as the only route -- which is
worth knowing before writing any SurfaceFlinger code.

It also means the four ioctls are safe to call and safe to ignore: they are
configuration, and configuration is not what is missing.

## /dev/ebc's userspace push path is NOT usable -- three attempts, three hangs

Upstream Rockchip's designed flow is `EBC_GET_BUFFER` -> mmap -> draw ->
`EBC_SEND_BUFFER` (docs/13). `src/ebcpush.c` implements exactly that, in stages.
It never gets past the first call:

| attempt | precondition | result |
|---|---|---|
| `ebctool refresh --go` | everything running | hang |
| `ebcprobe 1` | surfaceflinger stopped, composer RUNNING | hang |
| `ebcpush 1` | **surfaceflinger AND composer both stopped** | hang |

The third is the one that matters. `init.svc.surfaceflinger=stopped`,
`init.svc.vendor.qti.hardware.display.composer=stopped`, zero matching
processes -- and `EBC_GET_BUFFER` still blocks forever.

**So the free-buffer queue is not held by userspace.** Stopping every process
that touches the display changes nothing. The wait is on something internal to
the driver: a queue that is never primed, or one that only fills once the
kernel's EPD pipeline has been started through a path we have not triggered.
The `mdss_fb_epdc` / `epdc_refresh_waveform_task` / `commit_epdc` kernel threads
seen sitting in `D` state are plausibly the other end of it.

Nothing is logged during the hang -- `dmesg` captured with `sync` every second
shows the last EPD line ~2 s BEFORE the call and nothing after. A silent
`wait_event`, exactly as the upstream design implies.

Do not attempt a fourth variation. The composer path is the only way in.

### Also seen: a CRTC-level EPDC commit path

Alongside the plane-level `__sde_plane_atomic_update_epdc`, the kernel has

```
[drm:sde_crtc_prepare_commit_epdc:2320] plane[80[plane-1] plane->state != old_planestate!
sde_crtc_complete_commit_epdc(): crtc[...] is not is_dummy, dont release fence.
```

so the EPD commit is handled at both plane and CRTC level, and the CRTC half
deals with fences. Worth knowing when implementing the composer-side path.

## Why their SF does not finish starting

```
DisplayConfig AIDL is not present
Failed to get isDeclared for android.hardware.graphics.composer3.IComposer/default: BAD_TYPE
QtiSurfaceFlingerExtension: mClient_3_1 is null
```

Our VINTF manifest declares neither `vendor.qti.hardware.display.config` nor
composer3, so their SF runs half-initialised and never publishes. Adding those
declarations plus the ~10 QTI display libs as system prebuilts is mechanical
(the full 130-lib closure is already extracted under `firmware/stock-extract/`);
whether it then completes is unknown, and it would ship proprietary binaries.

## Reproducing

```sh
adb push out/libebctrace.so /data/local/tmp/onyxsf/
adb shell 'setprop ctl.stop surfaceflinger'
adb shell 'cd /data/local/tmp/onyxsf && \
    LD_PRELOAD=/data/local/tmp/onyxsf/libebctrace.so \
    LD_LIBRARY_PATH=/data/local/tmp/onyxsf/lib64 timeout 30 ./surfaceflinger'
adb pull /data/local/tmp/ebc_trace.log
```

Onyx's SF also needs `vendor.display.use_smooth_motion=0` and
`debug.sf.prime_shader_cache.*=0`, or it SIGSEGVs in `qtiCreateSmomoInstance`
and in Skia's shadow-layer priming respectively.

---

# 2026-07-31: the actual gate, found by disassembly

Two conclusions recorded earlier in this file and in the session are **wrong**.
They are corrected here rather than deleted, because the reasoning that produced
them was the expensive part.

## Correction 1: the Fairphone 4 ABL was never breaking the display

The runtime `/proc/cmdline` contains

```
msm_drm.dsi_display0=qcom,mdss_dsi_rm69299_visionox_amoled_cmd:
```

injected by the FP4 ABL we flashed to unlock the bootloader, and Onyx's DTBO
does contain an `rm69299 ... visionox dummy panel` node. That looked damning.
It is a coincidence.

`dsi_display0` selects the panel for the display node whose `label` is
`"primary"`, and in Onyx's DTBO that is `qcom,dsi-display-dummy`, whose
`qcom,dsi-default-panel` is *already* `&dsi_rm69299_visionox_amoled_cmd`. The
FP4 value therefore selects the panel that node would have used anyway. The
real e-ink panel hangs off `qcom,dsi-display-secondary` (label `"secondary"`),
which is untouched by `dsi_display0`. The kernel confirms it:

```
dsi_display_dev_probe(): boot_disp[qcom,mdss_dsi_epdc_cmd] for dsi display index[1]
dsi_display_dev_probe(): boot_disp[qcom,mdss_dsi_rm69299_visionox_amoled_cmd] for dsi display index[0]
[drm:dsi_display_bind] Successfully bind display panel 'qcom,mdss_dsi_epdc_cmd'
sde_encoder_get_hw_resources(): epdc panle is SECONDARY dsi, so force set
    hw_res.display_type SDE_CONNECTOR_PRIMARY for sde rm req.
```

Onyx patched SDE to force the secondary DSI to be treated as the primary
connector. The binding was correct the entire time. `scripts/patch-boot-cmdline.py`
and `out/images/boot-extra.img` were built to fix a non-problem; the cmdline
override is harmless but pointless, and `boot_b.img` can be restored.

Also wrong in passing: the connector mapping. `card0-DSI-1` at 1648x824 is the
**dummy**'s configured timing; the epdc panel node's own DSI timing is 457x835
(0x1c9 x 0x343), because the DSI link feeds a Lattice FPGA TCON that drives the
1648x824 EPD, so the link timing need not match the visible panel.

## Correction 2: the commit path was never "missing"

Zero `commit[%d] upd_data_cnt[...]` lines appear in a whole boot, which read as
"the commit never runs". Disassembly says otherwise -- that log is gated:

```
e4e7d4:  add   w2, w9, #1
e4e7d8:  str   w2, [x8, #0xff4]        ; commit counter++   (UNCONDITIONAL)
e4e7dc:  tbnz  w10, #4, 0xe4e9ec       ; only LOGS if debug bit 4 set
e4e7f8:  bl    0x81f60                 ; the submit itself  (UNCONDITIONAL)
```

`w10` is `mdp_buffer_debug_level` (resolved via `/proc/kallsyms` after
`kptr_restrict=0`; `_text` is file offset 0, so file offset + `_text` = VA).
The same byte gates the per-plane success log at `0xe4e944`. There is no
debugfs (`CONFIG_DEBUG_FS` is off) and no module param for it, so those logs
are unreachable without a kernel memory write. **Absence of those lines carries
no information.**

## What actually gates the panel

`__sde_plane_atomic_update_epdc` (file `0xe4e6d8` = `sde_plane_atomic_update`)
rejects any plane that is not exactly panel-sized:

```
e4e770:  ldp   w21, w20, [x22, #0x28]  ; fb width, height
e4e788:  ldr   w8, [x27, #0x1360]      ; panel width
e4e78c:  cmp   w21, w8
e4e790:  b.ne  <error>
e4e794:  ldr   w8, [x27, #0x1364]      ; panel height
e4e798:  cmp   w20, w8
e4e79c:  b.ne  <error>
```

`stride` and `fb_width` are logged but never compared, so the 1664-vs-1648
gralloc padding is irrelevant. Every rejection we ever logged was a partial
plane -- `height[785..823]` (animation frames) or `width[53]` (the nav bar).
Under client composition the whole screen collapses to one full-panel plane and
the check passes.

Past the check, the submit is:

```
e4e7e0:  ldr   w5, [x25, #0x91c]       ; upd_data_cnt
e4e7e4:  add   x4, x25, #0x7dc         ; upd_data[] -- the update rectangles
e4e7f8:  bl    0x81f60                 ; submit(vaddr, w, h, stride, upd_data, cnt)
```

where `x25 = [plane + 0x4d8]`. **With `cnt == 0` there are no regions to
refresh, so the panel is driven with nothing.** That is the blank screen.

## Where the rectangles come from

Onyx added two DRM **plane properties**:

```
0x2f6684b  EPDC_UPDATE_CNT
0x2f6685b  EPDC_UPDATE_PARMS_ADDR
0x2f66e9b  drm_epdc_update
```

handled by `_sde_plane_set_epdc_upd` / `_sde_plane_set_epdc_upd_cnt`:

```
'%s(): user space  epdc_update_parms_addr[0x%llx]'
'%s(): failed to copy epdc_update_parms_addr [0x%...'
'%s(): prop upd_data_cnt[%d][0] [%d %d %d %d] waveform_mode[%d]
       update_mode[%d] update_marker[%d] ...'
'%s(): upd_data_cnt[%lld]!'
```

`EPDC_UPDATE_PARMS_ADDR` is a **userspace pointer**, `copy_from_user`'d by the
kernel, to an array of update-parameter structs; `EPDC_UPDATE_CNT` is how many.
Both are set per atomic commit by whoever owns DRM master -- SurfaceFlinger.

So the chain is: app damage -> `Surface::transferEpdc` -> `BufferData` -> SF ->
these two plane properties -> `upd_data[]`/`cnt` -> submit. Our framework has no
`epdc` symbols anywhere in libgui, so the chain is cut at the first link and
`cnt` is structurally always 0.

## What this means for the port

The EPD hardware, waveform stack and driver are fully functional under our
build. Confirmed this session:

* the UI composites correctly -- `screencap` returns a normal /e/OS Settings
  screen at 824x1648 (the earlier all-black capture was taken with the display
  **asleep**; `dumpsys display` showed `Display State=OFF`, `mWakefulness=Asleep`)
* full-panel planes pass the size check and reach the submit
* `SET_EBC_SEND_UPDATE` from `ebcrefresh` is accepted (`rc=0`) and drives the
  real waveform pipeline -- each call produces `o_g_w(): vmalloc wf_lut[n]`
  followed by `waveform_clean_work_handler()`
* the waveform loaded at boot: `320_R118_AFE001_ES133TT3P1_TC`

The only missing piece is the update-rectangle plumbing. Implementing it means
setting `EPDC_UPDATE_PARMS_ADDR` + `EPDC_UPDATE_CNT` on the plane in the DRM
atomic commit -- which for a full-screen refresh needs exactly one rectangle
covering the panel, not the full app-damage plumbing. That is a far smaller job
than reproducing Onyx's SF, and it belongs in the composer/DRM backend rather
than in libgui.

Still unknown: the layout of the update-parameter struct that
`EPDC_UPDATE_PARMS_ADDR` points at. The printk shows the field order
(`[x y w h] waveform_mode, update_mode, update_marker, flag, temp`), which
matches the 40-byte `ebc_send_update` struct `ebcrefresh` already uses
successfully -- likely the same struct.

## Measured: the EPD buffer is empty, under both SurfaceFlingers

`src/ebcfb.c` (build: `zig cc -target aarch64-linux-musl -static`) mmaps
`/dev/ebc` read-only and histograms it. `EBC_GET_BUFFER_INFO` (0x7003) returns:

```
[2] 824  [3] 1648  [4] 824  [5] 1648  [6] 1648  [7] 824
```

so 1648x824, 8 bits per pixel, 1357952 bytes. Result in both configurations:

```
distinct byte values: 1
most common: 0xff  1359872/1359872 (100.0%)
verdict: UNIFORM -- no image content in this buffer
```

* under **Onyx's SF**: expected -- it issues zero DRM commits
  (`dmesg | grep -c update_epdc` == 0 for a whole boot)
* under **our SF**: 155 logged plane rejections, and the full-panel planes pass
  the size check and reach the submit -- **and the buffer is still uniform white**

That is the proof. Passing the size check is not sufficient: the submit
`0x81f60(vaddr, w, h, stride, upd_data, cnt)` copies *per update rectangle*, so
with `cnt == 0` it copies nothing. The panel then faithfully displays an empty
buffer, which is why `ebcrefresh` visibly drives the waveform yet shows nothing.

Chain, fully resolved:

```
app damage -> Onyx libgui (hwc_epdc_llist) -> Onyx SF (EpdcWrapper::addEpdcList)
  -> composer HAL (CommitEpdc / onyx_epdc_update_to_display)
  -> libsdedrm  DRMPlane::SetEpdcUpdParmsAddr / SetEpdcUpdCnt
  -> DRM plane props EPDC_UPDATE_PARMS_ADDR / EPDC_UPDATE_CNT
  -> kernel copy_from_user(pstate+0x7dc, ptr, 320) ; cnt -> pstate+0x91c
  -> __sde_plane_atomic_update_epdc submit
```

The **vendor half is intact and already on the device**:

```
/vendor/lib64/libsdedrm.so
    _ZN7sde_drm8DRMPlane19SetEpdcUpdParmsAddrEP17_drmModeAtomicReqm
    _ZN7sde_drm8DRMPlane13SetEpdcUpdCntEP17_drmModeAtomicReqj
/vendor/bin/hw/vendor.qti.hardware.display.composer-service
    CommitEpdc, onyx_epdc_update_to_display
```

`hwc_epdc_llist` appears **only** in `/system/lib64/onyxsf/libgui.so` and
`surfaceflinger_onyx` -- never in any vendor library. So the missing link is
entirely on the system side, between SF and the composer.

Onyx's SF is not a shortcut around it: re-tested with the display held awake
(the previous test was invalid -- display asleep), it enables the display and
holds 90 layers but issues **zero** DRM commits, while logging continuously:

```
E SurfaceFlinger: ERROR(Unknown error 2147483640, -2147483640).
                  Failed to call parcel s.read(data)
```

Ours composites; theirs does not. Ours is the one to fix.

---

# RESOLVED: the panel works

`src/epdcshim.c`, LD_PRELOAD'd into the composer, supplies the missing update
rectangles. **The display works.** Setup wizard completed on-device, launcher
renders, UI is usable.

## What it does

Interposes `drmModeAtomicAddProperty` / `drmModeAtomicCommit`. This is possible
because `libsdedrm.so` -- which owns `DRMPlane::SetEpdcUpdParmsAddr` /
`SetEpdcUpdCnt` -- has `libdrm.so` as a NEEDED entry, so those calls resolve
through the global symbol table where a preloaded definition wins.

`AddProperty` is hooked *only to record* which object ids the composer itself
put in the request; at commit time we add the two epdc properties to exactly
those objects. Adding a property for an object that is not otherwise in the
request would pull it in and can fail an otherwise valid commit, so we never
guess a plane id. Objects that are not planes, or planes without the epdc
properties, are cached as negative and skipped forever after.

Confirmed at runtime:

```
epdcshim: plane 86: EPDC_UPDATE_PARMS_ADDR=78 EPDC_UPDATE_CNT=79
epdcshim: plane 96: EPDC_UPDATE_PARMS_ADDR=78 EPDC_UPDATE_CNT=79
```

and the kernel's wakeup sources gained `epdc_update` / `epdc_power`, with plane
commits going from 155 to 1228 per session.

## Tunables (live, re-read every 30 commits -- no restart)

```sh
setprop persist.epdcshim.enable   1      # master switch
setprop persist.epdcshim.wf       2      # waveform_mode, 0..7 (mode_num=8)
setprop persist.epdcshim.upd      0      # update_mode
setprop persist.epdcshim.flag     0x21000
setprop persist.epdcshim.interval 0      # ms floor between refreshes
```

**`upd 1` flashes the whole panel on every change; `upd 0` does not.** That one
value is the difference between unusable and pleasant. `wf 2` is GC16, the
full-flash mode Onyx itself uses for whole-screen refreshes.

`DRM_MODE_ATOMIC_TEST_ONLY` commits are skipped -- injecting there would drive
the panel for every validation pass the composer makes.

## Install / revert

```sh
adb push out/libepdcshim.so /vendor/lib64/libepdcshim.so
# add to /vendor/etc/init/vendor.qti.hardware.display.composer-service.rc:
#     setenv LD_PRELOAD /vendor/lib64/libepdcshim.so
```

Revert = delete that one line and reboot. Pristine rc is in the repo history;
nothing else in vendor is modified.

## Correction: ebcfb was reading the wrong buffer

The earlier "EPD buffer is 100% 0xff" measurement is **not** evidence of what it
claimed. Boot logs show `epdc_mmap(): [virt_buf_handwrite] ... size: 0x52f000`,
so `mmap(fd, 0)` lands on the *handwriting overlay* buffer, which is legitimately
blank. The conclusion it was used to support happened to be right, but it was
supported by the disassembly, not by that measurement. `ebcfb` needs an offset
argument before its output means anything.

## Remaining, in the order agreed

1. **Stock composer** -- if the shim ever proves too fragile, try the composer
   from the stock image instead of patching around ours.
2. **Option B, kernel patch** -- make `__sde_plane_atomic_update_epdc`
   substitute a full-panel rectangle when `cnt == 0`. Works for any userspace
   including a plain GSI, needs a trampoline (no spare instruction space at the
   patch site), and a mistake means no boot (EDL recovery).
3. **Option C, do it properly in SF** -- real damage regions plumbed to the
   composer, giving partial updates and per-region waveform modes instead of a
   full-screen refresh every commit. The correct end state. Blocked on reverse
   engineering the SF->composer transport: `hwc_epdc_llist` appears in no vendor
   library, only in Onyx's `libgui.so` and their SF.

Cosmetic, noticed once the panel came up: the launcher renders shifted left with
black at the right edge, and dark theme is the default (bad on e-ink -- `cmd
uimode night no`).

## Refresh policy, and why partial updates are not reachable from the shim

Enumerating every DRM plane property (dumped by the shim itself) settles the
question of damage:

```
type FB_ID IN_FENCE_FD CRTC_ID CRTC_X CRTC_Y CRTC_W CRTC_H
SRC_X SRC_Y SRC_W SRC_H zpos alpha input_fence excl_rect_v1 rotation
blend_op src_config color_fill prefill_size prefill_time capabilities
inverse_pma csc_dma_v1 SDE_DGM_1D_LUT_IGC_V5 SDE_DGM_1D_LUT_GC_V5
fb_translation_mode EPDC_UPDATE_PARMS_ADDR EPDC_UPDATE_CNT
```

**There is no `FB_DAMAGE_CLIPS`.** And client composition -- which this panel
*requires*, see below -- collapses everything into a single full-screen plane
whose `CRTC_W/H` is always the whole display. So the shim has no way to know
what changed, and every update is necessarily full-panel. Real partial updates
need damage from SurfaceFlinger.

### Client composition is mandatory, not a preference

`__sde_plane_atomic_update_epdc` accepts only planes exactly the size of the
panel. Any layer the composer promotes to its own hardware plane is therefore
dropped and never reaches the e-ink buffer -- drawn, clickable, invisible:

```
width[53]  height[824]   <- navigation bar
width[90]  height[824]   <- status bar
width[38]  height[824]   <- gesture handle
```

This is why the nav bar could be tapped but not seen. `service call
SurfaceFlinger 1008 i32 1` (`mDebugDisableHWC`) merges everything into one
full-panel plane and they all appear. It resets on **every** SF restart, so
`system/etc/init/epdc-clientcomp.rc` re-applies it on
`property:init.svc.surfaceflinger=running`. The durable fix is to default it in
our SF source, since we build it.

Note also: the nav bar does not exist at all unless `qemu.hw.mainkeys=0` is set
before WindowManager starts (`config_showNavigationBar` is false for this
device). That needs to move into a build.prop to survive a reboot.

### What the policy does instead

Since the *what* cannot be narrowed, the shim controls the *when* and the *how*,
which is where e-readers get their feel (Kobo/KOReader, PineNote):

| property | effect |
|---|---|
| `persist.epdcshim.interval` | ms floor between updates. Was firing on every atomic commit -- up to 60 full-panel repaints a second, which was most of the slowness. |
| `persist.epdcshim.fullevery` | one full-flash GC16 clean every N updates, to clear the residue partial waveforms leave |
| `persist.epdcshim.fastwf` / `fastms` | while frames arrive faster than `fastms` the screen is moving, so quality is wasted -- use a cheaper waveform |
| `persist.epdcshim.skipsame` | skip commits presenting the same `FB_ID`s as the last one acted on |

`skipsame` is the one that matters for idle. SurfaceFlinger commits even when
nothing changes, and each of those was costing a full-panel repaint. Measured
by counting the driver's own `waveform_clean_work_handler` per update:

| screen | idle updates / 10 s |
|---|---|
| Settings (static) | **0** |
| /e/OS Bliss launcher | 10-13 |

Zero on a static screen, so the suppression is correct. The launcher genuinely
repaints ~1 Hz on its own -- confirmed by diffing two screencaps two seconds
apart, which shows changed pixels in two bands (y 0..49 and y 300..399). It is
not the status bar clock: `clock_seconds` is unset and forcing it to 0 changes
nothing. That is a launcher-level behaviour the shim cannot distinguish from a
real content change; a different launcher would avoid it.

### The shortcut to real partial updates

Rather than reverse engineering Onyx's private SF->composer transport (option C
proper), our own SurfaceFlinger could publish its damage rectangles into a small
shared-memory region that the shim reads and turns into up to 8 update rects --
which is exactly the kernel's array size. That skips the unknown transport
entirely and needs only an SF rebuild.

## Writer side: publishing damage from SurfaceFlinger

Contract: `src/epdc_damage.h` (copy into the AOSP tree, or add `src/` to the
module's include path). Reader is implemented in `src/epdcshim.c`; it falls back
to one full-panel rectangle whenever the mapping is missing, so a partial or
absent writer is never worse than today.

**Where.** `frameworks/native/services/surfaceflinger/CompositionEngine/src/Output.cpp`.
The dirty region is in hand at the client-composition call site:

```cpp
1247:  if (const auto dirtyRegion = getDirtyRegion(); !dirtyRegion.isEmpty()) {
1252:      static_cast<void>(composeSurfaces(dirtyRegion, buffer, bufferFence));
```

Publish there. Do **not** publish inside `composeSurfaces` itself: two of its
three call sites (`:1214`, `:1290`) pass `Region::INVALID_REGION`.

**Coordinates.** `getDirtyRegion()` is layer-stack space (824x1648 portrait).
The kernel blits a plane in output space (1648x824 landscape) -- the panel is
installed rotated. So transform before publishing:

```cpp
const Region out = outputState.transform.transform(dirtyRegion);
```

Publishing layer-stack coordinates will refresh the wrong part of the screen,
and because the aspect is swapped it will look plausible but be subtly offset --
worth checking first with a single obvious rectangle.

**Merging.** The kernel takes at most `EPDC_DAMAGE_MAX` (8). `Region` routinely
holds more. Cheapest correct policy: use the rectangles when there are <= 8,
otherwise fall back to `out.getBounds()`. Merging by nearest-neighbour area cost
is better but is a refinement, not a correctness issue -- an over-large
rectangle only costs refresh time, a missing one leaves stale pixels.

**Protocol.** Single writer, single reader, seqlock -- neither side may block
the other, both are on the frame path:

```cpp
auto* s = mDamageShm;                      // mmap'd once, MAP_SHARED
uint32_t seq = s->seq + 1;                 // odd: write in progress
__atomic_store_n(&s->seq, seq, __ATOMIC_RELEASE);
s->count = n;
s->full  = fullRefreshWanted ? 1 : 0;
for (...) s->rect[i] = {l, t, r, b};
__atomic_store_n(&s->seq, seq + 1, __ATOMIC_RELEASE);   // even: stable
```

Set `magic`/`version` once at creation, *after* `ftruncate`, and only then let
the reader see a valid header.

**The file.** `/dev/epdc/damage`. `/dev` is root-owned, so init creates the
directory (already added to `system/etc/init/epdc-clientcomp.rc`):

```
on post-fs-data
    mkdir /dev/epdc 0770 system system
```

SF opens `O_RDWR|O_CREAT`, `ftruncate(4096)`, `mmap(MAP_SHARED)`, once.

**`full`.** Set it when the whole panel needs a clean pass regardless of damage
-- orientation change, first frame after resume, geometry change. The shim also
forces one every `persist.epdcshim.fullevery` updates on its own.

**Checking it works.** The shim logs `attached to SurfaceFlinger damage at
/dev/epdc/damage` once on success. After that, a keystroke should produce a
small rectangle rather than a whole-panel repaint; compare
`waveform_clean_work_handler` rates and watch which part of the panel flashes.
