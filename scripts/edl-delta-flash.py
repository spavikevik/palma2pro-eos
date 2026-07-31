#!/usr/bin/env python3
"""Flash only the sectors that changed between two partition images.

    edl-delta-flash.py <old.img> <new.img> <lpdump.txt> <partition> [--go]
                       [--max-pct N]

WHY
---
A full system_b write is 1.5 GB over EDL: a couple of minutes, plus the
reboot-to-EDL either side. Most iterations on this port change one library.
Diffing the images at 4096-byte granularity and writing only the differing
sectors turns that into seconds.

Diffing IMAGES rather than computing a file's ext4 extents is deliberate: it
picks up the inode, block-bitmap and group-descriptor updates that come with a
changed file, without having to reason about any of them. Whatever mkfs/debugfs
did, the diff sees it.

REQUIREMENTS
------------
`old.img` must be byte-identical to what is actually on the device. Keep the
last flashed image around and pass it here. If in doubt, do a full flash and
start again -- a wrong baseline writes the wrong sectors, and ext4 will not
necessarily notice immediately.

The two images must be the same size (same filesystem geometry). A rebuild that
changes the image size needs a full flash.

Sector mapping is the same arithmetic as flash-logical-via-edl.py:
    device_sector = (SUPER_OFFSET + extent_offset_512 * 512) / 4096
"""

import os
import re
import subprocess
import sys

SECTOR = 4096
SUPER_OFFSET = 0x0b208000        # from the GPT; = device sector 45576
LOADER = "firmware/palma2pro-firehose.bin"


def extents_for(lpdump_path, part):
    """[(phys_sector_512, len_512)] for one partition, from lpdump output"""
    out, cur = [], None
    for line in open(lpdump_path):
        m = re.match(r"\s*Name:\s*(\S+)", line)
        if m:
            cur = m.group(1)
            continue
        if cur != part:
            continue
        m = re.match(r"\s*(\d+)\s*\.\.\s*(\d+)\s+linear\s+super\s+(\d+)", line)
        if m:
            start, end, phys = (int(x) for x in m.groups())
            out.append((phys, end - start + 1))
    return out


def main():
    args = list(sys.argv[1:])
    go = "--go" in args
    if go:
        args.remove("--go")
    max_pct = 25
    if "--max-pct" in args:
        i = args.index("--max-pct")
        max_pct = int(args[i + 1])
        del args[i:i + 2]
    if len(args) < 4:
        print(__doc__)
        return 2
    old_p, new_p, lpdump, part = args[:4]

    old_sz, new_sz = os.path.getsize(old_p), os.path.getsize(new_p)
    if old_sz != new_sz:
        print(f"images differ in size ({old_sz} vs {new_sz}) -- needs a full "
              f"flash, filesystem geometry changed", file=sys.stderr)
        return 1

    ext = extents_for(lpdump, part)
    if not ext:
        print(f"no extents for {part}", file=sys.stderr)
        return 1
    total = sum(l for _, l in ext) * 512
    if new_sz > total:
        print(f"image {new_sz} > partition {total}", file=sys.stderr)
        return 1

    # Map image offset -> device sector, honouring the extent layout.
    def dev_sector(img_off):
        pos = 0
        for phys, ln in ext:
            n = ln * 512
            if img_off < pos + n:
                return (SUPER_OFFSET + phys * 512 + (img_off - pos)) // SECTOR
            pos += n
        return None

    print(f"diffing {os.path.basename(old_p)} -> {os.path.basename(new_p)} "
          f"({new_sz} bytes, {new_sz // SECTOR} sectors)")

    changed = []
    with open(old_p, "rb") as fa, open(new_p, "rb") as fb:
        idx = 0
        while True:
            a = fa.read(SECTOR)
            b = fb.read(SECTOR)
            if not b:
                break
            if a != b:
                changed.append(idx)
            idx += 1

    pct = 100.0 * len(changed) / max(1, new_sz // SECTOR)
    print(f"changed sectors: {len(changed)} ({pct:.2f}%)")
    if not changed:
        print("nothing to do")
        return 0
    if pct > max_pct:
        print(f"more than {max_pct}% differs -- a full flash will be faster "
              f"and safer; pass --max-pct to override", file=sys.stderr)
        return 1

    # Coalesce into contiguous runs so we issue few, large writes.
    runs, s, prev = [], changed[0], changed[0]
    for c in changed[1:]:
        if c == prev + 1:
            prev = c
            continue
        runs.append((s, prev - s + 1))
        s = prev = c
    runs.append((s, prev - s + 1))
    print(f"coalesced into {len(runs)} run(s), "
          f"{sum(n for _, n in runs) * SECTOR / 1e6:.1f} MB total")

    if not go:
        for st, n in runs[:10]:
            print(f"  img sector {st:<9} x{n:<5} -> device sector {dev_sector(st * SECTOR)}")
        if len(runs) > 10:
            print(f"  ... {len(runs) - 10} more")
        print("\nplan only -- pass --go to write")
        return 0

    tmp = "/tmp/edl-delta-run.bin"
    with open(new_p, "rb") as f:
        for i, (st, n) in enumerate(runs, 1):
            f.seek(st * SECTOR)
            data = f.read(n * SECTOR)
            with open(tmp, "wb") as t:
                t.write(data)
            ds = dev_sector(st * SECTOR)
            print(f"  [{i}/{len(runs)}] writing {n} sector(s) at device {ds}")
            r = subprocess.run(["edl", "ws", str(ds), tmp,
                                f"--loader={LOADER}", "--memory=ufs", "--lun=0"],
                               capture_output=True, text=True)
            if "Wrote" not in r.stdout:
                print(r.stdout[-400:], r.stderr[-400:], file=sys.stderr)
                return 1
    os.path.exists(tmp) and os.unlink(tmp)
    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
