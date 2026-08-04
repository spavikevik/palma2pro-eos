#!/usr/bin/env python3
"""
kdis -- symbolised disassembly of the Onyx EPD kernel.

The shipped kernel Image carries no symbol table, so earlier passes through this
driver worked in raw file offsets and guessed at what each call reached. That is
unnecessary: /proc/kallsyms on the running device names every address, and a raw
arm64 Image maps _text to file offset 0, so

    file_offset = kallsyms_address - <_text>

Check the base, do not trust it. epdc_ioctl resolves to 0x57a988, and the ioctl
jump-table dispatch located by hand in an earlier pass sits exactly 0x2c into it.
Two independent derivations landing on the same byte is what makes the base
sound.

The kernel MUST be the one actually running. See docs/22 section 9.2: a kernel
taken from firmware/analysis/ turned out to be a different build (#147 against
the running #245) and every offset drifted by amounts small enough to look like
an arithmetic slip rather than the wrong file.

SETUP
    adb root
    adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
    adb shell 'cat /proc/kallsyms' > kallsyms.txt
    adb shell 'dd if=/dev/block/by-name/boot_b of=/data/local/tmp/b.img bs=1M count=96'
    adb pull /data/local/tmp/b.img && adb shell 'rm /data/local/tmp/b.img'
    python3 scripts/kdis.py --prepare b.img kallsyms.txt

USAGE
    kdis.py <symbol|0xoffset> [length]   disassemble
    kdis.py -s <regex>                   search symbol names
    kdis.py -w <symbol|0xoffset>         find callers (bl/b)

Needs capstone:
    python3 -m venv .venv && .venv/bin/pip install capstone
"""
import bisect
import os
import re
import struct
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN, Cs

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("KDIS_DIR", os.path.join(HERE, os.pardir, "out", "kdis"))
IMAGE = os.path.join(OUT, "kernel.raw")
SYMMAP = os.path.join(OUT, "symmap.txt")

MD = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
MD.detail = False

BLOB = b""
offs, names, kinds, byname = [], [], [], {}


def prepare(bootimg, kallsyms):
    """Split the kernel out of a boot image and rebase kallsyms onto it."""
    os.makedirs(OUT, exist_ok=True)
    d = open(bootimg, "rb").read()
    if d[:8] != b"ANDROID!":
        sys.exit("not an Android boot image: %s" % bootimg)
    ksize = struct.unpack_from("<I", d, 8)[0]
    page = struct.unpack_from("<I", d, 36)[0]
    kern = d[page:page + ksize]
    if kern[56:60] != b"ARMd":
        sys.exit("extracted kernel lacks the arm64 magic -- wrong header layout?")
    open(IMAGE, "wb").write(kern)

    rows, base = [], None
    for line in open(kallsyms):
        p = line.split(None, 2)
        if len(p) < 3:
            continue
        a, t, n = int(p[0], 16), p[1], p[2].strip()
        if n == "_text":
            base = a
        rows.append((a, t, n))
    if base is None:
        sys.exit("no _text in kallsyms -- is kptr_restrict still non-zero?")
    # Loadable modules live outside the kernel image and would map to negative
    # offsets; keep only what the image actually contains.
    rows = sorted((a - base, t, n) for a, t, n in rows if a >= base)
    with open(SYMMAP, "w") as f:
        for o, t, n in rows:
            f.write("%08x %s %s\n" % (o, t, n))

    m = re.search(rb"Linux version [^\x00]{0,120}", kern)
    print("kernel : %s (%d bytes)" % (IMAGE, len(kern)))
    print("version: %s" % (m.group(0).decode() if m else "?"))
    print("symbols: %s (%d, _text = 0x%x)" % (SYMMAP, len(rows), base))
    print("\nConfirm /proc/version matches the version line above before"
          "\ntrusting any offset this produces.")


def load():
    if not os.path.exists(SYMMAP) or not os.path.exists(IMAGE):
        sys.exit("no symbol map yet; run: kdis.py --prepare <boot.img> <kallsyms.txt>")
    global BLOB
    BLOB = open(IMAGE, "rb").read()
    for line in open(SYMMAP):
        o, t, n = line.split(None, 2)
        o, n = int(o, 16), n.strip()
        offs.append(o)
        names.append(n)
        kinds.append(t)
        byname.setdefault(n, o)


def sym(off):
    """Nearest preceding symbol as name+delta -- how a call target reads."""
    i = bisect.bisect_right(offs, off) - 1
    if i < 0:
        return None
    d = off - offs[i]
    # A large delta means we ran off the end of the last known symbol into
    # unnamed data; naming it anyway would be worse than saying nothing.
    if d > 0x4000:
        return None
    return names[i] if d == 0 else "%s+0x%x" % (names[i], d)


def resolve(arg):
    if arg.startswith("0x"):
        return int(arg, 16)
    if arg in byname:
        return byname[arg]
    sys.exit("unknown symbol: %s" % arg)


def extent(start):
    """Function length, inferred as 'up to the next distinct symbol'."""
    i = bisect.bisect_right(offs, start)
    while i < len(offs) and offs[i] == start:
        i += 1
    return (offs[i] - start) if i < len(offs) else 0x200


def disas(start, length):
    print("== %s   file 0x%x..0x%x   (%d bytes)"
          % (sym(start), start, start + length, length))

    insns = list(MD.disasm(BLOB[start:start + length], start))

    # Label branch targets that stay inside the range, so loop heads and error
    # paths are visible rather than being bare addresses.
    local = set()
    for ins in insns:
        m = re.search(r"#0x([0-9a-f]+)$", ins.op_str)
        if m and ins.mnemonic[0] in "bct":
            t = int(m.group(1), 16)
            if start <= t < start + length:
                local.add(t)

    # ADRP+ADD pairs address globals and string constants; tracking the ADRP
    # page lets the following ADD resolve to something nameable.
    adrp = {}
    for ins in insns:
        if ins.address in local:
            print("  %8x:                    .L_%x:" % (ins.address, ins.address))

        note = ""
        m = re.search(r"#0x([0-9a-f]+)$", ins.op_str)

        if ins.mnemonic == "adrp" and m:
            adrp[ins.op_str.split(",")[0].strip()] = int(m.group(1), 16)
            note = "   ; page 0x%x" % int(m.group(1), 16)
        elif ins.mnemonic == "add" and "#" in ins.op_str:
            parts = [p.strip() for p in ins.op_str.split(",")]
            if len(parts) == 3 and parts[1] in adrp and parts[2].startswith("#"):
                tgt = adrp[parts[1]] + int(parts[2][1:], 16)
                s = sym(tgt)
                note = "   ; 0x%x%s" % (tgt, " <%s>" % s if s else "")
                txt = cstr(tgt)
                if txt:
                    note += "  %r" % txt
        elif m and ins.mnemonic[0] in "bct":
            t = int(m.group(1), 16)
            if not (start <= t < start + length):
                s = sym(t)
                note = "   ; <%s>" % s if s else ""

        print("  %8x: %-8s %s%s" % (ins.address, ins.mnemonic, ins.op_str, note))


def cstr(off, limit=140):
    """Printable NUL-terminated string at off, or None.

    The driver logs with __func__, so its format strings double as an
    accidental symbol table -- resolving them inline is most of what makes a
    listing readable.
    """
    end = BLOB.find(b"\x00", off, off + limit)
    if end <= off:
        return None
    try:
        s = BLOB[off:end].decode("ascii")
    except UnicodeDecodeError:
        return None
    return s if len(s) >= 4 and s.isprintable() else None


def whoref(target):
    """Every bl/b in the image that reaches this offset.

    Exhaustive and cheap: scan all 4-byte instructions and decode the two
    encodings that can name a far address.
    """
    hits = []
    for off in range(0, len(BLOB) & ~3, 4):
        w = int.from_bytes(BLOB[off:off + 4], "little")
        if (w >> 26) in (0b100101, 0b000101):
            imm = w & 0x03FFFFFF
            if imm & 0x02000000:
                imm -= 0x04000000
            if off + imm * 4 == target:
                hits.append((off, "bl" if (w >> 26) == 0b100101 else "b"))
    return hits


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--prepare":
        if len(sys.argv) != 4:
            sys.exit("usage: kdis.py --prepare <boot.img> <kallsyms.txt>")
        prepare(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    load()

    if sys.argv[1] == "-s":
        rx = re.compile(sys.argv[2], re.I)
        for o, t, n in zip(offs, kinds, names):
            if rx.search(n):
                print("%08x %s %s" % (o, t, n))
        return
    if sys.argv[1] == "-w":
        t = resolve(sys.argv[2])
        print("== callers of %s (0x%x)" % (sym(t), t))
        for off, kind in whoref(t):
            print("  %-3s from %08x  %s" % (kind, off, sym(off)))
        return

    start = resolve(sys.argv[1])
    length = int(sys.argv[2], 0) if len(sys.argv) > 2 else extent(start)
    disas(start, length)


if __name__ == "__main__":
    main()
