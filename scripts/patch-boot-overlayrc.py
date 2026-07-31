#!/usr/bin/env python3
"""Inject a Magisk overlay.d .rc into the boot ramdisk to capture boot logs.

Why: the GSI dies at StorageManagerService.initUser0() and reboots to recovery.
Its adbd never brings USB up (observed: 46s of no enumeration at all during the
boot window), so logs cannot be pulled over adb. But the boot image is
Magisk-patched, and magiskinit injects any `overlay.d/*.rc` into init.rc at
first-stage init -- which runs regardless of USB, /data or the framework.

The injected service loops `logcat -d` into the `logdump` partition and `dmesg`
into `rawdump`. Both were read over EDL and confirmed to be all zeros -- they
are Qualcomm crash-dump regions that are never armed on a retail unit -- and
both are in the backup set. After the failed boot they are read back over EDL.

Looping a full `-d` dump rather than streaming matters: a streaming redirect is
block-buffered and an abrupt reboot loses the tail, which is exactly the part we
need. Each iteration rewrites the whole buffer, so the last completed write is
always self-contained.

The ramdisk section is padded back to its ORIGINAL page count. See
patch-recovery-adb.py for why that is not optional.

Usage:
    patch-boot-overlayrc.py <in.img> <out.img>
"""

import gzip
import io
import struct
import sys

CPIO_MAGIC = b"070701"
TRAILER = b"TRAILER!!!"

# `class core` starts before /data, so the service is alive across the whole
# boot. No seclabel: the GSI's policy has no type we can safely name, and the
# device is booted permissive for this test anyway.
RC = """
service bootlog /system/bin/sh -c "while true; do /system/bin/logcat -b all -d -v threadtime > /dev/block/bootdevice/by-name/logdump; /system/bin/dmesg > /dev/block/bootdevice/by-name/rawdump; sleep 2; done"
    class core
    user root
    group root log readproc
    disabled

on post-fs-data
    start bootlog

on boot
    start bootlog
"""


def cpio_entry(name: str, data: bytes, mode: int) -> bytes:
    name_b = name.encode() + b"\0"
    hdr = (
        CPIO_MAGIC
        + b"%08X" % 0
        + b"%08X" % mode
        + b"%08X" % 0
        + b"%08X" % 0
        + b"%08X" % 1
        + b"%08X" % 0
        + b"%08X" % len(data)
        + b"%08X" % 0 * 4
        + b"%08X" % len(name_b)
        + b"%08X" % 0
    )
    out = hdr + name_b
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\0" * ((4 - len(data) % 4) % 4)
    return out


def strip_trailer(cpio: bytes) -> bytes:
    i = cpio.rfind(TRAILER)
    if i < 0:
        return cpio
    start = cpio.rfind(CPIO_MAGIC, 0, i)
    return cpio[:start] if start >= 0 else cpio


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]

    img = open(src, "rb").read()
    if img[:8] != b"ANDROID!":
        print("not an Android boot image", file=sys.stderr)
        return 1

    ks, rs, ps = (struct.unpack_from("<I", img, o)[0] for o in (8, 16, 36))
    ro = ((ps + ks) + ps - 1) // ps * ps
    cpio = gzip.decompress(img[ro:ro + rs])
    print(f"ramdisk cpio: {len(cpio)} bytes")

    # The ramdisk must stay within its original page count (the AVB vbmeta blob
    # begins immediately after the DTB -- there is zero slack), and python's
    # zlib cannot even reproduce the original size on a no-op recompress. So
    # make room by dropping the GSI AVB public keys: init's first-stage AVB
    # reads them to verify a chained `system`, but this device is flashed with
    # vbmeta flags 0x3 (HASHTREE_DISABLED | VERIFICATION_DISABLED) and init
    # early-returns before consulting them. ~3KB of high-entropy data, so the
    # saving survives compression.
    DROP = ("avb/q-gsi.avbpubkey", "avb/r-gsi.avbpubkey", "avb/s-gsi.avbpubkey")
    kept, dropped = bytearray(), []
    off = 0
    while off + 110 <= len(cpio):
        if cpio[off:off + 6] != CPIO_MAGIC:
            break
        f = lambda n: int(cpio[off + 6 + n * 8: off + 14 + n * 8], 16)
        fsz, nsz = f(6), f(11)
        name = cpio[off + 110: off + 110 + nsz - 1].decode("utf-8", "replace")
        d = off + 110 + nsz
        d += (4 - d % 4) % 4
        nxt = d + fsz
        nxt += (4 - nxt % 4) % 4
        if name == TRAILER.decode():
            break
        if name in DROP:
            dropped.append(f"{name} ({fsz} B)")
        else:
            kept += cpio[off:nxt]
        off = nxt
    for x in dropped:
        print(f"  dropping {x}")

    add = cpio_entry("overlay.d/bootlog.rc", RC.encode(), 0o100750)
    add += cpio_entry(TRAILER.decode(), b"", 0)
    new_cpio = bytes(kept) + add

    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
        g.write(new_cpio)
    new_rd = buf.getvalue()

    ss = struct.unpack_from("<I", img, 24)[0]        # second_size
    rdtbo_sz = struct.unpack_from("<I", img, 1632)[0]  # recovery_dtbo_size
    dtb_sz = struct.unpack_from("<I", img, 1648)[0]

    # A recovery image stores recovery_dtbo_offset as an ABSOLUTE offset, so its
    # sections must not move. A boot image has no recovery_dtbo at all, which is
    # what makes rebuilding safe here.
    if rdtbo_sz != 0:
        print("ERROR: image has a recovery_dtbo section; its absolute offset "
              "would be invalidated. Use patch-recovery-adb.py instead.",
              file=sys.stderr)
        return 1

    up = lambda n: (n + ps - 1) // ps * ps
    print(f"ramdisk: {rs} -> {len(new_rd)} bytes "
          f"({up(rs) // ps} -> {up(len(new_rd)) // ps} pages)")

    if up(len(new_rd)) > up(rs):
        print(f"ERROR: ramdisk needs {up(len(new_rd)) // ps} pages, original had "
              f"{up(rs) // ps}. Growing it would overwrite the AVB blob that "
              f"starts immediately after the DTB. Refusing.", file=sys.stderr)
        return 1

    # The ramdisk may legitimately end up SMALLER (we dropped the AVB keys). It
    # is not enough to pad the section back to the original span: the bootloader
    # locates the DTB arithmetically, as
    #     page + align(kernel_size) + align(ramdisk_size) + align(second_size)
    # using the sizes in the HEADER. Declaring a smaller ramdisk while padding
    # the bytes would make it read the DTB a page early.
    #
    # So declare the padded length. Trailing zeros inside the ramdisk are
    # harmless -- gunzip stops at the end of the deflate stream and the initramfs
    # loader stops at the cpio TRAILER -- and padding to the original size keeps
    # every absolute offset after it exactly where it was.
    declared = max(len(new_rd), rs)
    new_rd = new_rd + b"\0" * (declared - len(new_rd))
    if declared != len(new_rd):
        raise AssertionError("padding arithmetic")

    # Carve the original sections out, then reassemble with the new ramdisk.
    k_off = ps
    r_off = k_off + up(ks)
    s_off = r_off + up(rs)
    d_off = s_off + up(ss)
    kernel = img[k_off:k_off + ks]
    second = img[s_off:s_off + ss]
    dtb = img[d_off:d_off + dtb_sz]

    out = bytearray(img[:ps])                    # header page, unchanged
    for blob in (kernel, new_rd, second, dtb):
        out += blob + b"\0" * (up(len(blob)) - len(blob))
    struct.pack_into("<I", out, 16, len(new_rd))

    # Everything after the sections -- the AVB vbmeta blob starts immediately at
    # the end of the DTB, with no gap -- is copied verbatim at its original
    # absolute position. That only works because the ramdisk kept its page
    # count; if it had grown, the blob would be overwritten.
    orig_end = d_off + up(dtb_sz)
    if len(out) != orig_end:
        print(f"ERROR: rebuilt sections end at {len(out)}, original at "
              f"{orig_end}. Tail would move. Refusing.", file=sys.stderr)
        return 1
    out += img[orig_end:]

    if len(out) != len(img):
        print("ERROR: image size changed -- refusing", file=sys.stderr)
        return 1

    open(dst, "wb").write(bytes(out))
    print(f"wrote {dst} ({len(out)} bytes, size unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
