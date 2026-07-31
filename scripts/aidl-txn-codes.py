#!/usr/bin/env python3
"""Recover AIDL transaction codes from a compiled Bp proxy, and diff two builds.

    aidl-txn-codes.py <libA.so> [libB.so] [--class 17BpSurfaceComposer]

WHY
---
A binder interface's wire format is its transaction codes, and AIDL assigns them
by DECLARATION ORDER in the .aidl file. Two builds of the same interface from
different AOSP revisions therefore disagree the moment one of them inserts a
method anywhere but the end -- every method after the insertion shifts, and
callers silently invoke the wrong one.

That is exactly what stopped Onyx's SurfaceFlinger working with our framework:
our libgui declared `getMaxLayerPictureProfiles` at code 25, shifting the 45
methods after it by +1, so our `getCompositionPreference` (34) reached their
`getDisplayedContentSamplingAttributes` (33). The visible symptom was
`SurfaceControl.getCompositionColorSpaces()` returning null and taking
system_server down -- nothing that points at transaction numbering.

HOW
---
Each generated `Bp` method loads its transaction code as an immediate into w1
immediately before calling `transact()`. So: for every `Bp<Class>` FUNC symbol,
disassemble the body and take the last `mov w1, #imm` with a plausible code.

Filter on the MANGLED LENGTH PREFIX (`17BpSurfaceComposer`), not the bare name.
`BpSurfaceComposerClient` is a different interface and its symbols will
otherwise pollute the map -- that mistake made codes 3 and 6 look like
divergences when they were not.

USE
---
One library: print its code -> method map.
Two: diff them, report where they diverge and which methods are ours-only.
"""

import os
import re
import subprocess
import sys

NDK_CANDIDATES = [
    os.environ.get("NDK_BIN", ""),
    "/opt/homebrew/share/android-ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin",
    os.path.expanduser("~/Library/Android/sdk/ndk"),
]


def ndk_bin():
    for c in NDK_CANDIDATES:
        if c and os.path.isfile(os.path.join(c, "llvm-readelf")):
            return c
    sys.exit("no NDK llvm-readelf found; set NDK_BIN")


BIN = None


def codes(lib, klass):
    """{transaction_code: method_name} for one shared library"""
    out = subprocess.run([f"{BIN}/llvm-readelf", "--dyn-syms", lib],
                         capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or f[3] != "FUNC":
            continue
        name = f[7].split("@")[0]
        if klass not in name:
            continue
        try:
            addr, size = int(f[1], 16), int(f[2])
        except ValueError:
            continue
        if size > 0:
            syms.append((addr, size, name))

    res = {}
    for addr, size, name in syms:
        dis = subprocess.run(
            [f"{BIN}/llvm-objdump", "-d", f"--start-address={hex(addr)}",
             f"--stop-address={hex(addr + size)}", lib],
            capture_output=True, text=True).stdout
        code = None
        for m in re.finditer(r"\bmov\s+w1, #(0x[0-9a-f]+|\d+)", dis):
            v = int(m.group(1), 0)
            if 0 < v < 300:
                code = v          # last one wins: it is the transact() argument
        if code is None:
            continue
        dem = subprocess.run([f"{BIN}/llvm-cxxfilt", name],
                             capture_output=True, text=True).stdout.strip()
        g = re.search(r"Bp\w+::(\w+)", dem)
        if g:
            res[code] = g.group(1)
    return res


def main():
    global BIN
    BIN = ndk_bin()
    args = [a for a in sys.argv[1:]]
    klass = "17BpSurfaceComposer"
    if "--class" in args:
        i = args.index("--class")
        klass = args[i + 1]
        del args[i:i + 2]
    if not args:
        print(__doc__)
        return 2

    a = codes(args[0], klass)
    if len(args) == 1:
        for c in sorted(a):
            print(f"{c:4}  {a[c]}")
        print(f"\n{len(a)} methods")
        return 0

    b = codes(args[1], klass)
    print(f"A {os.path.basename(args[0])}: {len(a)} codes")
    print(f"B {os.path.basename(args[1])}: {len(b)} codes")

    # Walk in code order. Where A has a method B lacks at the same code, treat it
    # as an A-only insertion and keep walking with an offset -- that identifies
    # which declaration is misplaced rather than just reporting N mismatches.
    shift, inserts = 0, []
    for c in range(1, max(list(a) + list(b), default=0) + 1):
        av, bv = a.get(c), b.get(c - shift)
        if av and bv and av != bv:
            inserts.append((c, av))
            shift += 1

    print(f"\nA-only insertions (mid-interface): {len(inserts)}")
    for c, nm in inserts:
        print(f"    code {c:3}: {nm}")

    shift, bad = 0, []
    for c in range(1, max(list(a) + list(b), default=0) + 1):
        if any(c == ic for ic, _ in inserts):
            shift += 1
            continue
        av, bv = a.get(c), b.get(c - shift)
        if av and bv and av != bv:
            bad.append((c, av, bv))
    print(f"remaining mismatches: {len(bad)}")
    for c, x, y in bad[:10]:
        print(f"    code {c}: A={x} B={y}")

    if not inserts and not bad:
        print("\nALIGNED: every shared code maps to the same method.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
