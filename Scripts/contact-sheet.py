#!/usr/bin/env python3
"""把一批截图拼成 contact sheet（缩略图网格），供视觉模型一次性快速扫描定位问题。

用法：
    python3 Scripts/contact-sheet.py <截图目录> <输出.png> [--cols 6] [--thumb 360]
"""
import sys, os, argparse
from PIL import Image, ImageDraw, ImageFont

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("out")
    ap.add_argument("--cols", type=int, default=6)
    ap.add_argument("--thumb", type=int, default=360)
    args = ap.parse_args()

    files = sorted(f for f in os.listdir(args.dir) if f.endswith(".png"))
    if not files:
        print("无截图"); return

    cols = args.cols
    thumb_w = args.thumb
    label_h = 28
    # 缩略图高度按比例
    first = Image.open(os.path.join(args.dir, files[0]))
    ratio = first.height / first.width
    thumb_h = int(thumb_w * ratio)

    rows = (len(files) + cols - 1) // cols
    cell_w = thumb_w
    cell_h = thumb_h + label_h
    sheet = Image.new("RGB", (cols * cell_w, rows * cell_h), (255, 255, 255))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 20)
    except Exception:
        font = ImageFont.load_default()

    for i, f in enumerate(files):
        im = Image.open(os.path.join(args.dir, f)).convert("RGB")
        im.thumbnail((thumb_w, thumb_h))
        x = (i % cols) * cell_w
        y = (i // cols) * cell_h
        sheet.paste(im, (x, y))
        draw.rectangle([x, y, x + cell_w - 1, y + cell_h - 1], outline=(200, 200, 200))
        draw.text((x + 4, y + thumb_h + 4), f"{i:02d} {f}", fill=(0, 0, 0), font=font)

    sheet.save(args.out)
    print(f"{len(files)} 张 → {args.out} ({sheet.width}x{sheet.height})")

if __name__ == "__main__":
    main()
