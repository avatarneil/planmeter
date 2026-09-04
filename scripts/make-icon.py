#!/usr/bin/env python3
"""Renders a simple app icon (two stacked bars on a rounded tile) to an .icns file.

Uses only macOS built-ins: PyObjC is not required; the PNGs are drawn with
Quartz via `sips`-free pure Python PNG encoding, then packed with `iconutil`.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib


def png(width, height, pixels):
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def render(size):
    s = size
    rows = []
    radius = s * 0.22
    bg = (28, 30, 38)
    bar_a = (8, 145, 178)   # personal (teal)
    bar_b = (124, 58, 237)  # work (violet)
    for y in range(s):
        row = []
        for x in range(s):
            # Rounded-rect mask
            dx = max(radius - x, x - (s - 1 - radius), 0)
            dy = max(radius - y, y - (s - 1 - radius), 0)
            inside = (dx * dx + dy * dy) <= radius * radius
            if not inside:
                row.extend((0, 0, 0, 0))
                continue
            r, g, b = bg
            fx, fy = x / s, y / s
            # Three bars: left two are "personal", right one "work", heights differ.
            bars = [(0.16, 0.30, 0.42, bar_a), (0.40, 0.54, 0.26, bar_a), (0.64, 0.84, 0.58, bar_b)]
            for x0, x1, h, color in bars:
                if x0 <= fx < x1 and fy >= (0.86 - h) and fy < 0.86:
                    r, g, b = color
            # Baseline
            if 0.86 <= fy < 0.875 and 0.12 <= fx < 0.88:
                r, g, b = (90, 94, 110)
            row.extend((r, g, b, 255))
        rows.append(row)
    return png(s, s, rows)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for base in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                size = base * scale
                name = f"icon_{base}x{base}" + ("@2x" if scale == 2 else "") + ".png"
                with open(os.path.join(iconset, name), "wb") as f:
                    f.write(render(size))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
