#!/usr/bin/env python3
"""Wrap a byte range of a raw binary in a minimal ELF64 so llvm-objdump can disassemble it.

llvm-objdump refuses raw input (`-b binary` is a GNU objdump flag it does not
accept), and it misdetects a bare ARM64 kernel Image as COFF. Wrapping the bytes
in a one-section ELF is the cheapest way to get a real disassembler onto them.

The virtual address is set equal to the file offset of the range, so addresses in
the disassembly line up with offsets into the original image -- which is what we
want, since the kernel's true load address is unknown and every reference we care
about (ADRP/ADD, B/BL) is PC-relative anyway.

Usage:
    rawelf.py kernel.Image out.elf 0x57c000 0x57c800
    llvm-objdump -d --no-show-raw-insn out.elf
"""

import struct
import sys

EM_AARCH64 = 183


def build(data: bytes, vaddr: int) -> bytes:
    ehsize, phentsize, shentsize = 64, 56, 64
    shnum = 3                      # NULL, .text, .shstrtab
    shstrtab = b"\0.text\0.shstrtab\0"

    text_off = ehsize
    text_size = len(data)
    shstr_off = text_off + text_size
    sh_off = shstr_off + len(shstrtab)
    sh_off = (sh_off + 7) & ~7     # 8-byte align the section header table

    e = bytearray()
    e += b"\x7fELF" + bytes([2, 1, 1, 0]) + b"\0" * 8   # ELF64, LE, SysV
    e += struct.pack("<HH", 1, EM_AARCH64)              # ET_REL, aarch64
    e += struct.pack("<I", 1)                           # version
    e += struct.pack("<QQQ", 0, 0, sh_off)              # entry, phoff, shoff
    e += struct.pack("<I", 0)                           # flags
    e += struct.pack("<HHHHHH", ehsize, phentsize, 0, shentsize, shnum, 2)
    assert len(e) == ehsize

    e += data
    e += shstrtab
    e += b"\0" * (sh_off - len(e))

    def sh(name, typ, flags, addr, off, size, link=0, info=0, align=1, entsize=0):
        return struct.pack("<IIQQQQIIQQ", name, typ, flags, addr, off, size,
                           link, info, align, entsize)

    e += sh(0, 0, 0, 0, 0, 0)                                    # NULL
    e += sh(1, 1, 0x6, vaddr, text_off, text_size, align=4)      # .text AX
    e += sh(7, 3, 0, 0, shstr_off, len(shstrtab))                # .shstrtab
    return bytes(e)


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 2
    src, dst, lo, hi = sys.argv[1], sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0)
    data = open(src, "rb").read()[lo:hi]
    open(dst, "wb").write(build(data, lo))
    print(f"wrote {dst}: {len(data)} bytes, vaddr {lo:#x}-{hi:#x}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
