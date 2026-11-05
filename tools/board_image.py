#!/usr/bin/env python3
"""Documents/LCAC-2048_over.log の 1 ゲーム分から、ゲームと同じ見た目の盤面画像を作る。

使い方:

    python3 tools/board_image.py LCAC-2048_over.log              # 最後のゲーム
    python3 tools/board_image.py LCAC-2048_over.log --list       # 記録の一覧
    python3 tools/board_image.py LCAC-2048_over.log --block 12   # 12 番目 (1 始まり)
    python3 tools/board_image.py - < block.txt                   # 1 ブロックを貼り付けて渡す
    python3 tools/board_image.py LCAC-2048_over.log --block -1 --format svg

- 画像は PNG (Pillow が必要) か SVG (追加のインストール不要) で出す。
  指定なし (`--format auto`) は Pillow があれば PNG、無ければ SVG。
- `--half` を付けると、画面に出ている値 (内部値の 1/2) で描く。
  4 固定のビルドではゲームの内部値と画面の数字が 1 段ずれることがあるため。
- `--scale 2` で 2 倍の大きさ (Retina 向け)。`--out` で出力先を指定できる。
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# ゲーム (2048) と同じ配色。
BG = "#faf8ef"
BOARD = "#bbada0"
CELL_COLOR = "#cdc1b4"
TEXT_DARK = "#776e65"
TEXT_MUTED = "#8f8579"
TEXT_LIGHT = "#f9f6f2"
TILE_COLORS = {
    2: "#eee4da",
    4: "#ede0c8",
    8: "#f2b179",
    16: "#f59563",
    32: "#f67c5f",
    64: "#f65e3b",
    128: "#edcf72",
    256: "#edcc61",
    512: "#edc850",
    1024: "#edc53f",
    2048: "#edc22e",
}
TILE_DARK_TEXT = {2, 4}  # 薄いタイルは濃い文字
TILE_HIGH = "#3c3a32"  # 4096 以上

FONT_CANDIDATES_BOLD = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/SFNSDisplay-Bold.otf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "C:/Windows/Fonts/arialbd.ttf",
    "C:/Windows/Fonts/arial.ttf",
]

# レイアウト (scale 1 の値)。
CELL = 120
GAP = 12
MARGIN = 24
TITLE_H = 96
FOOTER_H = 62
BOARD_W = 4 * CELL + 5 * GAP
BOARD_H = 4 * CELL + 5 * GAP


class Block:
    """ゲームオーバー 1 回分。"""

    def __init__(self, time_text: str, version: str, score, rows):
        self.time_text = time_text
        self.version = version
        self.score = score
        self.rows = rows

    @property
    def max_tile(self) -> int:
        return max((v for row in self.rows for v in row), default=0)

    @property
    def empties(self) -> int:
        return sum(1 for row in self.rows for v in row if v == 0)

    def summary(self, half: bool = False) -> str:
        fmt = (lambda v: v // 2 if half else v)
        top = fmt(self.max_tile)
        score = "?" if self.score is None else f"{self.score:,}"
        return f"{self.time_text} {self.version} スコア {score} 最大タイル {top}"


HEADER_RE = re.compile(r"^(?P<time>.*?)\s+(?P<version>v[\w.\-]+)\s+score=(?P<score>-?\d+)\s*$")


def parse_blocks(text: str) -> list[Block]:
    """空行で区切られたブロックを読む。途中で切れた最後のブロックも読めるだけ読む。"""
    blocks = []
    for chunk in re.split(r"\n\s*\n", text.strip()):
        lines = [ln.rstrip() for ln in chunk.splitlines() if ln.strip()]
        if not lines:
            continue
        m = HEADER_RE.match(lines[0].strip())
        if not m:
            # 時刻の書式が変わっていても、版とスコアだけ拾えれば描ける。
            version = re.search(r"\bv[\w.\-]+", lines[0])
            score = re.search(r"score=(-?\d+)", lines[0])
            time_text = lines[0].split(version.group(0))[0].strip() if version else lines[0].strip()
            if not score:
                continue
            header = (time_text, version.group(0) if version else "?", int(score.group(1)))
        else:
            header = (m.group("time").strip(), m.group("version"), int(m.group("score")))

        rows = []
        for line in lines[1:]:
            cells = [int(tok) for tok in re.findall(r"-?\d+", line)][:4]
            if not cells:
                continue
            rows.append((cells + [0] * 4)[:4])
            if len(rows) == 4:
                break
        if not rows:
            continue
        while len(rows) < 4:  # 書き込み途中で切れたブロック
            rows.append([0, 0, 0, 0])
        blocks.append(Block(header[0], header[1], header[2], rows))
    return blocks


def tile_face(value: int, half: bool):
    """(描く数字, 背景色, 文字色) を返す。"""
    shown = value // 2 if half else value
    color = TILE_COLORS.get(shown, TILE_HIGH)
    text = TEXT_DARK if shown in TILE_DARK_TEXT else TEXT_LIGHT
    return shown, color, text


def tile_font_size(digits: int) -> int:
    if digits <= 2:
        return 46
    if digits == 3:
        return 40
    if digits == 4:
        return 32
    if digits == 5:
        return 26
    if digits == 6:
        return 22
    return 18


def caption_lines(block: Block, half: bool) -> list[str]:
    """画像の下に出す 2 行。文字化けを避けるため、画像内の文字は英字だけにする。"""
    score = "?" if block.score is None else f"{block.score:,}"
    top = block.max_tile // 2 if half else block.max_tile
    note = "screen values" if half else "raw board values"
    return [
        f"{block.version}   {display_time(block.time_text)}",
        f"score {score}    max tile {top:,}    empty {block.empties}    ({note})",
    ]


def display_time(text: str) -> str:
    """「午前 10:57」を AM / PM に直す (画像内を ASCII だけにするため)。"""
    return text.replace("午前", "AM ").replace("午後", "PM ")


def find_font_path() -> str | None:
    for path in FONT_CANDIDATES_BOLD:
        if os.path.exists(path):
            return path
    return None


def render_png(block: Block, path: str, half: bool, scale: float) -> None:
    from PIL import Image, ImageDraw, ImageFont

    def px(v: float) -> int:
        return int(round(v * scale))

    width = px(BOARD_W + 2 * MARGIN)
    height = px(MARGIN + TITLE_H + BOARD_H + FOOTER_H + MARGIN)
    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)
    font_path = find_font_path()

    def font(size: float):
        if font_path:
            return ImageFont.truetype(font_path, px(size))
        try:
            return ImageFont.load_default(px(size))
        except TypeError:  # 古い Pillow
            return ImageFont.load_default()

    # タイトルとスコア (ゲームの HUD と同じ並び)。
    draw.text((px(MARGIN), px(MARGIN + 6)), "2048", font=font(62), fill=TEXT_DARK)
    box_w, box_h = px(168), px(64)
    box_x = px(MARGIN + BOARD_W) - box_w
    box_y = px(MARGIN)
    draw.rounded_rectangle([box_x, box_y, box_x + box_w, box_y + box_h], radius=px(6), fill=BOARD)
    draw.text((box_x + box_w / 2, box_y + px(20)), "SCORE", font=font(15), fill="#eee4da", anchor="mm")
    score_text = "?" if block.score is None else f"{block.score:,}"
    draw.text((box_x + box_w / 2, box_y + px(42)), score_text, font=font(30), fill=TEXT_LIGHT, anchor="mm")

    # 盤面。
    top = px(MARGIN + TITLE_H)
    draw.rounded_rectangle([px(MARGIN), top, px(MARGIN + BOARD_W), top + px(BOARD_H)], radius=px(10), fill=BOARD)
    for y, row in enumerate(block.rows):
        for x, value in enumerate(row):
            left = px(MARGIN + GAP + x * (CELL + GAP))
            upper = top + px(GAP + y * (CELL + GAP))
            right, lower = left + px(CELL), upper + px(CELL)
            draw.rounded_rectangle([left, upper, right, lower], radius=px(8), fill=CELL_COLOR)
            if value <= 0:
                continue
            shown, color, text = tile_face(value, half)
            draw.rounded_rectangle([left, upper, right, lower], radius=px(8), fill=color)
            draw.text(
                ((left + right) / 2, (upper + lower) / 2),
                str(shown),
                font=font(tile_font_size(len(str(shown)))),
                fill=text,
                anchor="mm",
            )

    # 版・時刻・スコアの説明。盤面の幅に収まるよう、入りきらない行だけ小さくする。
    line1, line2 = caption_lines(block, half)
    base = top + px(BOARD_H) + px(16)

    def fitted(text_line: str, size: float):
        for candidate in (size, size - 1, size - 2, size - 3, size - 4):
            if candidate < 10:
                break
            f = font(candidate)
            if draw.textlength(text_line, font=f) <= px(BOARD_W):
                return f
        return font(max(size - 4, 10))

    draw.text((px(MARGIN), base), line1, font=fitted(line1, 15), fill=TEXT_MUTED)
    draw.text((px(MARGIN), base + px(24)), line2, font=fitted(line2, 16), fill=TEXT_DARK)

    img.save(path)


def render_svg(block: Block, path: str, half: bool, scale: float) -> None:
    sans = "Helvetica, Arial, 'Hiragino Sans', 'Noto Sans JP', sans-serif"
    width = (BOARD_W + 2 * MARGIN) * scale
    height = (MARGIN + TITLE_H + BOARD_H + FOOTER_H + MARGIN) * scale
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{height:.0f}" '
        f'viewBox="0 0 {width:.0f} {height:.0f}" font-family="{sans}">',
        f'<rect width="{width:.0f}" height="{height:.0f}" fill="{BG}"/>',
    ]

    def rect(x, y, w, h, r, fill):
        out.append(
            f'<rect x="{x * scale:.1f}" y="{y * scale:.1f}" width="{w * scale:.1f}" '
            f'height="{h * scale:.1f}" rx="{r * scale:.1f}" fill="{fill}"/>'
        )

    def text(x, y, s, size, fill, anchor="start"):
        out.append(
            f'<text x="{x * scale:.1f}" y="{y * scale:.1f}" font-size="{size * scale:.1f}" '
            f'fill="{fill}" text-anchor="{anchor}" dominant-baseline="central">{s}</text>'
        )

    text(MARGIN, MARGIN + 36, "2048", 62, TEXT_DARK)
    box_w, box_h = 168, 64
    box_x = MARGIN + BOARD_W - box_w
    rect(box_x, MARGIN, box_w, box_h, 6, BOARD)
    text(box_x + box_w / 2, MARGIN + 20, "SCORE", 15, "#eee4da", "middle")
    score_text = "?" if block.score is None else f"{block.score:,}"
    text(box_x + box_w / 2, MARGIN + 42, score_text, 30, TEXT_LIGHT, "middle")

    top = MARGIN + TITLE_H
    rect(MARGIN, top, BOARD_W, BOARD_H, 10, BOARD)
    for y, row in enumerate(block.rows):
        for x, value in enumerate(row):
            left = MARGIN + GAP + x * (CELL + GAP)
            upper = top + GAP + y * (CELL + GAP)
            rect(left, upper, CELL, CELL, 8, CELL_COLOR)
            if value <= 0:
                continue
            shown, color, fill = tile_face(value, half)
            rect(left, upper, CELL, CELL, 8, color)
            text(left + CELL / 2, upper + CELL / 2, str(shown), tile_font_size(len(str(shown))), fill, "middle")

    line1, line2 = caption_lines(block, half)
    base = top + BOARD_H + 16
    text(MARGIN, base + 8, line1, 15, TEXT_MUTED)
    text(MARGIN, base + 32, line2, 16, TEXT_DARK)

    out.append("</svg>")
    with open(path, "w", encoding="utf-8") as fp:
        fp.write("\n".join(out) + "\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="LCAC-2048_over.log の 1 ゲーム分から盤面画像を作る",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="例:\n"
        "  python3 tools/board_image.py LCAC-2048_over.log --list\n"
        "  python3 tools/board_image.py LCAC-2048_over.log --block 3 --scale 2\n"
        "  python3 tools/board_image.py - < block.txt\n",
    )
    parser.add_argument("log", help="ログファイル (stdin は -)")
    parser.add_argument("--block", type=int, default=None, help="何番目のゲームか (1 始まり、-1 で最後)")
    parser.add_argument("--list", action="store_true", help="記録されているゲームを一覧するだけで終わる")
    parser.add_argument("--out", default=None, help="出力ファイル (既定: ログと同じ場所に board_<n>.png)")
    parser.add_argument("--format", choices=["auto", "png", "svg"], default="auto")
    parser.add_argument("--half", action="store_true", help="画面に出ている値 (内部値の 1/2) で描く")
    parser.add_argument("--scale", type=float, default=1.0, help="倍率 (Retina 向けは 2)")
    args = parser.parse_args(argv)

    if args.log == "-":
        text = sys.stdin.read()
        origin = None
    else:
        with open(args.log, encoding="utf-8", errors="replace") as fp:
            text = fp.read()
        origin = args.log

    blocks = parse_blocks(text)
    if not blocks:
        print("ゲームの記録が見つかりませんでした (score= の行と 4 行の盤面が要ります)", file=sys.stderr)
        return 1

    if args.list:
        for i, block in enumerate(blocks, 1):
            print(f"{i:3d}. {block.summary(args.half)}")
        return 0

    index = -1 if args.block is None else args.block
    if index == -1:
        block = blocks[-1]
        number = len(blocks)
    else:
        if not 1 <= index <= len(blocks):
            print(f"--block は 1〜{len(blocks)} で指定してください", file=sys.stderr)
            return 1
        block = blocks[index - 1]
        number = index

    fmt = args.format
    if fmt == "auto":
        try:
            import PIL  # noqa: F401

            fmt = "png"
        except ImportError:
            fmt = "svg"

    if args.out:
        out_path = args.out
    else:
        base = os.path.splitext(os.path.basename(origin))[0] if origin else "block"
        out_path = f"{base}_{number}.{fmt}"

    if fmt == "png":
        try:
            render_png(block, out_path, args.half, args.scale)
        except ImportError:
            print("Pillow がありません。`pip install pillow` か --format svg を使ってください", file=sys.stderr)
            return 1
    else:
        render_svg(block, out_path, args.half, args.scale)

    print(f"{number}/{len(blocks)}: {block.summary(args.half)}")
    print(out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
