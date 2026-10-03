#!/usr/bin/env python3
"""「能工智人·数据库」图标的设计源。

设计语言取自游戏开始菜单的实机画面（标题屏的机房通道）：
深蓝黑底 + 深蓝灰机柜层板 + 蓝/白/青三色 LED + 柜顶那道荧光条。
LED 三色就是 TitleBackdrop.LED_TINTS 里那三组灯色。

分两套网格，各管各的尺寸档——这是图标设计的常规做法，不是偷懒：

  64×64（细密版 big）  → 64 / 128 / 256 / 512 / 1024
      四层板，每层 5 颗 3px 小灯。大尺寸下看的是"一排排指示灯"的密度感。
  16×16（粗放版 small）→ 16 / 32 / 48
      三层板、每层 3 颗 2px 灯。灯少而大，缩到 16px 才还剩得下东西；
      细密版直接缩到 16px 会糊成一团黑块加几个彩点（实测过）。

两个网格的尺寸档都取整数倍，所以光栅化永远不做非整数缩放，像素不糊。
`.ico` / `.icns` 由 tools/build_icons.sh 用这两套 SVG 拼出来。

用法：
  python3 tools/make_icon.py svg big   <out.svg>
  python3 tools/make_icon.py svg small <out.svg>
  python3 tools/make_icon.py ico <out.ico> <size>:<png> [<size>:<png> ...]
"""

import struct
import sys

# ------------------------------------------------------------------ 调色板
PLATE  = "#0a0f16"   # 底板（近黑，带蓝）
RIM    = "#22303f"   # 底板描边：黑桌面上也能看出轮廓
SLAB   = "#223449"   # 层板正面
EDGE   = "#6f92b3"   # 普通层上沿
CAP    = "#b9cee2"   # 顶层上沿（柜顶荧光条）
SHADOW = "#131e29"   # 层板下沿
BLUE   = "#4d8cff"   # 对应 LED_TINTS 的 led_blue
WHITE  = "#dceaff"   # 对应 led_white
CYAN   = "#5ae0ff"   # 对应 led_cyan


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.g = [[None] * w for _ in range(h)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.g[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, c)

    def plate(self, radius, fill=PLATE, rim=RIM):
        """圆角底板 + 1px 描边。角上用圆的方程判定，保证是干净的像素台阶。"""
        for y in range(self.h):
            for x in range(self.w):
                cx = min(x, self.w - 1 - x)
                cy = min(y, self.h - 1 - y)
                if cx >= radius or cy >= radius:
                    inside, edge = True, (cx == 0 or cy == 0)
                else:
                    dx, dy = radius - cx - 0.5, radius - cy - 0.5
                    d = (dx * dx + dy * dy) ** 0.5
                    inside = d <= radius
                    edge = inside and d > radius - 1.0
                if inside:
                    self.put(x, y, rim if edge else fill)

    def slab(self, x0, x1, top, height, cap=False):
        """一层机柜板：正面 + 上沿（顶层给荧光条色）+ 下沿暗边。"""
        self.rect(x0, top, x1, top + height - 1, SLAB)
        self.rect(x0, top, x1, top, CAP if cap else EDGE)
        self.rect(x0, top + height - 1, x1, top + height - 1, SHADOW)

    def leds(self, leds, y0, y1):
        """leds: [(x, w, color), ...]"""
        for x, w, col in leds:
            self.rect(x, y0, x + w - 1, y1, col)

    def svg(self, title, box):
        """把每行同色连续像素并成一条矩形，SVG 体积小很多。"""
        runs = []
        for y in range(self.h):
            x = 0
            while x < self.w:
                c = self.g[y][x]
                if c is None:
                    x += 1
                    continue
                x2 = x
                while x2 + 1 < self.w and self.g[y][x2 + 1] == c:
                    x2 += 1
                runs.append((x, y, x2 - x + 1, c))
                x = x2 + 1
        out = [
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{box}" height="{box}" '
            f'viewBox="0 0 {self.w} {self.h}" shape-rendering="crispEdges">',
            f'<title>{title}</title>',
        ]
        for x, y, w, c in runs:
            out.append(f'<rect x="{x}" y="{y}" width="{w}" height="1" fill="{c}"/>')
        out.append('</svg>')
        return '\n'.join(out) + '\n'


# ------------------------------------------------------------------ 细密版 64×64
def build_big():
    """四层板，每层 5 颗 3px 小灯——大尺寸下要的是"一排排指示灯"的密度。"""
    c = Canvas(64, 64)
    c.plate(radius=12)
    x0, x1 = 5, 58
    tops = [4, 19, 34, 49]
    for i, top in enumerate(tops):
        c.slab(x0, x1, top, 11, cap=(i == 0))
    # 灯位逐层错开：三层完全对齐会显出机械的网格感，错开才像真实的机柜面板
    units = [
        [(10, 3, CYAN), (17, 3, WHITE), (25, 3, BLUE), (38, 6, BLUE), (49, 3, CYAN)],
        [(10, 3, WHITE), (18, 6, CYAN), (29, 3, BLUE), (40, 3, CYAN), (49, 3, WHITE)],
        [(10, 6, BLUE), (20, 3, CYAN), (28, 3, WHITE), (39, 6, CYAN), (50, 3, BLUE)],
        [(10, 3, CYAN), (17, 3, BLUE), (25, 6, WHITE), (37, 3, CYAN), (45, 3, BLUE)],
    ]
    for top, leds in zip(tops, units):
        c.leds(leds, top + 4, top + 6)
    return c


# ------------------------------------------------------------------ 粗放版 16×16
def build_small():
    """三层板、每层 3 颗 2px 灯——灯少而大，16px 上才还剩得下东西。"""
    c = Canvas(16, 16)
    c.plate(radius=4)
    x0, x1 = 1, 14
    tops = [1, 6, 11]
    for i, top in enumerate(tops):
        c.slab(x0, x1, top, 4, cap=(i == 0))
    units = [
        [(3, 2, CYAN), (7, 2, WHITE), (11, 2, BLUE)],
        [(3, 2, WHITE), (7, 2, BLUE), (11, 2, CYAN)],
        [(3, 2, BLUE), (7, 2, CYAN), (11, 2, WHITE)],
    ]
    for top, leds in zip(tops, units):
        c.leds(leds, top + 1, top + 2)
    return c


def write_svg(which, out):
    if which == "big":
        svg = build_big().svg("能工智人·数据库", 512)
    elif which == "small":
        svg = build_small().svg("能工智人·数据库", 256)
    else:
        raise SystemExit(f"unknown grid: {which}")
    with open(out, "w") as f:
        f.write(svg)
    print("wrote %s (%s)" % (out, which))


def write_ico(out, entries):
    """把若干 PNG 打成 ICO。

    Vista 以后的 ICO 允许每个尺寸直接存 PNG 数据，不必再转 BMP——
    所以这里不做任何格式转换，原样嵌入，像素一个不差。
    entries: [(size, png_path), ...]
    """
    blobs = []
    for size, path in entries:
        with open(path, "rb") as f:
            blobs.append((size, f.read()))

    header = struct.pack("<HHH", 0, 1, len(blobs))     # reserved, type=icon, count
    offset = len(header) + 16 * len(blobs)
    dir_entries, data = b"", b""
    for size, blob in blobs:
        dim = 0 if size >= 256 else size               # 256 在目录里记 0
        dir_entries += struct.pack("<BBBBHHII",
                                   dim, dim, 0, 0, 1, 32, len(blob), offset)
        data += blob
        offset += len(blob)

    with open(out, "wb") as f:
        f.write(header + dir_entries + data)
    print("wrote %s (%s)" % (out, ", ".join("%dpx" % s for s, _ in entries)))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "svg":
        write_svg(sys.argv[2], sys.argv[3])
    elif cmd == "ico":
        entries = []
        for spec in sys.argv[3:]:
            size, path = spec.split(":", 1)
            entries.append((int(size), path))
        write_ico(sys.argv[2], entries)
    else:
        raise SystemExit(__doc__)
