#!/usr/bin/env python3
"""Prepare lock-screen artwork for the e-ink panel.

Takes an ordinary image and produces one the panel can actually show well:
greyscale, Floyd-Steinberg dithered to the panel's **16 grey levels**, at the
display's exact pixel size so nothing is rescaled at draw time.

Why dither rather than let the hardware do it
---------------------------------------------
The panel has 4 bits per pixel. Handing it an 8-bit photograph means the driver
truncates, and truncation of a smooth gradient produces visible banding -- a sky
becomes four flat stripes. Dithering trades that banding for high-frequency
noise, which at this DPI reads as texture rather than error, and is why e-ink
readers ship dithered artwork rather than raw photographs.

Why a script rather than committed binaries
-------------------------------------------
The output is derived from third-party artwork. Keeping the recipe in the repo
and the sources external means provenance stays checkable: THIRD_PARTY.md records
what each image is and where it came from, and anyone can re-run this to verify
the derivation. It also keeps the repo small.

Depends only on the standard library plus `sips`, which ships with macOS. No
Pillow: this project's build hosts do not have it, and adding a dependency for
three images is not worth it.

Usage:
    scripts/gen-screensaver.py IN.jpg OUT.png [--width 824] [--height 1648]
"""

import argparse
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

# The panel is 1648x824 in output space, but content is composited in layer-stack
# space, which is portrait. See docs/19.
DEFAULT_W, DEFAULT_H = 824, 1648

# 4bpp panel: 16 evenly spaced levels.
LEVELS = 16


def sips_prepare(src: Path, dst: Path, w: int, h: int) -> None:
    """Scale to fit and pad to exactly w x h on white, via sips."""
    # Longest side first, so the whole image fits inside the target box...
    subprocess.run(["sips", "-Z", str(max(w, h)), str(src), "--out", str(dst)],
                   check=True, capture_output=True)
    # ...then pad the short axis. White, not black: an e-ink lock screen sits at
    # rest for hours and white is the panel's zero-energy state.
    subprocess.run(["sips", "--padToHeightWidth", str(h), str(w),
                    "--padColor", "FFFFFF", str(dst), "--out", str(dst)],
                   check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "png", str(dst), "--out", str(dst)],
                   check=True, capture_output=True)


def read_png(path: Path):
    """Minimal PNG reader: 8-bit greyscale/RGB/RGBA, non-interlaced."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, hdr = 8, bytearray(), None
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length

    width, height, depth, color, comp, filt, interlace = hdr
    if depth != 8 or interlace != 0:
        raise ValueError(f"unsupported PNG: depth={depth} interlace={interlace}")
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        # Undo the per-scanline filter (PNG spec 9.2).
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            x = line[i]
            if ftype == 1:
                x += a
            elif ftype == 2:
                x += b
            elif ftype == 3:
                x += (a + b) >> 1
            elif ftype == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                x += a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[i] = x & 0xFF
        prev = line
        # Rec. 709 luma. Alpha is composited onto white, matching the padding.
        for x in range(width):
            o = x * channels
            if channels == 1:
                v = line[o]
            elif channels == 2:
                v, alpha = line[o], line[o + 1]
                v = (v * alpha + 255 * (255 - alpha)) // 255
            else:
                v = (line[o] * 299 + line[o + 1] * 587 + line[o + 2] * 114) // 1000
                if channels == 4:
                    alpha = line[o + 3]
                    v = (v * alpha + 255 * (255 - alpha)) // 255
            out[y * width + x] = v
    return width, height, out


def dither(width: int, height: int, buf: bytearray) -> bytearray:
    """Floyd-Steinberg to LEVELS grey levels, in place."""
    step = 255.0 / (LEVELS - 1)
    err = [0.0] * (width * height)
    for y in range(height):
        row = y * width
        for x in range(width):
            i = row + x
            old = buf[i] + err[i]
            new = round(old / step) * step
            new = 0.0 if new < 0 else (255.0 if new > 255 else new)
            buf[i] = int(new)
            e = old - new
            # Distribute the residual to not-yet-visited neighbours.
            if x + 1 < width:
                err[i + 1] += e * 7 / 16
            if y + 1 < height:
                if x:
                    err[i + width - 1] += e * 3 / 16
                err[i + width] += e * 5 / 16
                if x + 1 < width:
                    err[i + width + 1] += e * 1 / 16
    return buf


def write_png(path: Path, width: int, height: int, buf: bytearray) -> None:
    """8-bit greyscale PNG, filter 0. Values already snapped to the panel levels."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        rows += buf[y * width:(y + 1) * width]

    def chunk(tag: bytes, body: bytes) -> bytes:
        return (struct.pack(">I", len(body)) + tag + body
                + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b""))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--width", type=int, default=DEFAULT_W)
    ap.add_argument("--height", type=int, default=DEFAULT_H)
    ap.add_argument("--no-dither", action="store_true",
                    help="quantise without dithering (shows why dithering is used)")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as td:
        staged = Path(td) / "staged.png"
        sips_prepare(Path(args.src), staged, args.width, args.height)
        w, h, buf = read_png(staged)

    if args.no_dither:
        step = 255.0 / (LEVELS - 1)
        buf = bytearray(int(round(v / step) * step) for v in buf)
    else:
        buf = dither(w, h, buf)

    write_png(Path(args.dst), w, h, buf)
    print(f"{args.dst}: {w}x{h}, {LEVELS} grey levels, "
          f"{'quantised' if args.no_dither else 'dithered'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
