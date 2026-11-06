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
- 盤面の向き: ログはゲームの座標順 (y=0 が画面の**最下段**) で書かれているため、
  画像では上下を反転して画面と同じ向きに描く。ログと同じ順で見たいときは `--raw-order`。
- 数字はログに入っている値そのもの (ゲームの内部値) で描く。画面と同じにしたいときは
  `--spawn2` を付けると、**4 のタイルだけ 2 と表示**する (4 固定のビルドでは、2 のマスを
  4 に書き換えても画面が描き直されないため、出現した 4 だけが 2 のまま見える)。
- `--scale 2` で 2 倍の大きさ (Retina 向け)。`--out` で出力先を指定できる。

配色は**ゲーム本体 (com.ketchapp.2048 4.0.8) の実機スクリーンショットから採取**した値です
(2026-11-05 採取)。伝統的な 2048 の配色 (64 = #f65e3b など) より少し暗くくすんだ色で、
盤面の枠や空きマスも実機の値に合わせています。

    タイル   実機の色      タイル    実機の色
    --------------------------------------------
    2        #ece4db      128       #efd97b
    4        #ebe0cc      256       #edd164
    8        #e9b482      512       #dec14b
    16       #df925f      1024      #dbbb42
    32       #e78266      2048      #e6c542 (ロゴのタイルから採取)
    64       #da6343      4096      #81d79a (薄い緑)
                          8192      #5bb96f (緑)

    背景 #f9f7f0 / 盤面の枠 #b9ada1 / 空きマス #cac0b5

16,384 以上はまだ実機で見ていないため未採取で、濃いグレー (#3c3a32) のままです。
実機で出たら、その部分の色を採取して TILE_COLORS に足してください。
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# 配色はすべて実機 (com.ketchapp.2048 4.0.8) のスクリーンショットから採取した値。
# 上 (docstring) に一覧がある。16,384 だけは未採取。
BG = "#f9f7f0"  # 画面の背景
BOARD = "#b9ada1"  # 盤面の枠・スコア枠
CELL_COLOR = "#cac0b5"  # 空きマス
TEXT_DARK = "#71685f"  # 2 / 4 の数字
TEXT_MUTED = "#8f8579"  # 画像下の小さい文字
TEXT_LIGHT = "#ffffff"  # 8 以上の数字
TILE_COLORS = {
    2: "#ece4db",
    4: "#ebe0cc",
    8: "#e9b482",
    16: "#df925f",
    32: "#e78266",
    64: "#da6343",
    128: "#efd97b",
    256: "#edd164",
    512: "#dec14b",
    1024: "#dbbb42",
    2048: "#e6c542",  # 実機の 2048 ロゴのタイルから採取
    4096: "#81d79a",
    8192: "#5bb96f",
}
TILE_DARK_TEXT = {2, 4}  # 薄いタイルは濃い文字
TILE_HIGH = "#3c3a32"  # 16,384 以上 (ゲーム側の色が未確認のため濃いグレー)

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

    def __init__(self, time_text: str, version: str, score, rows, moves=None):
        self.time_text = time_text
        self.version = version
        self.score = score
        self.rows = rows
        self.moves = moves

    @property
    def max_tile(self) -> int:
        return max((v for row in self.rows for v in row), default=0)

    @property
    def empties(self) -> int:
        return sum(1 for row in self.rows for v in row if v == 0)

    def summary(self, spawn2: bool = False) -> str:
        top = 2 if (spawn2 and self.max_tile == 4) else self.max_tile
        score = "?" if self.score is None else f"{self.score:,}"
        line = f"{self.time_text} {self.version} スコア {score} 最大タイル {top}"
        if self.moves is not None:
            line += f" 手数 {self.moves:,}"
        return line


HEADER_RE = re.compile(
    r"^(?P<time>.*?)\s+(?P<version>v[\w.\-]+)\s+score=(?P<score>-?\d+)(?:\s+moves=(?P<moves>\d+))?\s*$"
)


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
            moves = re.search(r"moves=(\d+)", lines[0])
            time_text = lines[0].split(version.group(0))[0].strip() if version else lines[0].strip()
            if not score:
                continue
            header = (
                time_text,
                version.group(0) if version else "?",
                int(score.group(1)),
                int(moves.group(1)) if moves else None,
            )
        else:
            header = (m.group("time").strip(), m.group("version"), int(m.group("score")),
                      int(m.group("moves")) if m.group("moves") else None)

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
        blocks.append(Block(header[0], header[1], header[2], rows, header[3]))
    return blocks


def tile_face(value: int, spawn2: bool):
    """(描く数字, 背景色, 文字色) を返す。

    spawn2 のときは、出現した 4 のマスだけ画面と同じく 2 として描く。
    (4 固定はゲームのセルを 2 -> 4 に書き換えるが、画面は描き直されないため)
    """
    shown = 2 if (spawn2 and value == 4) else value
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


def caption_lines(block: Block, spawn2: bool) -> list[str]:
    """画像の下に出す 2 行。文字化けを避けるため、画像内の文字は英字だけにする。"""
    score = "?" if block.score is None else f"{block.score:,}"
    top = 2 if (spawn2 and block.max_tile == 4) else block.max_tile
    note = "as shown (4 -> 2)" if spawn2 else "board values"
    moves = f"moves {block.moves:,}    " if block.moves is not None else ""
    return [
        f"{block.version}   {display_time(block.time_text)}",
        f"score {score}    max tile {top:,}    {moves}empty {block.empties}    ({note})",
    ]


def display_time(text: str) -> str:
    """「午前 10:57」を AM / PM に直す (画像内を ASCII だけにするため)。"""
    return text.replace("午前", "AM ").replace("午後", "PM ")


def find_font_path() -> str | None:
    for path in FONT_CANDIDATES_BOLD:
        if os.path.exists(path):
            return path
    return None


def board_rows(block: Block, raw_order: bool):
    """画像に描く順の行。(ログは最下段が先頭なので、既定では上下を反転する)"""
    return list(block.rows) if raw_order else list(reversed(block.rows))


def render_png(block: Block, path: str, spawn2: bool, scale: float, raw_order: bool = False) -> None:
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
    for y, row in enumerate(board_rows(block, raw_order)):
        for x, value in enumerate(row):
            left = px(MARGIN + GAP + x * (CELL + GAP))
            upper = top + px(GAP + y * (CELL + GAP))
            right, lower = left + px(CELL), upper + px(CELL)
            draw.rounded_rectangle([left, upper, right, lower], radius=px(8), fill=CELL_COLOR)
            if value <= 0:
                continue
            shown, color, text = tile_face(value, spawn2)
            draw.rounded_rectangle([left, upper, right, lower], radius=px(8), fill=color)
            draw.text(
                ((left + right) / 2, (upper + lower) / 2),
                str(shown),
                font=font(tile_font_size(len(str(shown)))),
                fill=text,
                anchor="mm",
            )

    # 版・時刻・スコアの説明。盤面の幅に収まるよう、入りきらない行だけ小さくする。
    line1, line2 = caption_lines(block, spawn2)
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


def render_svg(block: Block, path: str, spawn2: bool, scale: float, raw_order: bool = False) -> None:
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
    for y, row in enumerate(board_rows(block, raw_order)):
        for x, value in enumerate(row):
            left = MARGIN + GAP + x * (CELL + GAP)
            upper = top + GAP + y * (CELL + GAP)
            rect(left, upper, CELL, CELL, 8, CELL_COLOR)
            if value <= 0:
                continue
            shown, color, fill = tile_face(value, spawn2)
            rect(left, upper, CELL, CELL, 8, color)
            text(left + CELL / 2, upper + CELL / 2, str(shown), tile_font_size(len(str(shown))), fill, "middle")

    line1, line2 = caption_lines(block, spawn2)
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
    parser.add_argument("--spawn2", action="store_true", help="画面と同じく、出現した 4 を 2 として描く")
    parser.add_argument("--raw-order", action="store_true", help="ログの順 (最下段が先頭) のまま描く")
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
            print(f"{i:3d}. {block.summary(args.spawn2)}")
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
            render_png(block, out_path, args.spawn2, args.scale, args.raw_order)
        except ImportError:
            print("Pillow がありません。`pip install pillow` か --format svg を使ってください", file=sys.stderr)
            return 1
    else:
        render_svg(block, out_path, args.spawn2, args.scale, args.raw_order)

    print(f"{number}/{len(blocks)}: {block.summary(args.spawn2)}")
    print(out_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
