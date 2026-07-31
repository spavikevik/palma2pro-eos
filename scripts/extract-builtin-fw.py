#!/usr/bin/env python3
"""Extract CONFIG_EXTRA_FIRMWARE blobs embedded in a raw ARM64 kernel Image.

    extract-builtin-fw.py <Image> <outdir>

WHY
---
Onyx publishes no kernel source, and every Onyx driver is built in (=y, not =m --
1766 built-ins vs 5 modules), so no .ko can be salvaged. But the *data* the EPD
stack feeds to the hardware is compiled into the Image via CONFIG_EXTRA_FIRMWARE:

    waveform/eink_waveform.wbf                      e-ink waveform table
    mxo/mxo{1300,4300}_nvcm_8*.ied                  EPD controller firmware
    lfcpnx/lfcpnx100_tcon_fw_*.bin                  Lattice TCON firmware

Those are recoverable, and would be needed by any clean-room EPD driver.

HOW
---
CONFIG_EXTRA_FIRMWARE builds a table of

    struct builtin_fw { char *name; void *data; unsigned long size; };

in section .builtin_fw -- 24 bytes per entry on arm64, laid out contiguously.
A raw `Image` has no symbols or section headers, so the table is located
structurally instead:

  1. find the file offset of each known firmware name string
  2. scan 8-byte-aligned u64s for a run of entries whose first field, taken at
     stride 24, points at those strings under ONE consistent virtual-address
     bias (kernel VA -> file offset)
  3. that bias then resolves every `data` pointer, and `size` gives the length

The bias is recovered rather than assumed because a raw Image gives no load
address, and it is validated by requiring several names to agree.
"""

import os
import struct
import sys

ENTRY = 24  # sizeof(struct builtin_fw) on arm64


def find_names(d, names):
    """file offset of each NUL-terminated name string present in the image"""
    out = {}
    for n in names:
        pat = n.encode() + b"\0"
        i = d.find(pat)
        if i >= 0:
            out[n] = i
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    img, outdir = sys.argv[1], sys.argv[2]
    d = open(img, "rb").read()
    os.makedirs(outdir, exist_ok=True)

    names = [
        "waveform/eink_waveform.wbf",
        "mxo/mxo1300_nvcm_81.ied", "mxo/mxo4300_nvcm_81.ied",
        "mxo/mxo1300_nvcm_82.ied", "mxo/mxo4300_nvcm_82.ied",
        "mxo/mxo1300_nvcm_83.ied", "mxo/mxo1300_nvcm_84.ied",
        "mxo/mxo1300_nvcm_86.ied", "mxo/mxo1300_nvcm_87.ied",
        "lfcpnx/lfcpnx100_tcon_fw_9f.bin", "lfcpnx/lfcpnx100_tcon_fw_9e.bin",
        "lfcpnx/lfcpnx100_tcon_fw_99.bin", "lfcpnx/lfcpnx100_tcon_fw_a2.bin",
        "lfcpnx/lfcpnx100_tcon_fw_a5.bin", "lfcpnx/lfcpnx100_tcon_fw_a7.bin",
    ]
    # names may be stored with or without the directory prefix
    found = find_names(d, names)
    if not found:
        found = find_names(d, [n.split("/")[-1] for n in names])
    if not found:
        print("no firmware name strings found", file=sys.stderr)
        return 1
    print(f"located {len(found)}/{len(names)} name strings")

    name_offsets = set(found.values())
    lo, hi = min(name_offsets), max(name_offsets)

    # Recover the VA bias STRUCTURALLY, not by voting.
    #
    # A first attempt counted, for every aligned u64, the bias that would map it
    # onto some name string, and took the most popular. That is noise: 354,975
    # "agreements" and a bogus 8 MiB extraction. Random pointers land on random
    # biases, and with 15 targets the winner means nothing.
    #
    # The table is an ARRAY: entry i and entry i+1 are exactly 24 bytes apart,
    # and their name pointers differ by exactly the gap between the two name
    # strings (which are laid out adjacently, in the same order). That pair of
    # constraints is highly specific, so match on it.
    sorted_offs = sorted(name_offsets)
    gaps = [b - a for a, b in zip(sorted_offs, sorted_offs[1:])]

    # A candidate bias is only accepted if it makes MANY entries resolve.
    # The first version accepted the first structural gap match and got a
    # coincidence: table "found" at 0x3468568, bias derived, zero entries
    # resolved. Verify before trusting.
    def score(bias):
        """how many table entries resolve to known names under this bias"""
        n = 0
        for base in range(0, len(d) - ENTRY, 8):
            pass
        return n

    def verify(off0, bias):
        """count resolvable entries in the contiguous run starting at off0"""
        n = 0
        for k in range(0, 40):
            o = off0 + k * ENTRY
            if o + ENTRY > len(d):
                break
            np_, dp_, sz = struct.unpack_from("<QQQ", d, o)
            if np_ < 0xFFFF000000000000:
                break
            if (np_ - bias) in inv_offsets and 0 < sz < (64 << 20):
                n += 1
            else:
                break
        return n

    inv_offsets = set(found.values())
    sorted_offs = sorted(name_offsets)
    gaps = {b - a for a, b in zip(sorted_offs, sorted_offs[1:])}

    bias = None
    table_off = None
    best = 0
    for off in range(0, len(d) - ENTRY * 3, 8):
        v0 = struct.unpack_from("<Q", d, off)[0]
        if v0 < 0xFFFF000000000000:
            continue
        v1 = struct.unpack_from("<Q", d, off + ENTRY)[0]
        if v1 < 0xFFFF000000000000:
            continue
        d1 = v1 - v0
        if d1 not in gaps:
            continue
        for cand in sorted_offs:
            if cand + d1 not in name_offsets:
                continue
            b_ = v0 - cand
            n = verify(off, b_)
            if n > best:
                best, bias, table_off = n, b_, off
            if n >= 8:
                break
        if best >= 8:
            break

    if bias is None or best < 3:
        print(f"could not locate the table reliably (best run: {best})", file=sys.stderr)
        return 1
    print(f"table at 0x{table_off:x}, {best} consecutive entries resolve")
    print(f"virtual-address bias 0x{bias & 0xFFFFFFFFFFFFFFFF:016x}")

    # Walk the table: find each entry whose name pointer resolves to a known name.
    inv = {v: k for k, v in found.items()}
    extracted = 0
    for off in range(0, len(d) - ENTRY, 8):
        name_p, data_p, size = struct.unpack_from("<QQQ", d, off)
        if name_p < 0xFFFF000000000000 or data_p < 0xFFFF000000000000:
            continue
        n_off = name_p - bias
        if n_off not in inv:
            continue
        if not (0 < size < 64 << 20):
            continue
        d_off = data_p - bias
        if d_off < 0 or d_off + size > len(d):
            print(f"  {inv[n_off]}: data outside image, skipped")
            continue
        blob = d[d_off:d_off + size]
        out = os.path.join(outdir, os.path.basename(inv[n_off]))
        open(out, "wb").write(blob)
        print(f"  {inv[n_off]:34} {size:>9} bytes  -> {out}")
        extracted += 1

    print(f"extracted {extracted} blob(s)")
    return 0 if extracted else 1


if __name__ == "__main__":
    sys.exit(main())
