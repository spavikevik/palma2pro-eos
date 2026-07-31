# Build, flash, test

The practical loop. `docs/04` covers why the build runs on a remote machine and
`docs/05` covers how that machine is wired up; this is what you actually type.

There are two loops, and picking the wrong one is the single biggest time sink
on this project.

| | fast loop | full loop |
|---|---|---|
| when | changing a binary or a library | changing partitions, kernel, or many packages |
| build | one soong module (~50 s warm) | full image (hours) |
| deploy | `adb push` over a writable `/system` | EDL, image write |
| device | stays booted, restart one service | reboots into EDL, several minutes |

**Use the fast loop unless you cannot.** Everything in `docs/11` and `docs/15`
was developed without ever flashing an image.

---

## 1. The traps, first

These cost hours each when hit. Read them before your first build.

**Never touch a `.mk` file to iterate.** Editing any makefile triggers a full
kati/soong regeneration, roughly 35 minutes, before a single source file
compiles. Source edits (`.c`, `.cpp`, `.h`) are free. If you need a build flag
temporarily, find another way.

**Adding a *new file* to a directory that a glob picks up also triggers it.**
Adding `overlay/.../drawable-nodpi/default_wallpaper.png` cost a full regen even
though no makefile changed, because the overlay directory is globbed. Editing an
existing file there is free; creating one is not.

**A blank screen usually means the display is asleep, not broken.** An empty
`screencap` (about 9 kB, solid black) is the signature. Two separate wrong
conclusions in this project were built on asleep-display captures. Always:

```sh
adb shell 'svc power stayon true; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard'
```

**After every SurfaceFlinger restart, re-apply client composition** or the nav
bar, status bar and IME silently vanish -- they are separate DRM planes and the
kernel drops any plane smaller than the panel (`docs/11`):

```sh
adb shell 'service call SurfaceFlinger 1008 i32 1'
```

`system/etc/init/epdc-clientcomp.rc` does it on boot with an 8 second delay, so
after a reboot, wait rather than panicking.

**`adb remount` is needed again after every reboot** before you can push to
`/system` or `/vendor`.

---

## 2. Fast loop

### Build one module

```sh
scripts/builder.sh build surfaceflinger     # or framework-res, or any module
scripts/builder.sh logs -f                  # follow
scripts/builder.sh status                   # what is running
```

Wait for the real completion marker -- `pgrep ninja` is not reliable, there are
gaps between phases:

```sh
scripts/builder.sh ssh 'grep -c "build completed successfully" /aosp/build.log'
```

Check the artifact's timestamp before deploying, or you will happily push the
*previous* build and debug a change that is not there:

```sh
scripts/builder.sh ssh 'ls -l --time-style=+%H:%M \
  /aosp/out/target/product/Palma2_Pro_C/system/bin/surfaceflinger'
```

### Get the artifact off the builder

There is no `scp` subcommand, and stdin is not forwarded. Use base64:

```sh
scripts/builder.sh ssh 'base64 -w0 /aosp/out/target/product/Palma2_Pro_C/system/bin/surfaceflinger' \
  | base64 -d > /tmp/sf.new
ls -l /tmp/sf.new     # sanity: size must match the builder's
```

The same trick works in the other direction for sending a file or script *to*
the builder:

```sh
B64=$(base64 < local.py | tr -d '\n')
scripts/builder.sh ssh "echo '$B64' | base64 -d > /tmp/remote.py && python3 /tmp/remote.py"
```

### Push and restart

```sh
adb root && adb remount
adb shell 'cp /system/bin/surfaceflinger /data/local/tmp/surfaceflinger.prev'   # keep a way back
adb push /tmp/sf.new /system/bin/surfaceflinger
adb shell 'chmod 755 /system/bin/surfaceflinger; chown root:shell /system/bin/surfaceflinger'
adb shell 'setprop ctl.restart surfaceflinger'
sleep 15
adb shell 'service call SurfaceFlinger 1008 i32 1'      # client composition, always
```

Restarting `surfaceflinger` also restarts `zygote`, so the UI reloads -- about
15 seconds. Restarting the composer restarts SurfaceFlinger too.

Native tools built with zig (no NDK needed):

```sh
zig cc -target aarch64-linux-musl -static -O2 -o out/ebcfb src/ebcfb.c
zig cc -target aarch64-linux-none -fPIC -shared -nostdlib -O2 -o out/libepdcshim.so src/epdcshim.c
adb push out/libepdcshim.so /vendor/lib64/ && adb shell 'setprop ctl.restart vendor.qti.hardware.display.composer'
```

The shim is built freestanding on purpose: it is injected into a bionic process
and must not drag in a libc.

---

## 3. Full loop

Only for kernel, partition layout, or a wholesale image change.

```sh
scripts/builder.sh push          # sync the device tree (rsync -a keeps mtimes, so no needless regen)
scripts/builder.sh build         # full image
```

### Into EDL

`fastboot` is not usable on this device for flashing -- Onyx's fastbootd rejects
`flash`. Everything goes through EDL (Sahara/Firehose):

```sh
adb reboot edl                   # works;  adb reboot bootloader does NOT help
```

The screen stays blank in EDL. That is normal -- there is no bootloader UI on
this panel (`docs/02`), so drive everything from the host and never wait for an
on-device prompt.

### Write

```sh
# a logical partition, resolving its extents from lpdump
scripts/flash-logical-via-edl.py <image> <lpdump.txt> <partition> --go

# only the sectors that changed since the last flash -- seconds instead of minutes
scripts/edl-delta-flash.py <old.img> <new.img> <lpdump.txt> <partition> --go
```

`edl-delta-flash.py` requires `old.img` to be byte-identical to what is on the
device. If in doubt, do a full write; a wrong baseline corrupts the filesystem
quietly.

**Re-dump before patching partition metadata.** A stale `lpdump` once led to
resizing a partition that had already been resized, and diagnosing the wrong one.

### Backup and restore

```sh
scripts/edl-backup.sh            # full partition backup
scripts/edl-verify-restore.sh    # verify the restore path actually works
```

Stock images live in `firmware/`. They are the way back from anything.

---

## 4. Testing

### Is it alive

```sh
adb wait-for-device && adb root
adb shell 'getprop sys.boot_completed'                  # 1
adb shell 'ps -A | grep -E "surfaceflinger|composer"'
adb logcat -b crash -d | tail
```

### Is the display actually working

Wake it first (see traps), then:

```sh
adb shell 'screencap -p /data/local/tmp/s.png' && adb pull /data/local/tmp/s.png
```

A capture around 9 kB is solid black -- asleep, or a `FLAG_SECURE` window such
as the PIN screen, which blanks captures by design. A real screen is 60-250 kB.

`screencap` proves the *framework* composited something. It says nothing about
whether the panel received it -- those are different failures (`docs/11`).

### Is the panel being refreshed

The driver logs one line per update, so count them over a window:

```sh
adb shell dmesg > /tmp/dm.txt
# count 'waveform_clean_work_handler' lines in the last 10 s of kernel time
```

`dmesg` is a ring buffer and wraps; comparing two raw counts can go *negative*.
Filter by the kernel timestamp in the line instead.

Expected: **0 on a static screen**, non-zero while interacting. Anything
refreshing at idle means something is animating -- find it by diffing two
`screencap` frames a couple of seconds apart and looking at which rows changed.

### What is being published

```sh
adb shell 'od -A n -t d4 -j 8 -N 40 /dev/epdc/damage'
#   seq, count, full, then rect[0] as l t r b
adb logcat -s CompositionEngine | grep epdc
adb logcat | grep epdcshim
```

Healthy: `epdcshim: attached to SurfaceFlinger damage at /dev/epdc/damage`.

### Panel tuning, live

No rebuild, no restart -- re-read every 30 commits:

```sh
setprop persist.epdcshim.wf 2          # waveform: 2=GC16 full, 8=PART_GL16, 12=A2
setprop persist.epdcshim.upd 0         # 1 flashes the whole panel on every change
setprop persist.epdcshim.interval 120  # ms floor between refreshes
setprop persist.epdcshim.fullevery 12  # periodic full-flash clean
setprop persist.epdcshim.enable 0      # off, for A/B
```

`upd` is the one that matters: `1` flashes constantly, `0` does not.

---

## 5. When it breaks

| symptom | first thing to check |
|---|---|
| black screen, adb works | display asleep -- wake it before anything else |
| nav/status bar gone | client composition reset; `service call SurfaceFlinger 1008 i32 1` |
| panel blank but `screencap` fine | damage/update path, not composition (`docs/11`) |
| SF crash-looping | `adb push /data/local/tmp/surfaceflinger.prev /system/bin/surfaceflinger` |
| no boot, adb dead | EDL, restore from `firmware/` |
| build "did nothing" | you edited a `.mk`, or you deployed a stale artifact -- check its mtime |

adb survives almost everything, because the display is not on the boot path.
EDL survives the rest. The device has not been unrecoverable yet.
