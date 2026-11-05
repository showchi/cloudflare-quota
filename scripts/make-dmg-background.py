#!/usr/bin/env python3
"""Arrow between the app icon and the Applications alias."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parents[1]
path = root / "assets" / "dmg-background.png"
image = Image.new("RGB", (680, 400), (245, 245, 247))
pen = ImageDraw.Draw(image)
pen.rounded_rectangle((210, 186, 450, 206), radius=2, fill=(186, 186, 192))
pen.polygon([(430, 186), (470, 196), (430, 206)], fill=(130, 130, 138))
font = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", 18)
label = "拖到右边的应用程序"
bbox = pen.textbbox((0, 0), label, font=font)
width = bbox[2] - bbox[0]
pen.text(((680 - width) / 2, 250), label, fill=(110, 110, 116), font=font)
path.parent.mkdir(exist_ok=True)
image.save(path)
