#!/usr/bin/env python3
"""Generate synthetic Android boot images for tests.

Real images are 100 MB and live on a device; these are a few hundred KB and
reproduce the structural details that actually broke things:

  * header v2 layout, including `recovery_dtbo_offset` as an ABSOLUTE offset
  * an AVB vbmeta blob immediately after the DTB, with ZERO slack -- this is
    what makes the ramdisk page count a hard constraint
  * a Magisk-style ramdisk (overlay.d/, .backup/init.xz, avb/*.avbpubkey)

Usage:
    mkbootfixture.py <out.img> [--kind boot|recovery] [--no-avb-keys]
                     [--tight] [--no-default-prop]

  --kind recovery    non-zero recovery_dtbo_size (patchers must refuse to
                     rebuild sections for these)
  --no-avb-keys      omit avb/*.avbpubkey, so there is nothing to drop
  --tight            pad the ramdisk with incompressible data so its gzip lands
                     just under a page boundary; any addition then overflows
"""

import gzip
import io
import os
import struct
import sys

PAGE = 4096
CPIO_MAGIC = b"070701"


def cpio_entry(name, data, mode=0o100644):
    nb = name.encode() + b"\0"
    hdr = (CPIO_MAGIC + b"%08X" % 0 + b"%08X" % mode + b"%08X" % 0 + b"%08X" % 0
           + b"%08X" % 1 + b"%08X" % 0 + b"%08X" % len(data) + b"%08X" % 0 * 4
           + b"%08X" % len(nb) + b"%08X" % 0)
    out = hdr + nb
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\0" * ((4 - len(data) % 4) % 4)
    return out


def build_ramdisk(avb_keys=True, default_prop=True, tight=False):
    e = b""
    e += cpio_entry("dev", b"", 0o040755)
    e += cpio_entry("proc", b"", 0o040755)
    if default_prop:
        e += cpio_entry("default.prop",
                        b"ro.adb.secure=1\nro.debuggable=0\nro.secure=1\n")
    e += cpio_entry(".backup", b"", 0o040755)
    e += cpio_entry(".backup/init.xz", os.urandom(2048))
    e += cpio_entry("overlay.d", b"", 0o040755)
    e += cpio_entry("overlay.d/sbin", b"", 0o040755)
    e += cpio_entry("overlay.d/sbin/magisk.xz", os.urandom(4096))
    if avb_keys:
        e += cpio_entry("avb", b"", 0o040755)
        for k in ("q", "r", "s"):
            e += cpio_entry(f"avb/{k}-gsi.avbpubkey", os.urandom(1032))
    e += cpio_entry("filler", b"A" * 20000)
    e += cpio_entry("TRAILER!!!", b"", 0)

    def gz(payload):
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g:
            g.write(payload)
        return buf.getvalue()

    if not tight:
        return gz(e)

    # Grow with incompressible data until the gzip output sits just under a page
    # boundary, leaving less headroom than a small addition needs.
    pad = 0
    while True:
        cand = e[:e.rfind(CPIO_MAGIC)] \
             + cpio_entry("incompressible", os.urandom(pad)) \
             + cpio_entry("TRAILER!!!", b"", 0)
        out = gz(cand)
        slack = (-len(out)) % PAGE
        if 0 < slack < 200:
            return out
        pad += 512
        if pad > 400000:
            return out


def main():
    out_path = sys.argv[1]
    kind = "boot"
    if "--kind" in sys.argv:
        kind = sys.argv[sys.argv.index("--kind") + 1]
    ramdisk = build_ramdisk(avb_keys="--no-avb-keys" not in sys.argv,
                            default_prop="--no-default-prop" not in sys.argv,
                            tight="--tight" in sys.argv)
    kernel = b"\xaa" * 8192
    dtb = b"\xd0\x0d\xfe\xed" + b"\xbb" * 4092

    up = lambda n: (n + PAGE - 1) // PAGE * PAGE
    hdr = bytearray(PAGE)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<I", hdr, 8, len(kernel))
    struct.pack_into("<I", hdr, 16, len(ramdisk))
    struct.pack_into("<I", hdr, 24, 0)              # second_size
    struct.pack_into("<I", hdr, 36, PAGE)
    struct.pack_into("<I", hdr, 40, 2)              # header_version
    cmdline = (b"console=ttyMSM0,115200,n8 androidboot.hardware=qcom "
               b"buildvariant=user")
    hdr[64:64 + len(cmdline)] = cmdline
    struct.pack_into("<I", hdr, 1644, 1660)         # header_size
    struct.pack_into("<I", hdr, 1648, len(dtb))

    body = bytearray()
    for blob in (kernel, ramdisk, b"", dtb):
        if not blob:
            continue
        body += blob + b"\0" * (up(len(blob)) - len(blob))

    if kind == "recovery":
        # Non-zero recovery_dtbo, and the ABSOLUTE offset that made shifting
        # sections fatal on the real device.
        rdtbo = b"\xcc" * 1024
        struct.pack_into("<I", hdr, 1632, len(rdtbo))
        struct.pack_into("<Q", hdr, 1636, PAGE + len(body))
        body += rdtbo + b"\0" * (up(len(rdtbo)) - len(rdtbo))

    # AVB vbmeta immediately after the sections: no slack, by design.
    avb = b"AVB0" + b"\0" * 12 + os.urandom(1024)
    image = bytes(hdr) + bytes(body) + avb
    image += b"\0" * (up(len(image)) - len(image))

    with open(out_path, "wb") as f:
        f.write(image)
    print(f"{out_path}: {len(image)} bytes, ramdisk={len(ramdisk)} "
          f"({up(len(ramdisk)) // PAGE} pages), kind={kind}")


if __name__ == "__main__":
    main()
