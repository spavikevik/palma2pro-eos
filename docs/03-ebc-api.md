# The EBC display API on Palma 2 Pro

Derived statically from `boot_a` (stock kernel, uncompressed ARM64 `Image`) and
`/system/bin/surfaceflinger`, then **confirmed on the live device** with
`ebctool` once root was available.

## Summary

| | |
|---|---|
| Device node | `/dev/ebc` |
| Driver version string | `ONYX_EBC_DRIVER_VERSION_2.00` |
| Lineage | Rockchip EBC ("E-Book Controller"), ported by Onyx onto Qualcomm `lito` |
| Command encoding | plain integers from base `0x7000` — **not** `_IOR`/`_IOW` encoded |
| Driver location | built into the kernel, not a `.ko` |
| Userspace caller | patched SurfaceFlinger (`EpdcManager` / `EpdcWrapper`) |

The Rockchip lineage is the single most useful fact: that driver is open source
and is what the PineNote uses, so struct layouts and command semantics have a
public reference implementation instead of needing blind reverse engineering.

## How the numbering was established

The kernel's ioctl handler sits around file offset `0x0057c000` in the extracted
`Image`. It was located by finding ADRP+ADD pairs that reference the driver's log
format strings — PC-relative addressing, so this works in file-offset space
without knowing the kernel's load address.

Inside the case blocks:

```
0x0057c11c  -> "%s(): GET_EBC_BUFFER!"          ... 0x0057c13c  movz w0, #0x7000
0x0057c19c  -> "%s(): SET_EBC_SEND_BUFFER!"     ... 0x0057c258  movz w0, #0x7001
```

Those literals match upstream Rockchip's `EBC_GET_BUFFER = 0x7000` and
`EBC_SEND_BUFFER = 0x7001`, which establishes both the base and that the codes
are raw integers rather than `_IO*` macros.

## Command set

Eighteen commands, from kernel strings (`firmware/analysis/ebc-commands.txt`):

```
GET_EBC_BUFFER                 SET_EBC_SEND_BUFFER
GET_EBC_BUFFER_INFO            SET_EBC_SEND_UPDATE
GET_EBC_DRIVER_SN              SET_EBC_WAIT_ALL_UPDATE_COMPLETE
GET_EBC_CAPTURE_ALL_BUFFER     SET_EBC_CLEAR_ALL_UPDATE
GET_EBC_CAPTURE_ALL_NAME       SET_EBC_FORCE_WAVEFORM
                               SET_EBC_LUT_ENABLE
                               SET_EBC_GAMMA_TAB
                               SET_EBC_UPDATE_SCHEME
                               SET_EBC_UPD_LIST_SIZE
                               SET_EBC_EXTBUF_SYNC_FB_ENABLE
                               SET_EBC_CAPTURE_ALL_START
                               SET_EBC_CAPTURE_SRART      [sic -- typo is Onyx's]
                               SET_EBC_CAPTURE_STOP
```

Confirmed numbers:

| Command | Value | Basis |
|---|---|---|
| `GET_EBC_BUFFER` | `0x7000` | literal in kernel case block; matches upstream |
| `SET_EBC_SEND_BUFFER` | `0x7001` | literal in kernel case block; matches upstream |
| `GET_EBC_DRIVER_SN` | `0x7002` | **confirmed on device** -- returns `ONYX_EBC_DRIVER_VERSION_2.00` |
| `GET_EBC_BUFFER_INFO` | `0x7003` | **confirmed on device** -- returns correct 824x1648 geometry |

**Onyx diverges from upstream Rockchip at `0x7002`.** Upstream puts
`GET_BUFFER_INFO` there; Onyx puts `GET_DRIVER_SN`, shifting everything after it
by one. Calling `0x7002` expecting a struct returns the version string instead,
which is how this was caught -- the "struct" decoded to ASCII.

### Command numbers from the ioctl jump table

The dispatch at `0x57a920` decodes as:

```
57a934:  sub  w8, w1, #0x7000      index = cmd - 0x7000   (w1 = ioctl cmd)
57a938:  cmp  w8, #0x11d           286 valid commands, 0x7000..0x711d
57a94c:  add  x9, x9, #0x398       u16 table at file offset 0x1923398
57a950:  adr  x10, 0x57a960        target = 0x57a960 + entry*4
57a95c:  br   x10
```

Decoding the table reproduces both empirically confirmed commands exactly
(`0x7002` DRIVER_SN, `0x7003` BUFFER_INFO), which validates the decode.

| Command | Number | Confidence |
|---|---|---|
| `GET_EBC_BUFFER` | `0x7000` | confirmed (disasm + table) |
| `SET_EBC_SEND_BUFFER` | `0x7001` | confirmed (disasm + table) |
| `GET_EBC_DRIVER_SN` | `0x7002` | **confirmed on device** |
| `GET_EBC_BUFFER_INFO` | `0x7003` | **confirmed on device** |
| `SET_EBC_LUT_ENABLE` | `0x7004` | table; handler adjacent to its log string |
| `SET_EBC_WAIT_ALL_UPDATE_COMPLETE` | `0x7010` | table; handler adjacent to its log string |
| `SET_EBC_SEND_UPDATE` | **unknown** | see below |

Only 47 of the 286 table entries are distinct targets, so most commands share a
handler or fall through to the epilogue at `0x57e5d4`.

### SET_EBC_SEND_UPDATE = 0x700c -- but on a *second* driver

Resolved. The kernel's virtual base is **`0xffffff8008000000`** (VA = base +
file offset), recovered by histogramming absolute pointers in the image: they
span `0xffffff8008000000`..`0xffffff800b6xxxxx` against an image size of
`0x35ec010`.

With data pointers followable, a **second ioctl handler** turned up at
`0x5b1a70`, with its own command base and jump table:

```
5b1ab4:  mov  w9, #-0x7002
5b1ab8:  add  w9, w21, w9        index = cmd - 0x7002   (w21 = cmd)
5b1abc:  cmp  w9, #0x27          40 commands: 0x7002..0x7029
5b1ac8:  add  x10, x10, #0x15c   u16 table at 0x192415c
5b1acc:  adr  x11, 0x5b1adc      target = 0x5b1adc + entry*4
```

The `copy_from_user(40)` at `0x5b23f8` sits in the case block at `0x5b23a8`,
which this table maps to **`0x700c`**.

Corroborated independently: the same table maps `0x7002` to `0x5b2960`, which is
exactly where the earlier string-reference scan found this driver's own
`GET_EBC_DRIVER_SN` site. Two methods, same answer.

### The open problem: which node?

This is **not** `/dev/ebc`. That node demonstrably uses the *other* dispatch at
`0x57a920`: on hardware, `0x7003` returned valid 824x1648 geometry, whereas in
this second table `0x7003` routes to the error path at `0x5b48e4`.

So the device has two EPD drivers and only one exposed node. `/proc/misc` lists
just `ebc` (minor 51); there is no `/dev/fb*` or `/dev/graphics`. Candidates:

- the **`compat_ioctl`** of `/dev/ebc`, reachable only from a 32-bit process.
  Testable: build `ebctool` for `arm-linux-musleabi` and call `0x700c`.
  (Weak prior -- the struct is ten `int32`s, identical under both ABIs, so a
  compat path would have little to do.)
- a second driver that registered a node we have not identified, or that did not
  probe.
- a node created on demand by an Onyx service.

**Do not send `0x700c` to `/dev/ebc`.** In the first table `0x700c` maps to
`0x57ac98`, a live handler whose function is unknown -- it is not the same
command, and firing it blind is exactly the sort of write to avoid.

### Superseded: the earlier claim this was unresolvable

Its log string is printed from `0x5b242c`, far outside the dispatch function's
body (`0x57a920`..`~0x57e620`). Nothing branches into that block from the
dispatch, and it has no direct `BL`/`B` callers anywhere, so it is reached
indirectly.

The intermediate guess of `0x7117` came from picking the greatest jump-table target at
or below the log site. **That is wrong** -- `0x57e5d4` is the function's shared
epilogue, which dozens of table entries point at. Do not use `0x7117`.

To resolve it properly, the kernel's virtual load base has to be recovered (from
kallsyms, or by matching a known data pointer), after which data references --
including `file_operations` tables and any function-pointer dispatch -- become
followable. That is the next concrete step.

Until then `ebctool` must not send updates: an unknown ioctl number on a display
driver is exactly the kind of blind write that wedges a controller.

### Earlier predicted numbering (superseded)

The kernel's case blocks appear in ascending address order, and that order
matches the four confirmed points. Extrapolating:

| Address of log string | Command | Predicted |
|---|---|---|
| `0x57c11c` | `GET_EBC_BUFFER` | `0x7000` confirmed |
| `0x57c19c` | `SET_EBC_SEND_BUFFER` | `0x7001` confirmed |
| `0x57c33c` | `GET_EBC_DRIVER_SN` | `0x7002` confirmed |
| `0x57c3b4` | `GET_EBC_BUFFER_INFO` | `0x7003` confirmed |
| `0x57c46c` | `SET_EBC_LUT_ENABLE` | `0x7004` unverified |
| `0x57c51c` | `SET_EBC_WAIT_ALL_UPDATE_COMPLETE` | `0x7005` unverified |

Only six of the eighteen commands had locatable string references, so the
sequence is probably not contiguous. **Do not probe the unverified ones blindly**
-- several are `SET_*`, and handing them a buffer pointer as an integer argument
could disable the LUT or push garbage into the controller.

### Live `GET_EBC_BUFFER_INFO` output

```
0000: ff ff ff ff  00 00 00 00  38 03 00 00  70 06 00 00
0010: 38 03 00 00  70 06 00 00  70 06 00 00  38 03 00 00
0020: 00 00 00 00  ...

word0 = -1     offset (no buffer currently acquired)
word1 =  0     epd_mode
word2 =  824   0x338
word3 =  1648  0x670
word4 =  824
word5 =  1648
word6 =  1648
word7 =  824
word8 =  0
```

824 x 1648 is this panel's true resolution, so the command and the general shape
are right. Exact field names beyond `offset`/`epd_mode` are still unsettled --
the three repeating 824/1648 pairs suggest width/height plus virtual dimensions
plus a window rect, but which is which is not yet pinned down. The upstream
ordering (`height` before `width`) does not obviously fit.

## Update submission — struct recovered

**The argument layout is now known**, recovered from the stock kernel's handler
rather than guessed. `scripts/rawelf.py` wraps a byte range of the raw kernel
`Image` in a minimal ELF so `llvm-objdump` will disassemble it (llvm-objdump
refuses raw input and misdetects a bare ARM64 Image as COFF).

The handler at `0x5b23f8`:

```
5b23fc:  mov  w2, #0x28          size = 40 bytes
5b2400:  add  x0, sp, #0x10      struct base
5b2418:  bl   copy_from_user
5b2420:  ldr  w3, [sp, #0x30]    struct +0x20
5b2424:  ldr  w2, [sp, #0x28]    struct +0x18
5b242c:  printk "SET_EBC_SEND_UPDATE -- update_marker[%d] flags[0x%x]"
```

`w2`/`w3` are printk's 3rd/4th arguments, naming two fields outright. So:

| Offset | Field | Evidence |
|---|---|---|
| `+0x00`..`+0x0c` | `rect[4]` | `ldp w4,w3,[sp,#0x10]` + `ldp w5,w6,[sp,#0x18]` feed `rect[%d %d %d %d]` |
| `+0x10` | `waveform_mode` | compared against 1, 2, 3 and `>3` — a small enum |
| `+0x14` | `update_mode` | compared against 1 |
| `+0x18` | `update_marker` | printk arg; handwriting path adds 60000 and stores back |
| `+0x1c` | unknown | not read in the traced path |
| `+0x20` | `flags` | bit-tested at 16, 17, 18 |
| `+0x24` | unknown | probably `temp` — the commit log ends `temp[%d]` |

Total 40 bytes, matching `mov w2, #0x28` exactly. Declared as
`struct ebc_send_update` in `src/ebctool.c` with a `_Static_assert` on the size.

### Still not fired

Knowing the struct is not the same as being able to submit an update. A real
submission needs the buffer flow first: `GET_EBC_BUFFER` to acquire a buffer,
`mmap` the region, draw into it, then `SET_EBC_SEND_UPDATE`. That is the next
increment, and it is the first thing here that writes to the display.

Two fields remain unidentified (`+0x1c`, `+0x24`), and the waveform enum's
numbering is not yet mapped to the `INIT`/`DU`/`A2`/`GC16`/`REGAL` names.

## Original notes on the update path

The update path is described by this kernel log format string:

```
commit[%d] upd_data_cnt[%d][0] [%d %d %d %d] waveform_mode[%d] update_mode[%d]
    update_marker[%d] flag[%d] temp[%d]
```

and this one from the UI path:

```
[UI] update_marker[%d] waveform[%d] update_mode[%d] flags[0x%x]
```

So a submission carries: a rectangle, a waveform mode, an update mode, a marker
for completion tracking, flags, and a temperature — and `upd_data_cnt` implies an
**array** of update records per call, not a single one.

That is enough to know the shape but **not** enough to pin the exact struct: field
order, widths, padding and the list header are all unconfirmed. Submitting a
malformed update can wedge the display controller, so `ebctool` implements only
read-only commands until `info` output confirms the layout empirically.

Waveform modes present in the kernel: `INIT`, `DU`, `A2`, `GC16`, `REGAL`/`REAGL`.
These are the standard E-ink waveforms — `INIT` full clear, `DU` fast 2-level,
`A2` fastest/lowest quality, `GC16` full 16-level greyscale, `REGAL` the
ghosting-reduction variant.

## Related sysfs

```
/sys/onyx_misc/cytp_lo_filter        touch low-pass filter (referenced by SurfaceFlinger)
dithering_set_debounce_delta
dithering_set_debounce_threshold
epdc_display_timeout
epdc_power_timeout
```

Full attribute list in `firmware/analysis/kernel-epd-attrs.txt`.

## Running the tool

```
scripts/build-ebctool.sh              # zig preferred; NDK also works
adb push out/ebctool /data/local/tmp/
adb shell su -c '/data/local/tmp/ebctool info'
adb shell su -c '/data/local/tmp/ebctool ident'
```

Both need **root** (Magisk), which needs an unlocked bootloader. Done — see
`docs/02-unlock.md`.

`info` takes an optional command number so alternatives can be tried without a
rebuild: `ebctool info 0x7003`.

`info` prints the parsed `ebc_buf_info` *and* a raw word dump, so a struct-layout
mismatch shows up as obviously-wrong geometry rather than being silently accepted.
Expected resolution for cross-checking: 824 x 1648 (6.13", per the panel spec).

## SELinux

`/dev/ebc` will have a vendor SELinux label. A GSI's SurfaceFlinger runs in the
stock `surfaceflinger` domain, which almost certainly lacks access, so the eventual
refresh controller needs either a policy addition or to run in a permissive
context. Check on device with:

```
ls -lZ /dev/ebc
dmesg | grep avc | tail
```

---

## The epdc node: it is DRM

Resolved from `dmesg` after a failed experiment:

```
mdss_mdp_epdc_open:  caller[msm_drm_open+0x48/0x80] task[composer-servic]
epdc_open(): OK!
epdc_mmap(): [virt_buf_handwrite] [system ion] vma start: 0x6e307b7000, size: 0x52f000
```

`epdc` is not a misc device and not an fbdev node -- despite `onyx_epdc_fb_*`
symbols and char major 29 being registered, nothing appears under
`/sys/class/graphics` even as root. It is reached through **`msm_drm_open`**,
i.e. it hangs off the DRM device:

```
/dev/dri/card0      crw-rw-rw-  root graphics  u:object_r:graphics_device:s0  226,0
/dev/dri/renderD128 crw-rw-rw-  root graphics                                 226,128
```

SurfaceFlinger (`composer-servic`) opens it as a DRM client; buffers come from
ION (`[virt_buf_handwrite] [system ion]`, 0x52f000 bytes).

So the two layers are:

| Layer | Node | Commands |
|---|---|---|
| `ebc` | `/dev/ebc` (misc 51) | base `0x7000`, 286-entry table, buffer management |
| `epdc` | `/dev/dri/card0` (DRM) | base `0x7002`, 40-entry table, `SET_EBC_SEND_UPDATE = 0x700c` |

`/dev/dri/card0` is world-accessible, so the epdc path may not even need root --
though it will need the SELinux `graphics_device` context.

## Failed experiment: `ebctool refresh` rebooted the device

The first attempt at `GET_EBC_BUFFER` -> `mmap` -> `SET_EBC_SEND_BUFFER` on
`/dev/ebc` **took the system down**; uptime after reconnect was 81 seconds.
No data loss, bootloader still unlocked, display fine afterwards.

Two things went wrong:

1. **The risk was understated.** It was described beforehand as "worst case a
   display glitch cleared by a reboot". Poking a display driver's buffer
   acquisition path blind can hang or panic the kernel, and did.
2. **No diagnostics survived.** `printf` to a pipe is block-buffered, so every
   line was lost when the process died -- we cannot even tell which call hung.
   `ebctool` now calls `setvbuf(..., _IONBF, ...)` on stdout and stderr, and
   announces `GET_EBC_BUFFER` before making the call, since that one blocks
   while waiting for a free buffer.

Most likely cause: `GET_EBC_BUFFER` blocks until a buffer is free, and
SurfaceFlinger holds them all -- so a second client asking for one while
holding driver state is a good way to deadlock the display pipeline.

### Before retrying

- Consider stopping SurfaceFlinger first (`stop`/`start` via `adb shell`) so the
  buffers are not contended.
- Or drive the DRM path instead, which is what the vendor stack actually uses.
- Either way, expect a possible reboot and do it with the device backed up.

## Why GET_EBC_BUFFER hangs: only two buffers exist

```
[7.434434] ebc_buf_init(): init OK! ebc_buf num = 2!
```

The pool holds **two** buffers. The vendor stack holds them, so a third request
blocks indefinitely. Stopping SurfaceFlinger did **not** help -- a dry run with
`stop surfaceflinger` still hung in `GET_EBC_BUFFER` and rebooted the device.
So the buffers are not released by stopping the compositor; something else
(likely the DRM/epdc side, which SurfaceFlinger opens via `msm_drm_open`) retains
them, or acquisition needs initialisation the vendor stack performs.

The input struct also mattered and was wrong: the window fields carried straight
over from `GET_EBC_BUFFER_INFO` were `(1648,1648)-(824,0)`, which is not a valid
rectangle. Asking the driver for a buffer matching that is a plausible way to
wedge it.

### Panel/waveform metadata, free from dmesg at boot

```
o_w_p_p(): file_size=599622, waveform_mode_version[0x10]=0x16, waveform_version=0x2e
o_w_p_p(): frame_rate=85HZ, waveform_lookup_table_fmt=4,
           waveform_mode_table_address=0x6c, mode_num=9, temp_num=14, gray_num=32
onyx_waveform_mode_swap_regal_and_regal_plus: swap.
```

Nine waveform modes, 14 temperature bands, 32 grey levels, 85 Hz. This is the
waveform blob's own header -- useful for the eventual controller, obtained with
no writes at all.

## Two device reboots were caused getting here

Both from `GET_EBC_BUFFER` on `/dev/ebc`. The device recovered fully each time
(bootloader still unlocked, no data loss), but the lesson stands:

**Observe the working sequence before synthesising one.** The driver logs every
update with full parameters (`waveform_mode`, `update_mode`, `update_marker`,
`flags`, `temp`) behind a debug-level gate. Raising that gate and watching the
vendor stack refresh the screen would have given exact, known-good values with
zero writes. That is the correct next step, not more blind ioctls.

## The sepdc debug interface

Only visible with root — the original recon ran unprivileged and saw nothing.

`/sys/devices/virtual/sepdc/debug/`:

| Attribute | Mode | Notes |
|---|---|---|
| `status` | r | live pipeline state, see below |
| `dump_list` | r | returned `1` |
| `panel_init` / `panel_clean` / `panel_last` | r | all `ok` |
| `update_err` | r | `0` |
| `debug_level` | rw* | reads `0`; **writes always fail** |
| `cut_frame_num` | rw* | `3` |
| `time_test_level` | rw* | `0` |
| `update_disable` | rw* | `0` |
| `submit_upd_work` | w | **triggers an update using driver-internal state** |
| `night_mode`, `reset_test`, `update_snapshot` | w | |

\* Mode bits say `0644`, but writes return `EACCES` as root **with SELinux
permissive and sysfs mounted rw**. These attributes were declared writable but
have no `store()` handler, so kernfs rejects the open. The `--w-------` ones are
the genuinely writable set.

Live `status`:

```
epdctask_status[0] wf_status[99] wftask_wf_status[99] wftask_status[0]
wb_status[30] wb_wf_status[0] cb_state[99] epdc_active_luts[0x0][0x0][0x0][0x0]
all_frames_completed[0] frame[1651:1651:1651]
```

Also: **`/waveform/eink_waveform.wbf`**, 599622 bytes — the panel's waveform blob,
matching `file_size=599622` from dmesg. Readable, and the source of the
`mode_num=9 / temp_num=14 / gray_num=32` metadata.

## Observation routes that are closed

- **`debug_level`** — no store handler, cannot be raised. This kills the plan of
  watching the vendor stack's `SET_EBC_SEND_UPDATE` parameters via dmesg.
- **ftrace** — `available_tracers: nop`, no `set_ftrace_filter`, no
  `kprobe_events`. Built without dynamic ftrace, so no function tracing or
  kprobes on `epdc_ioctl`.

What remains: intercepting SurfaceFlinger's ioctls from userspace (an
`LD_PRELOAD` shim), or `submit_upd_work`, which asks the driver to submit an
update using its own internal state — no user-supplied struct, which is exactly
the part that has been wedging the device.

---

# RESOLVED: userspace interception

`src/ebctrace.c`, an `LD_PRELOAD` shim logging every `ioctl()` against
`/dev/ebc` and `/dev/dri/*`. It only logs and forwards -- it never originates a
call. Injected by stopping SurfaceFlinger and relaunching it under the preload
(SELinux permissive for the duration, restored afterwards).

Bionic declares `int ioctl(int, int, ...)`, not glibc's `unsigned long` second
argument. The interposer must match or it is silently bypassed.

## Correction: /dev/ebc uses the SECOND dispatch

Earlier analysis concluded `/dev/ebc` was served by the dispatch at `0x57a920`
(base `0x7000`, 286 entries) and that the dispatch at `0x5b1a70` belonged to some
other, unexposed node. **That was backwards.**

Every command observed on `/dev/ebc` in the live trace:

```
0x700b 0x700c 0x700e 0x700f 0x701e 0x7021 0x7022 0x7025 0x7029 0x7210 0x7211
```

`0x7210`/`0x7211` are above the first dispatch's `0x711d` ceiling, and every
value falls inside the second dispatch's ranges (`0x7002..0x7029`, plus its
`> 0x7201` branch). So `/dev/ebc` is `epdc_ioctl` at `0x5b1a70`, and
**`SET_EBC_SEND_UPDATE = 0x700c` is callable directly on `/dev/ebc`.**

The earlier reasoning failed because `GET_EBC_DRIVER_SN` exists at `0x7002` in
*both* dispatches, so the one empirical result that seemed to discriminate did
not actually discriminate.

## Real SET_EBC_SEND_UPDATE payloads, captured live

```
in:  0  0  1648  824   2  1  1  4096  200704  0     -> rc=1160
in:  0  0  1648  824   2  1  2  4096  135168  0     -> rc=0
```

Against the struct recovered from the disassembly:

| Offset | Field | Observed | Note |
|---|---|---|---|
| `+0x00..0x0c` | `rect[4]` | `{0, 0, 1648, 824}` | full screen, x1 y1 x2 y2 |
| `+0x10` | `waveform_mode` | `2` | |
| `+0x14` | `update_mode` | `1` | |
| `+0x18` | `update_marker` | `1`, `2` | increments per call, as predicted |
| `+0x1c` | was unknown | `4096` | `0x1000` |
| `+0x20` | `flags` | `0x31000`, `0x21000` | bits 16 and 17 -- exactly the `tbnz` tests found at `0x5b2444`/`0x5b2448` |
| `+0x24` | was unknown | `0` | |

The flags bit pattern independently confirms the disassembly: the handler tests
bits 16, 17 and 18, and the live values set bits 16 and 17.

Return value is not a plain status -- the first call returned `1160`, the second
`0`. Possibly a frame or marker id.

Note the struct is **10 int32 = 40 bytes**, matching the `mov w2, #0x28` before
`copy_from_user` exactly.

## What this unblocks

A refresh can now be attempted with known-good parameters rather than guesses,
which is what caused both earlier reboots. The remaining unknown is buffer
acquisition: the two-buffer pool and how the vendor stack obtains one --
answerable from the same trace by examining the `0x700b`/`0x700e`/`0x700f` calls
that precede `0x700c`.

## The real call sequence -- and why the earlier attempts hung

Observed order on `/dev/ebc` (single fd, 35):

```
init:    0x7029  0x7021  0x701e  0x7022  0x7025
         0x7211  0x7211  0x7210  0x7211  0x7210
per-frame: 0x7025  0x700f  0x700b  0x700b  0x701e  0x7022  0x700e  0x700c
```

**No `0x7000` (`GET_EBC_BUFFER`) anywhere.** That command belongs to the *other*
dispatch; on `/dev/ebc` (base `0x7002`) it is out of range entirely. Both device
reboots came from calling it.

Argument shapes, read off where the stack garbage begins (the pair
`567244298 / -218052068` is leftover stack and marks the end of real data):

| Command | Argument |
|---|---|
| `0x700f`, `0x7022` | `NULL` |
| `0x700b` | pointer to a single `int32`, value `-1` |
| `0x700e` | pointer to a single `int32`, value `-1` |
| `0x701e` | pointer to a single `int32`, value `0` |
| `0x700c` | pointer to the 40-byte update struct -- ten clean words, then stack |

That last row is the cleanest confirmation of the struct size: exactly ten int32
of meaningful data before the canary, matching `mov w2, #0x28`.

### There is no userspace buffer acquisition

The update struct carries a rect, waveform mode, update mode, marker and flags
-- and no buffer handle. Pixel data reaches the EPDC through the DRM/SDE
composition path. Userspace does not acquire an EBC buffer at all.

This invalidates the whole approach behind the two crashes: they tried to
acquire a buffer this driver never asks for.

### Minimal refresh, using observed-good values

```c
int32_t upd[10] = {
    0, 0, 1648, 824,   /* rect: full screen        */
    2,                 /* waveform_mode            */
    1,                 /* update_mode              */
    marker,            /* increment per call       */
    4096,              /* +0x1c                    */
    0x21000,           /* flags: bits 16,17        */
    0                  /* +0x24                    */
};
ioctl(fd, 0x700c, upd);
```

Every value here was captured from the vendor stack rather than guessed.

## Capture technique 2: ptrace (`src/ebcptrace.c`)

Built because `LD_PRELOAD` turned out to be a dead end for a *correctly started*
SurfaceFlinger: init grants it capabilities, which sets `AT_SECURE`, and bionic
ignores `LD_PRELOAD` for `AT_SECURE` processes. Launching SF by hand makes the
preload work but the framework never finishes booting -- no init uid, SELinux
context or socket handoff, so the device sits at the loading screen. The two
requirements are mutually exclusive.

`ebcptrace` attaches to the already-running SF instead: `PTRACE_SEIZE` every
thread, `PTRACE_SYSCALL` loop, filter `ioctl` (aarch64 syscall 29) by request
range and fd path, read the struct with `process_vm_readv`, detach after a
bounded window.

Two implementation notes worth keeping:

- **`PTRACE_SEIZE` does not stop the tracee.** Issuing `PTRACE_SYSCALL`
  immediately fails `ESRCH` and nothing is ever traced. Must `PTRACE_INTERRUPT`
  and `waitpid()` first. The first run silently captured zero events for exactly
  this reason.
- `PTRACE_O_TRACECLONE` is needed to follow threads spawned after attach.

### Result: works, but does not capture updates

Clean attach to 24 threads, clean detach, no reboot, no instability. Captured:

```
tid=1347 /dev/ebc req=0x7211  arg[0]=128
tid=3022 /dev/ebc req=0x7210  arg[0]=10
tid=1244 /dev/ebc req=0x700b  arg[0]=-1
```

`0x7210`/`0x7211` come in pairs from many threads -- plausibly a per-frame
begin/end or lock/unlock. **No `0x700c` in any window.** Stopping SF on every
syscall slows it enough that the compositor does not reach the update path, so
the very event we want is the one the technique suppresses.

This is an observer-effect problem, not a bug. Lighter-weight interception
would be needed: a seccomp-unotify filter targeting only `ioctl`, or a Magisk
module that bind-mounts a patched SF binary (preserving init's start path so
`AT_SECURE` never blocks a preload).

### Waveform enum: still only mode 2 known

The one confirmed value remains `waveform_mode = 2` from the LD_PRELOAD capture.
The kernel reports nine modes (`mode_num=9`); mapping the rest to
`INIT`/`DU`/`A2`/`GC16`/`REGAL` needs a capture technique that does not perturb
the compositor.

### Lighter variant: main-thread-only tracing (also fails)

`ebcptrace <pid> <secs> main` seizes only the main thread, cutting trap overhead
~24x. Result: 4x `0x700b`, still **no `0x700c`**.

So the two settings fail for opposite reasons:

| Scope | Overhead | Result |
|---|---|---|
| all 24 threads | high | `0x7210`/`0x7211`/`0x700b`, updates suppressed |
| main thread only | low | `0x700b` only -- updates come from another thread |

`0x700c` is issued off the main thread, but tracing enough threads to catch it
reintroduces the throttling that stops it happening. ptrace cannot win here.

Genuinely lighter options not yet tried:

- **seccomp-unotify** filtering only `ioctl` -- no per-syscall stop for anything
  else. Needs the filter installed in the target, so still requires injection.
- **Magisk module bind-mounting a patched `surfaceflinger`** that logs
  `ioctl` itself. Preserves init's start path, so no `AT_SECURE` problem and no
  tracing overhead at all. Most promising, and the most work.
- **Hardware breakpoint on libc's `ioctl`** via `PTRACE_POKEUSER` debug
  registers -- traps only that one function rather than every syscall.

---

# MILESTONE: refresh fired successfully

`ebctool refresh 2 --go` submitted an update from our own code and the kernel
accepted it:

```
epdc_ioctl(): SET_EBC_SEND_UPDATE -- magic[1] [x=0 y=0 w=1648 h=824]!flags = 0x21000!
```

`rc=0`. No hang, no reboot, device stable afterwards.

## Working call

```c
int fd = open("/dev/ebc", O_RDWR);          /* needs root */
int32_t upd[10] = {
    0, 0, 1648, 824,   /* rect: x, y, w, h  */
    2,                 /* waveform_mode     */
    1,                 /* update_mode       */
    marker++,          /* update_marker     */
    4096,              /* +0x1c             */
    0x21000,           /* flags: bits 16,17 */
    0                  /* +0x24             */
};
ioctl(fd, 0x700c, upd);
```

No buffer acquisition, no mmap. Pixel content comes from the DRM/SDE composition
path; this call asks the controller to re-present it with a chosen waveform.

## Correction from the kernel log

The rect is **`x, y, w, h`** -- the kernel prints `[x=0 y=0 w=1648 h=824]`. The
struct comment previously called it `x1,y1,x2,y2`. Identical for a full-screen
update at the origin, but wrong for partial updates.

## Status of task 6

| | |
|---|---|
| Command numbers | confirmed |
| Update struct, all 10 fields | confirmed live |
| Buffer model | resolved -- none needed |
| Refresh from our own code | **working** |
| Waveform enum | only mode 2 mapped of nine |

What remains for a real controller is policy, not mechanism: which waveform for
which kind of screen change, and when to force a full clear. That needs the mode
map, which needs a lighter interception technique (Magisk-module SF wrapper).

## Key reframing: SET_EBC_SEND_UPDATE is NOT the per-frame path

`epdc_ioctl(): SET_EBC_SEND_UPDATE ...` is logged **unconditionally** in dmesg,
so vendor updates can be harvested for free. Sampling across seven activity
types (home, app launch, slow scroll, fast fling, back, screen off, screen on)
produced exactly **one** update -- on SCREEN_ON:

```
SET_EBC_SEND_UPDATE -- magic[3] [x=0 y=0 w=1648 h=824]!flags = 0x11000!
```

Scrolling, app launches and flings produced **none**. So `0x700c` is not how the
compositor refreshes the panel frame to frame -- it appears reserved for
occasional full-screen events such as wake.

This explains earlier observations that looked like tooling failures:

- ptrace saw `0x7210`/`0x7211` constantly but almost no `0x700c` -- because
  `0x7210`/`0x7211` *are* the per-frame calls.
- The LD_PRELOAD capture caught only two `0x700c` in a whole session.

**Implication for the refresh controller:** the policy layer we need lives in
the `0x7210`/`0x7211` pair plus the DRM/SDE commit path, not in
`SET_EBC_SEND_UPDATE`. Their arguments are a single int32 (`128` and `10`
respectively in captures), so they are cheap to characterise -- but they were
deprioritised because `0x700c` looked like the important one.

Next investigation should target `0x7210`/`0x7211` in the kernel's second
dispatch table, not further `0x700c` work.

## Second command range: 0x7202..0x7213

The `epdc_ioctl` dispatch has a second jump table for `cmd > 0x7201`:

```
5b1b68:  mov  w9, #-0x7202
5b1b6c:  add  w9, w21, w9        index = cmd - 0x7202
5b1b70:  cmp  w9, #0x11          18 commands: 0x7202..0x7213
5b1b7c:  add  x10, x10, #0x1ac   u16 table at 0x19241ac
5b1b80:  adr  x11, 0x5b1b90      target = 0x5b1b90 + entry*4
```

Decoded:

```
0x7202 -> 0x5b1b90     0x720c -> 0x5b1e2c     0x7210 -> 0x5b202c  (per-frame)
0x7204 -> 0x5b1cac     0x720d -> 0x5b1eac     0x7211 -> 0x5b20ac  (per-frame)
0x7205 -> 0x5b1d2c     0x720e -> 0x5b1f2c     0x7212 -> 0x5b212c
0x7206 -> 0x5b1dac     0x720f -> 0x5b1fac     0x7213 -> 0x5b21ac
0x7203, 0x7207-0x720b  -> 0x5b48e4 (unhandled)
```

Handlers are uniformly 0x80 bytes apart -- a regular family of small commands.

### 0x7210 and 0x7211 both take a single int32

Both handlers open with an `access_ok` for **4 bytes** (`adds x10, x10, #0x4`),
test the debug-level global at `0x35f0758`, then branch out-of-line to
`0x5b31a8` / `0x5b3210` where they do the PAN uaccess dance
(`msr TTBR0_EL1` / `isb`) and execute `ldr w20, [x10]` -- an inlined `get_user`
of one 32-bit word.

That matches the live captures exactly:

```
0x7210  arg[0] = 10
0x7211  arg[0] = 128
```

So the per-frame pair is: two commands, each carrying one small integer. What
they do with that value lies past the traced window and is the next thing to
chase -- but the calling convention is now settled, which is what a controller
needs first.

### 0x7210 / 0x7211 identified: TCON debounce tuning, not refresh

Following the user value through to its use:

```
5b3a30:  mov  w3, #0x10          /* 0x7210 -> cmd 0x10 */
5b3a34:  mov  w4, w20            /* user value          */
5b3a3c:  bl   printk
         byte0 = 0x10, byte1 = <value>   -- a 2-byte {cmd, data} message
```

The format string and function name settle it:

```
'%s(): [%s] cmd[0x%x] data[0x%x]\n'
'lfe5u_ctrl_send_cmd'
0x7210 -> 'CMD_TCON_DEBOUNCE_PARM'
0x7211 -> 'CMD_TCON_DEBOUNCE_THRESHOLD'
```

`LFE5U` is a **Lattice ECP5 FPGA** -- the panel's TCON. These ioctls are thin
wrappers that send a two-byte command/data pair to it. Observed live values
(`0x7210` = 10, `0x7211` = 128) are debounce parameters, and they line up with
the sysfs attributes seen earlier: `dithering_set_debounce_delta`,
`dithering_set_debounce_threshold`.

**So the per-frame pair is touch/dither debounce tuning, not the refresh path.**

## Conclusion: refresh policy is in DRM, not in /dev/ebc

Neither candidate is the frame-by-frame refresh mechanism:

| Command | What it actually is |
|---|---|
| `0x700c` `SET_EBC_SEND_UPDATE` | full-screen events only (observed once, on wake) |
| `0x7210` / `0x7211` | TCON debounce parameters sent to the Lattice FPGA |

The remaining path is the one the boot log pointed at all along:

```
mdss_mdp_epdc_open:  caller[msm_drm_open+0x48/0x80] task[composer-servic]
```

plus the exported `drm_atomic_helper_{update_plane,commit_planes,cleanup_planes}_epdc`
symbols. Onyx's patched SurfaceFlinger drives refresh through **DRM atomic
commits** on `/dev/dri/card0`, with EPD behaviour carried as DRM plane/CRTC
properties -- `/dev/ebc` handles auxiliary control only.

**Implication for the controller:** a replacement must participate in DRM atomic
commits, not issue `/dev/ebc` ioctls. That is consistent with the very first
finding of this project -- that the policy lives inside the compositor -- and it
means a source-built SurfaceFlinger remains the real deliverable.

Next investigation: enumerate DRM properties on `/dev/dri/card0`
(`drmModeObjectGetProperties` on the CRTC and planes) and look for Onyx-added
EPD properties. Fully read-only.

---

# THE REFRESH PATH: DRM plane properties

`src/drmprops.c` enumerates all DRM objects on `/dev/dri/card0` (read-only; only
GET ioctls plus the universal-planes and atomic client caps). 372 properties
across 2 CRTCs, 3 connectors, 7 planes. Everything is stock Qualcomm SDE except
**two properties on the planes**:

```
EPDC_UPDATE_PARMS_ADDR   id=78   value=12970367436310205940   (a pointer)
EPDC_UPDATE_CNT          id=79   value=0
```

Both names appear in the kernel symbol/string dump captured at the start of this
project (`firmware/analysis/kernel-epd-attrs.txt`) and were overlooked.

## How refresh actually works

This closes the loop with the kernel log format string found much earlier:

```
commit[%d] upd_data_cnt[%d][0] [%d %d %d %d] waveform_mode[%d] update_mode[%d]
    update_marker[%d] flag[%d] temp[%d]
```

`upd_data_cnt` is `EPDC_UPDATE_CNT`. The sequence per frame is:

1. SurfaceFlinger sets `EPDC_UPDATE_PARMS_ADDR` on a plane to point at an array
   of update-parameter structs.
2. Sets `EPDC_UPDATE_CNT` to the number of entries.
3. Issues a **DRM atomic commit**.
4. The kernel reads the array and drives the EPD accordingly.

**The array element is the same 40-byte struct already decoded** from the
`SET_EBC_SEND_UPDATE` handler -- rect (x, y, w, h), waveform_mode, update_mode,
update_marker, `+0x1c`, flags, `+0x24`. That work carries over directly; only
the delivery mechanism differs.

So the three candidate paths resolve as:

| Path | Role |
|---|---|
| `/dev/ebc` `0x700c` | full-screen events only (wake) |
| `/dev/ebc` `0x7210`/`0x7211` | TCON debounce params to the Lattice FPGA |
| **DRM plane props + atomic commit** | **the per-frame refresh path** |

## What a replacement controller must do

Set `EPDC_UPDATE_PARMS_ADDR` and `EPDC_UPDATE_CNT` on the plane as part of its
atomic commit -- i.e. it must live inside the compositor. This confirms, from the
opposite direction, the very first finding of the project: the refresh policy is
inside SurfaceFlinger, and a prebuilt GSI cannot carry it. **A source-built
/e/OS with a patched SurfaceFlinger is the real deliverable.**

Practical consequence: the waveform-mode map is no longer needed from ioctl
tracing. It can be read out of the parameter array by dumping the blob behind
`EPDC_UPDATE_PARMS_ADDR` during normal composition -- entirely read-only.

## Waveform blob: /waveform/eink_waveform.wbf

Readable as root, 599622 bytes -- matches `file_size=599622` from dmesg.
Standard E-Ink WBF format.

Header (validated against the kernel's own boot-time parse):

```
offset 0x00  checksum        0x4375ef5f
offset 0x04  filesize        0x00092646 = 599622   <- matches dmesg
offset 0x10  mode_version    0x16                  <- matches dmesg
offset 0x11  waveform_version 0x2e                 <- matches dmesg
```

dmesg also gave `waveform_mode_table_address=0x6c, mode_num=9, temp_num=14,
gray_num=32, frame_rate=85HZ`.

Mode table at `0x6c`, nine entries. Each is a **3-byte little-endian address
followed by a 1-byte checksum** (the checksum is the sum of the address bytes --
all nine verify):

```
mode 0 -> 0x000090      mode 5 -> 0x0002c0
mode 1 -> 0x000100      mode 6 -> 0x000330
mode 2 -> 0x000170      mode 7 -> 0x0003a0
mode 3 -> 0x0001e0      mode 8 -> 0x000410
mode 4 -> 0x000250
```

Each address points to that mode's temperature-range table (14 entries), which
in turn points at the per-temperature waveform data.

### Names are not in the blob, and not in the kernel

WBF does not store mode names, and a search of the kernel image found no
cluster of `INIT`/`DU`/`GC16`/`A2` strings. (The single `REGAL` hit is a SCSI
vendor name in the kernel's device blacklist, between `MegaRAID` and `PIONEER`
-- unrelated.)

The kernel does contain `onyx_waveform_mode_transform_init()` and
`onyx_waveform_mode_swap_regal_and_regal_plus()`, so Onyx remaps indices rather
than using the raw blob order. Mapping index -> semantic name therefore needs
either that transform table decoded statically, or observation of which index is
used for which on-screen behaviour.

**Known so far:** `waveform_mode = 2` is what the vendor stack uses for ordinary
composition (captured live). Given nine modes and a quality-first e-reader, index
2 is plausibly GC16, but that is inference, not established.

## Waveform mode-name mapping: SOLVED

`onyx_waveform_mode_transform_init()` (located at `0x590c18` via its own log
string, since `kptr_restrict` is locked at 2 and kallsyms is unavailable) does a
version-keyed lookup:

```
590c20:  ldrb w9, [x8, #0x10]     /* waveform mode_version -- 0x16 here */
590c30:  ldr  w8, [x10, #0x730]   /* table at 0x340b730, stride 0x4c    */
590c34:  cmp  w8, w9              /* chain of compares, one per entry   */
```

20 version entries. This device's `0x16` is **entry 17 at `0x340bc3c`**:

```
16 00 00 00                        version = 0x16
01 00 00 00  00 00 00 00  01 00 00 00  02 00 00 00
ff ff ff ff  06 00 00 00  04 00 00 00  ff ff ff ff
03 00 00 00  ff ff ff ff  ff ff ff ff  ff ff ff ff
05 00 00 00  ff ff ff ff  04 00 00 00  00 00 00 00
08 00 00 00  07 00 00 00
```

An 18-entry map of **logical mode -> waveform-blob index**, `-1` meaning
unsupported. Values span 0..8, exactly the nine modes in
`eink_waveform.wbf` -- self-consistent.

```
logical:  0  1  2  3   4  5  6   7  8   9 10 11 12  13 14 15 16 17
blob:     1  0  1  2  -1  6  4  -1  3  -1 -1 -1  5  -1  4  0  8  7
```

Interpreting the index as the Rockchip `EPD_*` enum (this driver is a confirmed
Rockchip EBC port):

| Logical | Name | Blob mode |
|---|---|---|
| 0 | `EPD_AUTO` | 1 |
| 1 | `EPD_OVERLAY` | 0 |
| 2 | `EPD_FULL_GC16` | 1 |
| 3 | `EPD_FULL_GL16` | 2 |
| 5 | `EPD_FULL_GLD16` | 6 |
| 6 | `EPD_FULL_GCC16` | 4 |
| 8 | `EPD_PART_GL16` | 3 |
| 12 | `EPD_A2` | 5 |
| 14 | `EPD_RESET` | 4 |
| 16, 17 | (high modes) | 8, 7 |

**The live-captured `waveform_mode = 2` is `EPD_FULL_GC16`** -- full 16-level
greyscale, the quality mode. Consistent with an e-reader that favours image
quality over speed.

The enum *names* come from the Rockchip lineage rather than from this kernel
(which stores no mode-name strings); the *table* is read directly from the
device's own firmware. `onyx_waveform_mode_swap_regal_and_regal_plus()` at
`0x590dc0` post-processes this mapping and is not yet decoded.

---

# Task 7 scoping: where the EPD code actually lives

Split between system and vendor, established by string analysis of the stock
binaries:

| Component | Partition | EPD role |
|---|---|---|
| `surfaceflinger` | **system** (replaced by any port) | computes/merges regions: `EpdcWrapper::addEpdc(x,y,w,h,mode)`, `mergeByMode()`, `getBatch()`, then `commitEpdc` |
| `vendor.qti.hardware.display.composer-service` | **vendor** (we keep) | performs the update: `CommitEpdc`, `onyx_epdc_update_to_display()`, validates `upd_data_cnt` and `waveform_mode`, sets the DRM plane properties |

Checked and found EPD-free: `libsdmcore.so`, `libsdmutils.so`, `libdrmutils.so`,
`libqdutils.so`, `libdisplayconfig.qti.so`,
`vendor.qti.hardware.display.composer@3.0.so`, `libqdMetaData.so`.

**Good news:** the half that touches DRM and the kernel is in `/vendor`, which no
system port replaces. We do not have to reimplement the update submission.

**The gap:** the transport from SF to the composer service. `hwc_epdc_llist` is
an hwcomposer type shared between them, and SF references
`vendor.qti.hardware.display.composer3`, so it is most likely a vendor-extended
composer AIDL whose client stub is statically linked into Onyx's SF. No vendor
`.so` exports an epdc entry point, and the service binary is stripped, so the
method name and parcel layout are not recoverable from strings alone.

## Three routes for task 7

1. **Reverse the SF -> composer interface** (disassemble `commitEpdc` for the
   binder transaction code and parcel layout), then implement it in a patched
   AOSP SurfaceFlinger. Most correct, most work.
2. **Build /e/OS A15 and drop in Onyx's stock `surfaceflinger` binary.** Both are
   Android 15; the vendor composer and its private interface stay intact on both
   sides. Much cheaper if the ABI holds. Best first experiment.
3. **Build /e/OS and accept no EPD optimisation** -- correct system, poor display.
   Useful only as a compatibility probe.

Route 2 is the pragmatic first attempt and is only possible because Onyx's system
is Android 15 qssi -- the same generation we would build.

## Build environment constraints

```
/Volumes/Storage   900 GB free   (AOSP needs ~250 GB source + ~150 GB out)
podman             available     (Linux container; AOSP does not build on macOS)
8 cores / 16 GB RAM              (below the 32 GB AOSP wants -- expect -j4,
                                  heavy swap, multi-hour builds, possible OOM
                                  at link time)
```

---

## CORRECTION (see docs/13-epd-ecosystem.md): Onyx shifted the ioctl numbering

Rockchip publishes the ancestor of this driver -- `ebc_dev.h` in
`drivers/gpu/drm/rockchip/ebc-dev/`. The command names here match it exactly,
so Onyx ported Rockchip's `ebc-dev` onto a Qualcomm SoC rather than writing one.
Upstream:

```
0x7000 EBC_GET_BUFFER        0x7006/7 EBC_{GET,SEND}_OSD_BUFFER
0x7001 EBC_SEND_BUFFER       0x7008   EBC_GET_AUTO_OLD_BUFFER
0x7002 EBC_GET_BUFFER_INFO   0x7009   EBC_GET_AUTO_NEW_BUFFER
0x7003 EBC_SET_FULL_MODE_NUM 0x700a   EBC_GET_AUTO_BG_BUFFER
0x7004 EBC_ENABLE_OVERLAY    0x700b   EBC_GET_AUTO_CUR_BUFFER
0x7005 EBC_DISABLE_OVERLAY
```

**Onyx inserted `GET_EBC_DRIVER_SN` at 0x7002**, so everything from there is +1
relative to upstream -- which is why `GET_EBC_BUFFER_INFO` answers at 0x7003
here (both values confirmed on-device). Any mapping in this document derived by
assuming upstream numbering is therefore off by one above 0x7001.

`struct ebc_buf_info` is confirmed identical to upstream, which retroactively
validates the geometry decoding above.

Two further points:

* **`0x7000` blocks by design.** Upstream `EBC_GET_BUFFER` waits for a free
  buffer from the driver's queue. With the vendor stack holding every buffer it
  never returns -- that is the whole explanation for the two silent device
  lockups, and why `docs/11` says never to call it.
* **Onyx's own commands sit above upstream's range.** Rockchip stops at 0x700b;
  the four their SurfaceFlinger actually uses (`0x701e`, `0x7021`, `0x7022`,
  `0x7029`) are Onyx additions, so no published source will name them.
