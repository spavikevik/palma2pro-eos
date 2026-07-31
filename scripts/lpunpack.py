#!/usr/bin/env python3
"""Unpack an Android dynamic-partition (`super`) image into its logical partitions.

Stdlib only -- no pip, no pipx, no third-party package in the path of a firmware
dump. Structure layout follows AOSP's
system/core/fs_mgr/liblp/include/liblp/metadata_format.h

Usage:
    lpunpack.py super.img outdir            # all partitions
    lpunpack.py super.img outdir system     # named partitions only
    lpunpack.py --list super.img            # just show what's in there
"""

import argparse
import os
import struct
import sys

SECTOR_SIZE = 512
PARTITION_RESERVED_BYTES = 4096
GEOMETRY_SIZE = 4096

GEOMETRY_MAGIC = 0x616C4467  # 'gDla' little-endian
HEADER_MAGIC = 0x414C5030    # '0PLA' little-endian

TARGET_TYPE_LINEAR = 0
TARGET_TYPE_ZERO = 1


class LpError(Exception):
    pass


def read_geometry(f):
    f.seek(PARTITION_RESERVED_BYTES)
    blob = f.read(GEOMETRY_SIZE)
    magic, struct_size = struct.unpack_from("<II", blob, 0)
    if magic != GEOMETRY_MAGIC:
        raise LpError(
            f"no LP geometry magic at offset {PARTITION_RESERVED_BYTES} "
            f"(got 0x{magic:08x}). Image may be sparse -- run simg2img first."
        )
    # magic, struct_size, checksum[32], metadata_max_size,
    # metadata_slot_count, logical_block_size
    (metadata_max_size, metadata_slot_count, logical_block_size) = struct.unpack_from(
        "<III", blob, 4 + 4 + 32
    )
    return {
        "struct_size": struct_size,
        "metadata_max_size": metadata_max_size,
        "metadata_slot_count": metadata_slot_count,
        "logical_block_size": logical_block_size,
    }


def read_header(f, geometry, slot=0):
    # Primary metadata follows the reserved area and both geometry copies.
    base = PARTITION_RESERVED_BYTES + GEOMETRY_SIZE * 2
    offset = base + geometry["metadata_max_size"] * slot
    f.seek(offset)
    blob = f.read(geometry["metadata_max_size"])

    magic, major, minor, header_size = struct.unpack_from("<IHHI", blob, 0)
    if magic != HEADER_MAGIC:
        raise LpError(
            f"no LP header magic in metadata slot {slot} (got 0x{magic:08x})"
        )

    # magic(4) major(2) minor(2) header_size(4) header_checksum(32)
    # tables_size(4) tables_checksum(32) = 80, then four table descriptors.
    desc_off = 4 + 2 + 2 + 4 + 32 + 4 + 32

    def descriptor(i):
        off, num, entry_size = struct.unpack_from("<III", blob, desc_off + i * 12)
        return {"offset": off, "num_entries": num, "entry_size": entry_size}

    tables = {
        "partitions": descriptor(0),
        "extents": descriptor(1),
        "groups": descriptor(2),
        "block_devices": descriptor(3),
    }
    return {
        "version": (major, minor),
        "header_size": header_size,
        "tables": tables,
        "blob": blob,
    }


def parse_partitions(header):
    blob, t = header["blob"], header["tables"]["partitions"]
    base = header["header_size"] + t["offset"]
    out = []
    for i in range(t["num_entries"]):
        off = base + i * t["entry_size"]
        name = blob[off : off + 36].split(b"\x00", 1)[0].decode("utf-8", "replace")
        attributes, first_extent_index, num_extents, group_index = struct.unpack_from(
            "<IIII", blob, off + 36
        )
        out.append(
            {
                "name": name,
                "attributes": attributes,
                "first_extent_index": first_extent_index,
                "num_extents": num_extents,
                "group_index": group_index,
            }
        )
    return out


def parse_extents(header):
    blob, t = header["blob"], header["tables"]["extents"]
    base = header["header_size"] + t["offset"]
    out = []
    for i in range(t["num_entries"]):
        off = base + i * t["entry_size"]
        num_sectors, target_type, target_data, target_source = struct.unpack_from(
            "<QIQI", blob, off
        )
        out.append(
            {
                "num_sectors": num_sectors,
                "target_type": target_type,
                "target_data": target_data,
                "target_source": target_source,
            }
        )
    return out


def partition_size(part, extents):
    total = 0
    for i in range(part["num_extents"]):
        total += extents[part["first_extent_index"] + i]["num_sectors"] * SECTOR_SIZE
    return total


def extract(f, part, extents, dest, chunk=8 * 1024 * 1024):
    written = 0
    with open(dest, "wb") as out:
        for i in range(part["num_extents"]):
            e = extents[part["first_extent_index"] + i]
            length = e["num_sectors"] * SECTOR_SIZE

            if e["target_type"] == TARGET_TYPE_ZERO:
                remaining = length
                zeros = b"\x00" * min(chunk, remaining)
                while remaining > 0:
                    n = min(chunk, remaining)
                    out.write(zeros[:n])
                    remaining -= n
                written += length
                continue

            if e["target_type"] != TARGET_TYPE_LINEAR:
                raise LpError(f"unsupported extent target type {e['target_type']}")

            f.seek(e["target_data"] * SECTOR_SIZE)
            remaining = length
            while remaining > 0:
                buf = f.read(min(chunk, remaining))
                if not buf:
                    raise LpError(
                        f"unexpected EOF reading {part['name']} "
                        f"(short by {remaining} bytes) -- image may be truncated"
                    )
                out.write(buf)
                remaining -= len(buf)
            written += length
    return written


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("super_image")
    ap.add_argument("outdir", nargs="?")
    ap.add_argument("partitions", nargs="*", help="names to extract (default: all)")
    ap.add_argument("--list", action="store_true", help="list partitions and exit")
    ap.add_argument("--slot", type=int, default=0, help="metadata slot (default 0)")
    args = ap.parse_args()

    with open(args.super_image, "rb") as f:
        geometry = read_geometry(f)
        header = read_header(f, geometry, args.slot)
        parts = parse_partitions(header)
        extents = parse_extents(header)

        print(
            f"LP metadata v{header['version'][0]}.{header['version'][1]}, "
            f"{len(parts)} partitions, {len(extents)} extents, "
            f"block size {geometry['logical_block_size']}",
            file=sys.stderr,
        )

        if args.list or not args.outdir:
            for p in parts:
                print(f"{p['name']:<24} {human(partition_size(p, extents)):>12}"
                      f"  extents={p['num_extents']}")
            return 0

        wanted = set(args.partitions)
        os.makedirs(args.outdir, exist_ok=True)

        selected = [p for p in parts if not wanted or p["name"] in wanted]
        if wanted:
            missing = wanted - {p["name"] for p in selected}
            if missing:
                raise LpError(f"no such partition(s): {', '.join(sorted(missing))}")

        for p in selected:
            if p["num_extents"] == 0:
                print(f"  skip {p['name']} (no extents)", file=sys.stderr)
                continue
            dest = os.path.join(args.outdir, p["name"] + ".img")
            n = extract(f, p, extents, dest)
            print(f"  {p['name']:<24} -> {dest}  ({human(n)})", file=sys.stderr)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except LpError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
