#!/usr/bin/env python3
"""Build a synthetic `super` head with valid LP metadata, for tests.

    mklpfixture.py <out.bin> [--slot1-full]

Modelled on the real device: metadata v10.2, header_size 256, entry sizes
52/24/48/64, geometry at 4096, three slots from 12288 with backups after them.
Deliberately synthetic rather than a slice of firmware/super.img, so the suite
runs with no 6.4 GB dump present.

Layout (1 GiB device, so the numbers stay readable):

    slot 0/2   alpha  200 MiB, beta 100 MiB, free tail
    slot 1     same, plus a *-cow partition covering the tail when --slot1-full,
               which is how the stale Jul-29 dump looks and must be refused
"""

import hashlib
import struct
import sys

GEO_OFF, GEO_SIZE = 4096, 4096
GEO_MAGIC, HDR_MAGIC = 0x616C4467, 0x414C5030
MAX_SIZE, SLOTS, BLOCK = 65536, 3, 4096
HDR_SIZE = 256
P_SZ, E_SZ, G_SZ, D_SZ = 52, 24, 48, 64
SECTOR = 512
DEV_SECTORS = (1 << 30) // SECTOR          # 1 GiB
FIRST_LOGICAL = 2048


def name36(s):
    b = s.encode()
    assert len(b) <= 36
    return b + b"\0" * (36 - len(b))


def geometry():
    g = bytearray(52)
    struct.pack_into("<II", g, 0, GEO_MAGIC, 52)
    struct.pack_into("<III", g, 40, MAX_SIZE, SLOTS, BLOCK)
    g[8:40] = hashlib.sha256(bytes(g)).digest()
    return bytes(g) + b"\0" * (GEO_SIZE - 52)


def metadata(partitions, groups):
    """partitions: [(name, group_index, [(num_sectors, phys_sector), ...])]"""
    parts, exts = b"", b""
    cursor = 0
    for nm, gidx, extents in partitions:
        p = bytearray(P_SZ)
        p[:36] = name36(nm)
        struct.pack_into("<IIII", p, 36, 0, cursor, len(extents), gidx)
        parts += bytes(p)
        for num, phys in extents:
            e = bytearray(E_SZ)
            struct.pack_into("<QIQ", e, 0, num, 0, phys)   # 0 = LINEAR
            struct.pack_into("<I", e, 20, 0)
            exts += bytes(e)
        cursor += len(extents)

    grp = b""
    for nm, maximum in groups:
        g = bytearray(G_SZ)
        g[:36] = name36(nm)
        struct.pack_into("<Q", g, 40, maximum)            # 40, not 36
        grp += bytes(g)

    dev = bytearray(D_SZ)
    struct.pack_into("<Q", dev, 0, FIRST_LOGICAL)
    struct.pack_into("<II", dev, 8, 1048576, 0)
    struct.pack_into("<Q", dev, 16, DEV_SECTORS * SECTOR)  # 16, not 20
    dev[24:60] = name36("super")
    dev = bytes(dev)

    tables = parts + exts + grp + dev
    hdr = bytearray(HDR_SIZE)
    struct.pack_into("<IHHI", hdr, 0, HDR_MAGIC, 10, 2, HDR_SIZE)
    struct.pack_into("<I", hdr, 44, len(tables))
    off = 0
    for field, num, sz in ((0x50, len(parts) // P_SZ, P_SZ),
                           (0x5C, len(exts) // E_SZ, E_SZ),
                           (104, len(grp) // G_SZ, G_SZ),
                           (116, 1, D_SZ)):
        struct.pack_into("<III", hdr, field, off, num, sz)
        off += num * sz
    struct.pack_into("<I", hdr, 128, 1)                    # virtual_ab_device
    hdr[48:80] = hashlib.sha256(tables).digest()
    hdr[12:44] = b"\0" * 32
    hdr[12:44] = hashlib.sha256(bytes(hdr)).digest()
    return bytes(hdr) + tables


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    out = sys.argv[1]
    slot1_full = "--slot1-full" in sys.argv

    groups = [("default", 0), ("grp", 600 << 20)]
    mib = (1 << 20) // SECTOR

    alpha_end = FIRST_LOGICAL + 200 * mib
    normal = [
        ("alpha", 1, [(200 * mib, FIRST_LOGICAL)]),
        ("beta", 1, [(100 * mib, alpha_end)]),
    ]
    beta_end = alpha_end + 100 * mib
    full = normal + [("alpha-cow", 1, [(DEV_SECTORS - beta_end, beta_end)])]

    d = bytearray(GEO_OFF + 2 * GEO_SIZE + MAX_SIZE * SLOTS * 2)
    d[GEO_OFF:GEO_OFF + GEO_SIZE] = geometry()
    d[GEO_OFF + GEO_SIZE:GEO_OFF + 2 * GEO_SIZE] = geometry()

    base = GEO_OFF + 2 * GEO_SIZE
    for slot in range(SLOTS):
        parts = full if (slot == 1 and slot1_full) else normal
        blob = metadata(parts, groups)
        assert len(blob) <= MAX_SIZE
        for o in (base + slot * MAX_SIZE,
                  base + MAX_SIZE * SLOTS + slot * MAX_SIZE):
            d[o:o + len(blob)] = blob

    open(out, "wb").write(bytes(d))
    print(f"wrote {out} ({len(d)} bytes), slot1_full={slot1_full}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
