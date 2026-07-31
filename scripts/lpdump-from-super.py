#!/usr/bin/env python3
"""Print lpdump-style extents by parsing LP metadata out of a raw `super` dump.

    lpdump-from-super.py <super-head.bin> [--slot N]

WHY THIS EXISTS
---------------
`scripts/flash-logical-via-edl.py` needs each partition's extents, and normally
you get those from `lpdump` on a booted device. After deleting and recreating a
logical partition in fastbootd there IS no bootable system to run lpdump on --
recreating `product_b` leaves it raw, so Android cannot mount /product.

So read the metadata directly. Only the first ~1 MiB of `super` is needed:

    edl rs 45576 256 super-head.bin --lun=0     # 45576 = 0x0b208000 / 4096

Output is deliberately in `lpdump`'s shape so flash-logical-via-edl.py consumes
it unchanged:

      Name: product_b
        0 .. 1835007 linear super 221192
      ------------------------

LAYOUT (same constants lpunpack.py uses, verified against this device)
  geometry at 4096, header at 12288; partition/extent tables follow the header.
"""

import struct
import sys

GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
METADATA_SLOT_SIZE_OFFSET = GEOMETRY_OFFSET + 40


def parse(path, slot):
    d = open(path, "rb").read()

    if d[GEOMETRY_OFFSET:GEOMETRY_OFFSET + 4] != b"\x67\x44\x6c\x61":  # 'gDla'
        # magic is 0x616c4467 little-endian
        magic = struct.unpack_from("<I", d, GEOMETRY_OFFSET)[0]
        if magic != 0x616C4467:
            print(f"ERROR: no LP geometry magic at {GEOMETRY_OFFSET} "
                  f"(got 0x{magic:08x})", file=sys.stderr)
            return 1

    # LpMetadataGeometry: magic(0) struct_size(4) checksum[32](8..39)
    #                     metadata_max_size(40) metadata_slot_count(44)
    metadata_max_size, metadata_slot_count = struct.unpack_from(
        "<II", d, GEOMETRY_OFFSET + 40)

    # Primary metadata starts after geometry (2 copies of 4 KiB).
    base = GEOMETRY_OFFSET + 2 * GEOMETRY_SIZE + slot * metadata_max_size

    hdr_magic, major, minor, hdr_size = struct.unpack_from("<IHHI", d, base)
    if hdr_magic != 0x414C5030:  # 'AL P0' -> LP_METADATA_HEADER_MAGIC
        print(f"ERROR: bad metadata header magic 0x{hdr_magic:08x} at {base} "
              f"(slot {slot})", file=sys.stderr)
        return 1

    # tables_size at 0x50; each table descriptor is offset/num/entry_size
    def table(off):
        o, n, sz = struct.unpack_from("<III", d, base + off)
        return base + hdr_size + o, n, sz

    # LpMetadataHeader: ... tables_size(44) tables_checksum[32](48..79)
    #                   partitions(80=0x50) extents(92=0x5C) groups(104) devices(116)
    part_off, part_num, part_sz = table(0x50)
    ext_off, ext_num, ext_sz = table(0x5C)

    print(f"# LP metadata v{major}.{minor}, slot {slot}, "
          f"{part_num} partitions, {ext_num} extents", file=sys.stderr)

    for i in range(part_num):
        p = part_off + i * part_sz
        name = d[p:p + 36].split(b"\0")[0].decode("utf-8", "replace")
        first_extent, num_extents = struct.unpack_from("<II", d, p + 40)
        print(f"  Name: {name}")
        sector = 0
        for e in range(first_extent, first_extent + num_extents):
            eo = ext_off + e * ext_sz
            num_sectors, target_type, target_data = struct.unpack_from(
                "<QIQ", d, eo)
            # target_type 0 == LINEAR
            if target_type == 0:
                print(f"    {sector} .. {sector + num_sectors - 1} "
                      f"linear super {target_data}")
            sector += num_sectors
        print("  ------------------------")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    slot = 0
    if "--slot" in sys.argv:
        slot = int(sys.argv[sys.argv.index("--slot") + 1])
    return parse(sys.argv[1], slot)


if __name__ == "__main__":
    sys.exit(main())
