"""生成 1024x1024 AppIcon（纯标准库，无需 PIL）。

图标语义：深色底 + 红色环形弧 + 逆时针箭头 = 回溯（rewind）。
"""
import math
import struct
import zlib
import os

SIZE = 1024
CENTER = SIZE / 2.0

BG = (18, 19, 26, 255)
DISC = (28, 31, 43, 255)
RED = (255, 59, 48, 255)
ARROW = (245, 245, 247, 255)

RING_INNER = 292.0
RING_OUTER = 372.0
GAP_HALF = 0.42          # 缺口半角（弧度），缺口在正上方
GAP_CENTER = -math.pi / 2  # 正上方

# 箭头三角形（缺口处，指向逆时针方向＝向左）
TRI = (
    (CENTER - 40, CENTER - 331),
    (CENTER + 24, CENTER - 361),
    (CENTER + 24, CENTER - 301),
)


def point_in_triangle(px, py, tri):
    (x1, y1), (x2, y2), (x3, y3) = tri
    d1 = (px - x2) * (y1 - y2) - (x1 - x2) * (py - y2)
    d2 = (px - x3) * (y2 - y3) - (x2 - x3) * (py - y3)
    d3 = (px - x1) * (y3 - y1) - (x3 - x1) * (py - y1)
    has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (has_neg and has_pos)


def build_pixels():
    pixels = bytearray(SIZE * SIZE * 4)
    disc_sq = 250.0 * 250.0
    for y in range(SIZE):
        row_base = y * SIZE * 4
        dy = y + 0.5 - CENTER
        for x in range(SIZE):
            dx = x + 0.5 - CENTER
            r_sq = dx * dx + dy * dy
            color = BG

            if r_sq <= disc_sq:
                color = DISC

            r = math.sqrt(r_sq)
            if RING_INNER <= r <= RING_OUTER:
                theta = math.atan2(dy, dx)
                delta = abs((theta - GAP_CENTER + math.pi) % (2 * math.pi) - math.pi)
                if delta > GAP_HALF:
                    color = RED

            if abs(dx) < 70 and abs(dy + 331) < 70:
                if point_in_triangle(x + 0.5, y + 0.5, TRI):
                    color = ARROW

            offset = row_base + x * 4
            pixels[offset] = color[0]
            pixels[offset + 1] = color[1]
            pixels[offset + 2] = color[2]
            pixels[offset + 3] = color[3]
    return pixels


def write_png(path, pixels):
    raw = bytearray()
    stride = SIZE * 4
    for y in range(SIZE):
        raw.append(0)
        raw += pixels[y * stride:(y + 1) * stride]
    compressed = zlib.compress(bytes(raw), 9)

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    blob = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(blob)


if __name__ == "__main__":
    target = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "Resources",
        "Assets.xcassets",
        "AppIcon.appiconset",
        "AppIcon-1024.png",
    )
    write_png(target, build_pixels())
    print("written:", target, os.path.getsize(target), "bytes")
