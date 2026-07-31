#!/usr/bin/env python3
"""Grow a logical partition by rewriting LP metadata in a raw `super` head.

    lp-resize-partition.py <super-head.bin> <partition> <new-size-bytes> \
                           --slot N -o <out.bin>

WHY THIS EXISTS
---------------
The supported way to resize a logical partition is
`fastboot resize-logical-partition`, which this device's fastbootd does accept.
But fastbootd is reached with `adb reboot fastboot`, and that needs a system
that boots. During bring-up there isn't one -- the device holds a non-booting
build and the only channel is EDL. So the same edit is done here, offline, on a
dump of super's head, and written back with `edl ws`.

Nothing is guessed: the result is verified with the real `lpdump` host binary
before it goes near the device (see docs/08-lp-resize.md).

WHAT IT DOES
------------
Appends a LINEAR extent, taken from unallocated space at the tail of `super`,
to the named partition until it reaches at least the requested size.

The extents table is REBUILT rather than patched in place. Each partition points
at a contiguous run of extents via first_extent_index/num_extents, so inserting
one extent in the middle would shift the indices of every later partition. This
regenerates the whole table in partition order and recomputes every index, which
is both simpler and harder to get subtly wrong.

Both metadata copies (primary and backup) of every slot are updated, because
liblp will fall back to the backup and a half-patched super is worse than an
unpatched one.

LAYOUT
------
geometry at 4096 (backup at 8192), metadata slots from 12288, each
metadata_max_size bytes; slot_count primaries followed by slot_count backups.
Checksums are SHA256, not CRC32.
"""

import hashlib
import struct
import sys

GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
GEOMETRY_MAGIC = 0x616C4467
HEADER_MAGIC = 0x414C5030
SECTOR = 512

# LpMetadataHeader field offsets
H_HEADER_SIZE = 8
H_HEADER_CSUM = 12          # 32 bytes
H_TABLES_SIZE = 44
H_TABLES_CSUM = 48          # 32 bytes
H_PARTITIONS = 0x50
H_EXTENTS = 0x5C
H_GROUPS = 104
H_DEVICES = 116


def die(msg):
    print(f"lp-resize: {msg}", file=sys.stderr)
    sys.exit(1)


def read_geometry(d):
    magic, struct_size = struct.unpack_from("<II", d, GEOMETRY_OFFSET)
    if magic != GEOMETRY_MAGIC:
        die(f"no LP geometry magic at {GEOMETRY_OFFSET} (got 0x{magic:08x})")
    max_size, slot_count, block_size = struct.unpack_from(
        "<III", d, GEOMETRY_OFFSET + 40)
    return max_size, slot_count, block_size


def descriptor(d, base, off):
    return struct.unpack_from("<III", d, base + off)   # offset, num, entry_size


def parse_metadata(d, base):
    magic, major, minor, hdr_size = struct.unpack_from("<IHHI", d, base)
    if magic != HEADER_MAGIC:
        return None
    tables_size = struct.unpack_from("<I", d, base + H_TABLES_SIZE)[0]
    return {
        "base": base, "major": major, "minor": minor,
        "hdr_size": hdr_size, "tables_size": tables_size,
        "partitions": descriptor(d, base, H_PARTITIONS),
        "extents": descriptor(d, base, H_EXTENTS),
        "groups": descriptor(d, base, H_GROUPS),
        "devices": descriptor(d, base, H_DEVICES),
    }


def entries(d, m, which):
    off, num, sz = m[which]
    start = m["base"] + m["hdr_size"] + off
    return [bytearray(d[start + i * sz: start + (i + 1) * sz]) for i in range(num)], sz


def part_name(e):
    return bytes(e[:36]).split(b"\0")[0].decode("utf-8", "replace")


def extent_fields(e):
    num_sectors, target_type, target_data = struct.unpack_from("<QIQ", e, 0)
    return num_sectors, target_type, target_data


def device_size_sectors(d, m):
    devs, sz = entries(d, m, "devices")
    if not devs:
        die("no block devices in metadata")
    # LpMetadataBlockDevice: first_logical_sector(0,u64) alignment(8,u32)
    # alignment_offset(12,u32) size(16,u64) partition_name[36](24) flags(60,u32)
    # `alignment` is u32, not u64 -- reading size at 20 yields garbage.
    dev = devs[0]
    first_logical = struct.unpack_from("<Q", dev, 0)[0]
    size = struct.unpack_from("<Q", dev, 16)[0]
    if size % SECTOR or size < (1 << 30):
        die(f"block device size looks wrong: {size}")
    return first_logical, size // SECTOR


def patch_slot(d, base, target, new_size_bytes, verbose):
    m = parse_metadata(d, base)
    if m is None:
        return None
    parts, psz = entries(d, m, "partitions")
    exts, esz = entries(d, m, "extents")
    groups_blob = d[m["base"] + m["hdr_size"] + m["groups"][0]:
                    m["base"] + m["hdr_size"] + m["groups"][0]
                    + m["groups"][1] * m["groups"][2]]
    devs_blob = d[m["base"] + m["hdr_size"] + m["devices"][0]:
                  m["base"] + m["hdr_size"] + m["devices"][0]
                  + m["devices"][1] * m["devices"][2]]

    first_logical, dev_sectors = device_size_sectors(d, m)

    # Per-partition extent lists, in table order.
    plan = []
    idx = None
    for i, p in enumerate(parts):
        first, num = struct.unpack_from("<II", p, 40)
        plan.append(list(exts[first:first + num]))
        if part_name(p) == target:
            idx = i
    if idx is None:
        die(f"partition {target!r} not found "
            f"(have: {', '.join(part_name(p) for p in parts)})")

    cur = sum(extent_fields(e)[0] for e in plan[idx])
    want = (new_size_bytes + SECTOR - 1) // SECTOR
    if want <= cur:
        if verbose:
            print(f"  {target}: already {cur * SECTOR} bytes, nothing to do")
        return None
    need = want - cur

    # Allocate from the tail: highest sector used by any LINEAR extent onward.
    high = first_logical
    for lst in plan:
        for e in lst:
            n, t, data = extent_fields(e)
            if t == 0:
                high = max(high, data + n)
    align = 8                                  # 4096-byte logical blocks
    start = (high + align - 1) // align * align
    need = (need + align - 1) // align * align
    free = dev_sectors - start
    if need > free:
        die(f"need {need} sectors, only {free} free at tail "
            f"({free * SECTOR} bytes)")

    # Group limit. liblp enforces this when a partition is resized through the
    # normal path, but nothing re-checks it when metadata is written directly --
    # lpdump will happily print an over-committed group.
    # LpMetadataPartitionGroup: name[36], 4 bytes PADDING, maximum_size(40, u64)
    # -- entry_size 48, not 44. These structs carry natural alignment padding
    # rather than being packed, which also moved LpMetadataBlockDevice.size.
    # Reading maximum_size at 36 yields 9205357638345293824; at 40 it is
    # 6438256640, matching lpdump.
    # LpMetadataPartition: name[36], attributes(36), first_extent(40),
    #                      num_extents(44), group_index(48) -- 52 bytes.
    groups, gsz = entries(d, m, "groups")
    gidx = struct.unpack_from("<I", parts[idx], 48)[0]
    if gidx < len(groups):
        gmax = struct.unpack_from("<Q", groups[gidx], 40)[0]
        gname = part_name(groups[gidx])
        if gmax:
            used = 0
            for i, p in enumerate(parts):
                if struct.unpack_from("<I", p, 48)[0] == gidx:
                    used += sum(extent_fields(e)[0] for e in plan[i])
            after = (used + need) * SECTOR
            if after > gmax:
                die(f"group {gname!r} would hold {after} bytes, "
                    f"over its maximum {gmax}")
            if verbose:
                print(f"  group {gname}: {used * SECTOR} -> {after} bytes "
                      f"(max {gmax})")

    new_ext = bytearray(esz)
    struct.pack_into("<QIQ", new_ext, 0, need, 0, start)
    if esz >= 24:
        struct.pack_into("<I", new_ext, 20, 0)   # target_source = device 0
    plan[idx].append(new_ext)

    if verbose:
        print(f"  {target}: {cur} -> {cur + need} sectors "
              f"({cur * SECTOR} -> {(cur + need) * SECTOR} bytes)")
        print(f"  new extent: {need} sectors @ physical {start} "
              f"(tail had {free} free)")

    # Rebuild tables.
    new_exts, cursor = [], 0
    for i, p in enumerate(parts):
        struct.pack_into("<II", p, 40, cursor, len(plan[i]))
        new_exts.extend(plan[i])
        cursor += len(plan[i])

    parts_blob = b"".join(bytes(p) for p in parts)
    exts_blob = b"".join(bytes(e) for e in new_exts)
    tables = parts_blob + exts_blob + groups_blob + devs_blob

    hdr = bytearray(d[base:base + m["hdr_size"]])
    off = 0
    for field, num, sz in (
            (H_PARTITIONS, len(parts), psz),
            (H_EXTENTS, len(new_exts), esz),
            (H_GROUPS, m["groups"][1], m["groups"][2]),
            (H_DEVICES, m["devices"][1], m["devices"][2])):
        struct.pack_into("<III", hdr, field, off, num, sz)
        off += num * sz

    struct.pack_into("<I", hdr, H_TABLES_SIZE, len(tables))
    hdr[H_TABLES_CSUM:H_TABLES_CSUM + 32] = hashlib.sha256(tables).digest()
    hdr[H_HEADER_CSUM:H_HEADER_CSUM + 32] = b"\0" * 32
    hdr[H_HEADER_CSUM:H_HEADER_CSUM + 32] = hashlib.sha256(hdr).digest()

    return bytes(hdr) + tables


def main():
    args = list(sys.argv[1:])
    if "-o" not in args or "--slot" not in args or len(args) < 7:
        print(__doc__)
        return 2
    out = args[args.index("-o") + 1]
    target_slot = int(args[args.index("--slot") + 1])
    flagged = set()
    for f in ("-o", "--slot"):
        i = args.index(f)
        flagged.add(i)
        flagged.add(i + 1)
    pos = [a for i, a in enumerate(args) if i not in flagged]
    src, target, new_size = pos[0], pos[1], int(pos[2])

    d = bytearray(open(src, "rb").read())
    max_size, slot_count, block_size = read_geometry(d)
    print(f"geometry: max_size={max_size} slots={slot_count} "
          f"block_size={block_size}")

    meta_base = GEOMETRY_OFFSET + 2 * GEOMETRY_SIZE
    need_bytes = meta_base + max_size * slot_count * 2
    if len(d) < need_bytes:
        die(f"input is {len(d)} bytes, need at least {need_bytes} "
            f"(dump more of super)")

    # Only ONE slot is patched, and it must be named explicitly.
    #
    # The metadata slot tracks the boot slot: booting _b uses metadata slot 1.
    # On this device slots 0 and 2 still describe the original 10-partition A/B
    # layout (odm_a, product_a, ...) while slot 1 is the live 5-partition one.
    # Patching all three would grow product_b inside layouts that are not in use,
    # and would fail or misallocate where their free space differs.
    want_slots = [target_slot] if target_slot is not None else []
    patched = 0
    for slot in want_slots:
        if slot >= slot_count:
            die(f"slot {slot} >= slot_count {slot_count}")
        primary = meta_base + slot * max_size
        backup = meta_base + max_size * slot_count + slot * max_size
        blob = None
        for label, base in (("primary", primary), ("backup", backup)):
            if parse_metadata(d, base) is None:
                print(f"slot {slot} {label}: no valid header, skipped")
                continue
            print(f"slot {slot} {label} @ 0x{base:x}:")
            b = patch_slot(d, base, target, new_size, verbose=(blob is None))
            if b is None:
                continue
            if len(b) > max_size:
                die(f"patched metadata {len(b)} > metadata_max_size {max_size}")
            d[base:base + len(b)] = b
            d[base + len(b):base + max_size] = b"\0" * (max_size - len(b))
            blob = b
            patched += 1

    if not patched:
        die("nothing was patched")
    open(out, "wb").write(bytes(d))
    print(f"\npatched {patched} metadata copies -> {out} ({len(d)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
