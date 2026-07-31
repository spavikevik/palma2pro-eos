#!/usr/bin/env python3
"""Patch the recovery image so adb is usable for debugging a failed boot.

Why: when the /e/OS GSI failed, the device landed in Onyx's recovery with
`adb devices` reporting *unauthorized*, so no logs could be pulled -- we were
diagnosing blind. Recovery's `default.prop` sets `ro.adb.secure=1`.

What this does: appends a small cpio to the recovery ramdisk containing

    default.prop / prop.default   with ro.adb.secure=0, ro.debuggable=1
    adb_keys                      the host's public key (belt and braces)

The Linux initramfs loader extracts concatenated cpio archives in order and
later entries overwrite earlier ones, so appending is enough -- no need to
unpack and rebuild the original archive. That matters: unpacking as a non-root
user would silently rewrite every file's uid/gid to the invoking user and break
recovery.

Usage:
    patch-recovery-adb.py <recovery.img> <out.img> [adbkey.pub]
"""

import gzip
import io
import os
import struct
import sys

CPIO_MAGIC = b"070701"
TRAILER = b"TRAILER!!!"


def cpio_entry(name: str, data: bytes, mode: int) -> bytes:
    """One newc-format cpio record, owned by root."""
    name_b = name.encode() + b"\0"
    hdr = (
        CPIO_MAGIC
        + b"%08X" % 0            # ino
        + b"%08X" % mode
        + b"%08X" % 0            # uid  (root)
        + b"%08X" % 0            # gid  (root)
        + b"%08X" % 1            # nlink
        + b"%08X" % 0            # mtime
        + b"%08X" % len(data)
        + b"%08X" % 0 * 4        # devmajor/minor, rdevmajor/minor
        + b"%08X" % len(name_b)
        + b"%08X" % 0            # check
    )
    out = hdr + name_b
    out += b"\0" * ((4 - len(out) % 4) % 4)      # pad name to 4 bytes
    out += data
    out += b"\0" * ((4 - len(data) % 4) % 4)     # pad data to 4 bytes
    return out


def strip_trailer(cpio: bytes) -> bytes:
    """Drop the original archive's TRAILER!!! record so ours can follow."""
    i = cpio.rfind(TRAILER)
    if i < 0:
        return cpio
    start = cpio.rfind(CPIO_MAGIC, 0, i)
    return cpio[:start] if start >= 0 else cpio


def read_member(cpio: bytes, want: str):
    """Pull one file's contents out of a newc archive."""
    off = 0
    while off + 110 <= len(cpio):
        if cpio[off:off + 6] != CPIO_MAGIC:
            break
        f = lambda n: int(cpio[off + 6 + n * 8: off + 14 + n * 8], 16)
        filesize, namesize = f(6), f(11)
        name = cpio[off + 110: off + 110 + namesize - 1].decode("utf-8", "replace")
        dstart = off + 110 + namesize
        dstart += (4 - dstart % 4) % 4
        if name == TRAILER.decode():
            break
        if name == want:
            return cpio[dstart:dstart + filesize]
        off = dstart + filesize
        off += (4 - off % 4) % 4
    return None


def fix_props(text: str) -> str:
    out = []
    seen = set()
    for line in text.splitlines():
        for k, v in (("ro.adb.secure", "0"), ("ro.debuggable", "1"), ("ro.secure", "0")):
            if line.startswith(k + "="):
                line = f"{k}={v}"
                seen.add(k)
        out.append(line)
    for k, v in (("ro.adb.secure", "0"), ("ro.debuggable", "1")):
        if k not in seen:
            out.append(f"{k}={v}")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    pub = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser("~/.android/adbkey.pub")

    img = open(src, "rb").read()
    if img[:8] != b"ANDROID!":
        print("not an Android boot image", file=sys.stderr)
        return 1

    ks, rs, ps = (struct.unpack_from("<I", img, o)[0] for o in (8, 16, 36))
    hv = struct.unpack_from("<I", img, 40)[0]
    ko = ps
    ro = ((ko + ks) + ps - 1) // ps * ps
    print(f"header v{hv} page={ps} kernel={ks} ramdisk={rs}")

    cpio = gzip.decompress(img[ro:ro + rs])
    print(f"ramdisk cpio: {len(cpio)} bytes")

    add = b""
    for pf in ("default.prop", "prop.default"):
        cur = read_member(cpio, pf)
        if cur is None:
            continue
        patched = fix_props(cur.decode("utf-8", "replace")).encode()
        add += cpio_entry(pf, patched, 0o100644)
        print(f"  overriding {pf} (ro.adb.secure=0, ro.debuggable=1)")

    if os.path.exists(pub):
        add += cpio_entry("adb_keys", open(pub, "rb").read(), 0o100644)
        print(f"  adding adb_keys from {pub}")

    add += cpio_entry(TRAILER.decode(), b"", 0)
    new_cpio = strip_trailer(cpio) + add

    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
        g.write(new_cpio)
    new_rd = buf.getvalue()
    print(f"new ramdisk: {len(new_rd)} bytes (was {rs})")

    # Rebuild. CRITICAL: the ramdisk section must keep the SAME page count as
    # the original.
    #
    # A boot image header v1+ stores `recovery_dtbo_offset` as an ABSOLUTE byte
    # offset into the image. If the ramdisk section changes size, everything
    # after it shifts, that offset becomes stale, and the bootloader reads
    # garbage where the DTBO should be -- the device then fails to boot recovery
    # with no diagnostic at all. (Learned the hard way: the first attempt
    # produced a 2047-page ramdisk where the original was 2048, and recovery
    # simply hung.)
    #
    # Padding the section back to its original page span keeps every downstream
    # absolute offset valid, so only `ramdisk_size` in the header changes.
    orig_pages = (rs + ps - 1) // ps
    new_pages = (len(new_rd) + ps - 1) // ps
    if new_pages > orig_pages:
        print(f"ERROR: new ramdisk needs {new_pages} pages, original had "
              f"{orig_pages}. Shifting later sections would invalidate "
              f"recovery_dtbo_offset. Refusing.", file=sys.stderr)
        return 1

    # Padding the SECTION is not sufficient on its own: the bootloader locates
    # every later section arithmetically from the sizes in the header, as
    #     page + align(kernel_size) + align(ramdisk_size) + ...
    # so a ramdisk that shrank would make it read the following section a page
    # early even though the bytes were padded. Declare the padded length instead;
    # trailing zeros are ignored (gunzip stops at the stream end, the initramfs
    # loader stops at the cpio TRAILER).
    declared = max(len(new_rd), rs)
    new_rd = new_rd + b"\0" * (declared - len(new_rd))

    out = bytearray(img[:ro])
    out += new_rd
    out += b"\0" * (orig_pages * ps - len(new_rd))     # pad to original span
    tail_src = ro + orig_pages * ps
    out += img[tail_src:]
    struct.pack_into("<I", out, 16, len(new_rd))
    print(f"ramdisk section: {new_pages} pages of data, padded to {orig_pages} "
          f"(unchanged) -- downstream offsets preserved")

    open(dst, "wb").write(bytes(out))
    print(f"wrote {dst} ({len(out)} bytes)")
    if len(out) > len(img):
        print("WARNING: image grew; confirm it still fits the recovery partition")
    return 0


if __name__ == "__main__":
    sys.exit(main())
