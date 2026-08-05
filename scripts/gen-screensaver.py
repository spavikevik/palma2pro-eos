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


def sips_dimensions(path: Path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                         check=True, capture_output=True, text=True).stdout
    dims = {}
    for line in out.splitlines():
        k, _, v = line.strip().partition(": ")
        if k in ("pixelWidth", "pixelHeight"):
            dims[k] = int(v)
    return dims["pixelWidth"], dims["pixelHeight"]


def sips_prepare(src: Path, dst: Path, w: int, h: int) -> None:
    """Scale and centre-crop to exactly w x h, covering the panel completely.

    "Cover", not "fit". Fitting preserves the whole image and pads the short axis,
    which on a lock screen means white bands down two edges -- and on e-ink those
    bands are not subtle, because the panel holds them at full contrast for hours.
    Covering fills the panel and loses the overflow instead.

    Scale by whichever axis is short relative to the target, so the result is at
    least w x h with aspect preserved, then take the middle. Resampling a single
    axis is what keeps sips from distorting: --resampleHeightWidth would force
    both and squash the image.
    """
    sw, sh = sips_dimensions(src)

    subprocess.run(["sips", "-s", "format", "png", str(src), "--out", str(dst)],
                   check=True, capture_output=True)

    # Compare aspect ratios with integer cross-multiplication -- no float
    # rounding deciding which axis to drive.
    if sw * h > sh * w:
        # Source is proportionally wider: match the height, overflow the width.
        subprocess.run(["sips", "--resampleHeight", str(h), str(dst), "--out", str(dst)],
                       check=True, capture_output=True)
    else:
        subprocess.run(["sips", "--resampleWidth", str(w), str(dst), "--out", str(dst)],
                       check=True, capture_output=True)

    # Centre crop. sips crops about the centre, which is the right default for
    # artwork; anything smarter needs to know where the subject is.
    subprocess.run(["sips", "--cropToHeightWidth", str(h), str(w), str(dst), "--out", str(dst)],
                   check=True, capture_output=True)

    cw, ch = sips_dimensions(dst)
    if (cw, ch) != (w, h):
        raise SystemExit(f"cover-crop produced {cw}x{ch}, wanted {w}x{h}")


def read_png(path: Path, rgb: bool = False):
    """Minimal PNG reader: 8-bit greyscale/RGB/RGBA, non-interlaced.

    Returns (width, height, buf) where buf is one byte per pixel, or three when
    rgb is set. Alpha is composited onto white either way, matching the panel's
    rest state.
    """
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
    outch = 3 if rgb else 1
    out = bytearray(width * height * outch)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        # Undo the per-scanline filter (PNG spec 9.2). Filter 0 is a straight
        # copy; skipping the byte loop for it matters here because a full-panel
        # RGB image is four million bytes and this is pure Python.
        if ftype != 0:
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

        for x in range(width):
            o = x * channels
            if channels == 1:
                r = g = b = line[o]
                alpha = 255
            elif channels == 2:
                r = g = b = line[o]
                alpha = line[o + 1]
            else:
                r, g, b = line[o], line[o + 1], line[o + 2]
                alpha = line[o + 3] if channels == 4 else 255
            if alpha != 255:
                r = (r * alpha + 255 * (255 - alpha)) // 255
                g = (g * alpha + 255 * (255 - alpha)) // 255
                b = (b * alpha + 255 * (255 - alpha)) // 255
            if rgb:
                i = (y * width + x) * 3
                out[i], out[i + 1], out[i + 2] = r, g, b
            else:
                # Rec. 601 luma.
                out[y * width + x] = (r * 299 + g * 587 + b * 114) // 1000
    return width, height, out


def dither(width: int, height: int, buf: bytearray,
           channels: int = 1, levels: int = LEVELS) -> bytearray:
    """Floyd-Steinberg to `levels` levels per channel, in place.

    For colour, each channel is diffused independently. That is the standard
    treatment for a Kaleido-style panel: the colour filter array puts separate R,
    G and B filters over neighbouring cells, so each channel really is quantised
    on its own and coupling them would not model anything the hardware does.
    """
    step = 255.0 / (levels - 1)
    err = [0.0] * (width * height * channels)
    for y in range(height):
        row = y * width * channels
        for x in range(width):
            base = row + x * channels
            for c in range(channels):
                i = base + c
                old = buf[i] + err[i]
                new = round(old / step) * step
                new = 0.0 if new < 0 else (255.0 if new > 255 else new)
                buf[i] = int(new)
                e = old - new
                # Distribute the residual to not-yet-visited neighbours, staying
                # within this channel's lattice.
                if x + 1 < width:
                    err[i + channels] += e * 7 / 16
                if y + 1 < height:
                    nxt = i + width * channels
                    if x:
                        err[nxt - channels] += e * 3 / 16
                    err[nxt] += e * 5 / 16
                    if x + 1 < width:
                        err[nxt + channels] += e * 1 / 16
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
    ap.add_argument("--color", action="store_true",
                    help="keep colour and dither each channel (Kaleido CFA panel)")
    ap.add_argument("--levels", type=int, default=LEVELS,
                    help=f"levels per channel (default {LEVELS})")
    args = ap.parse_args()

    channels = 3 if args.color else 1

    with tempfile.TemporaryDirectory() as td:
        staged = Path(td) / "staged.png"
        sips_prepare(Path(args.src), staged, args.width, args.height)
        w, h, buf = read_png(staged, rgb=args.color)

    if args.no_dither:
        step = 255.0 / (args.levels - 1)
        buf = bytearray(int(round(v / step) * step) for v in buf)
    else:
        buf = dither(w, h, buf, channels=channels, levels=args.levels)

    kind = f"{'24-bit RGB' if args.color else '8-bit grey'}"

    # A .raw destination writes the bare pixel plane instead of a PNG.
    # src/ebcshow.c takes that directly, which keeps a PNG decoder out of a
    # freestanding aarch64 tool -- the dithering has already happened here, and
    # re-encoding it only to decode it again on the device buys nothing.
    if Path(args.dst).suffix == ".raw":
        Path(args.dst).write_bytes(bytes(buf))
        print(f"{args.dst}: {w}x{h} {kind}, {len(buf)} bytes, "
              f"{args.levels} levels/channel, "
              f"{'quantised' if args.no_dither else 'dithered'}")
        print(f"  adb push {args.dst} /data/local/tmp/ && "
              f"adb shell /data/local/tmp/ebcshow /data/local/tmp/"
              f"{Path(args.dst).name} {w} {h} 270 2 1500 1 {channels}")
        return 0

    if args.color:
        raise SystemExit("--color writes .raw only; PNG output stays greyscale")

    write_png(Path(args.dst), w, h, buf)
    print(f"{args.dst}: {w}x{h}, {args.levels} grey levels, "
          f"{'quantised' if args.no_dither else 'dithered'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
