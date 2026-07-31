#!/usr/bin/env python3
"""Append kernel cmdline arguments to an Android boot image, in place.

Why: the /e/OS GSI lands in recovery with no obtainable log. Adding
`androidboot.selinux=permissive` tests the SELinux hypothesis directly rather
than by inference. The GSI is a userdebug build (ro.debuggable=1), so init
honours the flag -- on a `user` build it would be ignored, because
ALLOW_PERMISSIVE_SELINUX is compiled in only for userdebug/eng.

The cmdline lives in a FIXED-SIZE field in the boot header (512 bytes at offset
64), so appending to it changes no section size and shifts nothing. That matters
here: patching this image's ramdisk previously broke boot twice by invalidating
`recovery_dtbo_offset`, which is an absolute offset. Editing only the header
avoids that whole class of bug.

`extra_cmdline` (1024 bytes at 608) is left alone -- not every Qualcomm ABL
concatenates it, whereas the main field is always used.

The header's id[32] SHA1 goes stale, which is harmless: this device is flashed
with AVB verification disabled (vbmeta flags 0x3), and the bootloader does not
check that field itself.

Usage:
    patch-boot-cmdline.py <in.img> <out.img> "androidboot.selinux=permissive"
"""

import struct
import sys

CMDLINE_OFF = 64
CMDLINE_LEN = 512


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    src, dst, extra = sys.argv[1], sys.argv[2], " ".join(sys.argv[3:])

    img = bytearray(open(src, "rb").read())
    if img[:8] != b"ANDROID!":
        print("not an Android boot image", file=sys.stderr)
        return 1

    hv = struct.unpack_from("<I", img, 40)[0]
    cur = bytes(img[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN]).split(b"\0")[0]
    cur_s = cur.decode("utf-8", "replace")
    print(f"header v{hv}")
    print(f"current cmdline ({len(cur)} B):\n  {cur_s}")

    for tok in extra.split():
        key = tok.split("=")[0]
        if key in cur_s:
            print(f"WARNING: {key} already present -- appending anyway, "
                  f"last occurrence wins in the kernel", file=sys.stderr)

    new = (cur_s + " " + extra).strip().encode()
    # Leave a byte for the NUL terminator.
    if len(new) > CMDLINE_LEN - 1:
        print(f"ERROR: cmdline would be {len(new)} B, field holds "
              f"{CMDLINE_LEN - 1}. Refusing.", file=sys.stderr)
        return 1

    img[CMDLINE_OFF:CMDLINE_OFF + CMDLINE_LEN] = new + b"\0" * (CMDLINE_LEN - len(new))

    out = bytes(img)
    assert len(out) == len(open(src, "rb").read()), "image size changed -- bug"
    open(dst, "wb").write(out)
    print(f"new cmdline ({len(new)} B):\n  {new.decode()}")
    print(f"wrote {dst} ({len(out)} bytes, size unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
