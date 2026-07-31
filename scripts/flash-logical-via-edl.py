#!/usr/bin/env python3
"""Write an image into a logical partition's extents over EDL.

Onyx's fastbootd accepts delete/create/resize of logical partitions but REJECTS
`flash` ("Unrecognized command flash"), so images have to be written as raw
sectors through EDL instead. A logical partition is a list of extents inside
`super`, so the image must be split to match and each piece written at the right
absolute device sector.

Extent offsets from `lpdump` are in 512-byte units and relative to `super`;
EDL's `ws` takes the device's own 4096-byte sectors, absolute. Hence:

    device_sector = (SUPER_OFFSET + extent_offset_512 * 512) / 4096

Usage:
    flash-logical-via-edl.py <image> <lpdump.txt> <partition_name> [--go]

Without --go it only prints the plan.
"""

import os
import re
import subprocess
import sys

SUPER_OFFSET = 0x0b208000       # from GPT: super partition start, in bytes
SECTOR = 4096                   # device logical block size (UFS)
LOADER = "firmware/palma2pro-firehose.bin"


def extents_for(lpdump_path: str, part: str):
    """Pull (offset_512, length_512) pairs for one partition out of lpdump output."""
    out, inside = [], False
    for line in open(lpdump_path):
        if re.search(rf"Name:\s+{re.escape(part)}\s*$", line):
            inside = True
            continue
        if inside:
            if line.strip().startswith("---"):
                break
            m = re.match(r"\s*(\d+)\s*\.\.\s*(\d+)\s+linear\s+super\s+(\d+)", line)
            if m:
                start, end, phys = (int(x) for x in m.groups())
                out.append((phys, end - start + 1))
    return out


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    image, lpdump, part = sys.argv[1], sys.argv[2], sys.argv[3]
    go = "--go" in sys.argv

    ext = extents_for(lpdump, part)
    if not ext:
        print(f"no extents found for {part}", file=sys.stderr)
        return 1

    total = sum(l for _, l in ext) * 512
    size = os.path.getsize(image)
    print(f"{part}: {len(ext)} extents, {total} bytes; image is {size} bytes")
    if size > total:
        print("image LARGER than partition -- refusing", file=sys.stderr)
        return 1

    plan, img_off = [], 0
    for i, (phys512, len512) in enumerate(ext, 1):
        byte_off = SUPER_OFFSET + phys512 * 512
        nbytes = len512 * 512
        if byte_off % SECTOR or nbytes % SECTOR:
            print(f"  extent {i} not {SECTOR}-aligned -- refusing", file=sys.stderr)
            return 1
        take = min(nbytes, max(0, size - img_off))
        plan.append((i, byte_off // SECTOR, img_off, take))
        print(f"  ext{i}: sector={byte_off // SECTOR:<9} bytes={nbytes:<12} "
              f"image[{img_off}:{img_off + take}]")
        img_off += nbytes

    if not go:
        print("\nplan only -- pass --go to write")
        return 0

    for i, sector, off, take in plan:
        if take <= 0:
            print(f"  ext{i}: past end of image, skipping")
            continue
        piece = f"/tmp/_ext{i}.bin"
        with open(image, "rb") as src, open(piece, "wb") as dst:
            src.seek(off)
            remaining = take
            while remaining:
                buf = src.read(min(8 << 20, remaining))
                if not buf:
                    break
                dst.write(buf)
                remaining -= len(buf)
        # Pad the tail piece so the write covers whole sectors.
        pad = (-os.path.getsize(piece)) % SECTOR
        if pad:
            open(piece, "ab").write(b"\0" * pad)
        print(f"  writing ext{i} -> sector {sector} ({os.path.getsize(piece)} bytes)")
        r = subprocess.run(["edl", "ws", str(sector), piece,
                            f"--loader={LOADER}", "--memory=ufs", "--lun=0"],
                           capture_output=True, text=True)
        ok = "Wrote" in r.stdout
        print("   ", "OK" if ok else "FAILED")
        os.unlink(piece)
        if not ok:
            print(r.stdout[-500:], r.stderr[-500:], file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
