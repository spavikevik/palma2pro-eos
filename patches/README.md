# AOSP tree patches

Changes to the AOSP source tree, which lives on the builder at `/aosp` and is
**not** part of this repository. Without these files those edits exist only on
that one machine.

Apply from the root of each AOSP project:

```sh
cd /aosp/system/core        && git apply /path/to/patches/main/0001-*.patch
cd /aosp/frameworks/native  && git apply /path/to/patches/main/0002-*.patch
```

Regenerate after further edits with `git diff -- <file>` in the relevant project.

Names are `NNNN-<aosp-project>-<what-it-does>.patch`: the number is apply order,
the project says which tree to apply it in, and the rest says what it fixes
rather than which lines it touches.

## `main/` -- belongs on the main line

| patch | what | why |
|---|---|---|
| `0001-system-core-ueventd-let-surfaceflinger-open-dev-ebc.patch` | `/dev/ebc 0666` ueventd rule | SurfaceFlinger opens `/dev/ebc` directly to drive the EPD. The driver leaves it `0600 root:root`, so SF (uid `system`) cannot open it and reports `hasHwTcon: 0`. **TODO**: tighten to `0660 root system` once bring-up no longer needs to probe it from an adb shell. |

## Not captured here

Device-local changes that are not source patches and will not survive a reflash
of the partition they live in:

* `/vendor/etc/fstab.default` -- 7-byte `dirsync` -> `noatime` patch
  (`docs/09-vendor-fstab-patch.md`); undo image in `firmware/analysis/`
* `ro.adb.secure=0` in both `system_b` and `vendor_b` build.prop (task #10);
  vendor's copy is the one that wins
* the client-composition toggle and the `/dev/epdc` directory, which live in
  `system/etc/init/epdc-clientcomp.rc` on the device (docs/11)
* `qemu.hw.mainkeys=0`, without which no navigation bar is created at all
