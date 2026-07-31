# Device-local patch: `dirsync` in /vendor/etc/fstab.default

**This change lives only on the device, not in the device tree.** Restoring
`vendor_b` from the EDL backup reverts it and `/data` will stop mounting again.

## Symptom

First boot that got past the VNDK blocker reached vold and then:

```
F2FS-fs (dm-39): Unrecognized mount option "dirsync" or missing value
vold: [libfs_mgr] Cannot mount filesystem on /dev/block/mapper/userdata
      at /data with fstype f2fs: Invalid argument
vold: fs_mgr_do_mount failed with rc -1
```

`/data` never mounts, so Android shows *Can't load Android system* and offers a
factory reset. Resetting does not help -- `make_f2fs` runs, the format succeeds,
and the very next mount fails identically.

## Cause

`dirsync` is a VFS flag. This A15 `fs_mgr` does not consume it, so it is passed
through to f2fs as filesystem data and rejected. Onyx's Android 11 `fs_mgr`
evidently did consume it, which is why stock boots with the same line.

Fixing our own `rootdir/etc/fstab.default` was **not enough**: that copy goes
into the ramdisk, which only serves *first-stage* mounts (system, vendor,
product, odm). `/data` is `latemount`, done by **vold** in second stage, and
vold's `fs_mgr` resolves the fstab from `/odm/etc/fstab.*` then
`/vendor/etc/fstab.*`. This port does not rebuild vendor, so vold kept reading
Onyx's original file.

Confirmed by grepping the super dump -- exactly one occurrence, inside
`vendor_b`:

```
0x117c88cea  .../userdata  /data  f2fs  noatime,nosuid,nodev,discard,dirsync,reserve_root=32768,...
```

## The patch

Length-preserving, 7 bytes, `dirsync` -> `noatime`. `noatime` is consumed by
`fs_mgr` as `MS_NOATIME` and is already first in that option list, so the
duplicate is inert and never reaches f2fs.

```
vendor_b first extent   super sector 8996864, 1330016 sectors
offset within vendor_b  87,592,170
absolute device byte    4,880,665,834
device 4096-sector      1191568   (string at offset 3306, word at 3314)
```

The whole word sits inside that one sector, so it is a single read-modify-write.
AVB is disabled (vbmeta flags 0x3) and the log confirms `AVB is not enabled,
skip verity setup`, so there is no hashtree to invalidate.

```sh
edl rs 1191568 1 vendor-fstab-sector.orig --loader=... --memory=ufs --lun=0
# verify: b'discard,dirsync,reserve_root' at offset 3306
# patch bytes 3314..3320 -> b'noatime'
edl ws 1191568 vendor-fstab-sector.patched --loader=... --memory=ufs --lun=0
edl rs 1191568 1 verify.bin && cmp verify.bin vendor-fstab-sector.patched
```

Undo: write `firmware/analysis/vendor-fstab-sector.orig` back to sector 1191568.

## If vendor is ever rebuilt or restored

Reapply this, or better, ship a corrected `fstab.default` in `odm` -- `fs_mgr`
checks `/odm/etc/fstab.*` **before** `/vendor/etc/fstab.*`, so an odm copy wins
without touching vendor at all. That was not done here only because patching 7
bytes was smaller than writing a file into odm's ext4 image.
