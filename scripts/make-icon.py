#!/usr/bin/env python3
"""Turn the generated logo into a macOS icon set and a menu-bar template."""

import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "assets" / "logo-source.jpg"
ICONSET = ROOT / "assets" / "AppIcon.iconset"
ICNS = ROOT / "assets" / "AppIcon.icns"
TEMPLATE = ROOT / "assets" / "MenuTemplate.png"
TEMPLATE_2X = ROOT / "assets" / "MenuTemplate@2x.png"

# macOS squircle, about 22.37% corner radius on a 1024 canvas.
RADIUS = 229
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def squircle_mask(size: int) -> Image.Image:
    scale = size / 1024
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1),
        radius=RADIUS * scale,
        fill=255,
    )
    return mask


def master() -> Image.Image:
    image = Image.open(SOURCE).convert("RGBA")
    image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    # The generated file has a thin black frame. Inset it before the squircle.
    inset = 14
    cropped = image.crop((inset, inset, 1024 - inset, 1024 - inset))
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.paste(cropped.resize((1024, 1024), Image.Resampling.LANCZOS), (0, 0))
    mask = squircle_mask(1024)
    canvas.putalpha(mask)
    return canvas


def write_iconset(image: Image.Image) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for size in SIZES:
        rendered = image.resize((size, size), Image.Resampling.LANCZOS)
        rendered.save(ICONSET / f"icon_{size}x{size}.png")
        if size <= 512:
            retina = image.resize((size * 2, size * 2), Image.Resampling.LANCZOS)
            retina.save(ICONSET / f"icon_{size}x{size}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)


def write_template(_image: Image.Image) -> None:
    """Drawn cloud and gauge. AppKit tints a black template image."""

    def draw(side: int) -> Image.Image:
        scale = 8
        canvas = side * scale
        mask = Image.new("L", (canvas, canvas), 0)
        pen = ImageDraw.Draw(mask)
        cx = cy = canvas / 2
        ring = canvas * 0.36
        width = max(8, int(canvas * 0.075))
        pen.arc(
            (cx - ring, cy - ring, cx + ring, cy + ring),
            start=200,
            end=520,
            fill=255,
            width=width,
        )
        for ox, oy, radius in ((-0.12, 0.04, 0.13), (0.08, 0.02, 0.15), (0.0, -0.08, 0.12)):
            r = canvas * radius
            x = cx + canvas * ox
            y = cy + canvas * oy
            pen.ellipse((x - r, y - r, x + r, y + r), fill=255)
        small = mask.resize((side, side), Image.Resampling.LANCZOS)
        return Image.merge(
            "RGBA",
            (
                Image.new("L", (side, side), 0),
                Image.new("L", (side, side), 0),
                Image.new("L", (side, side), 0),
                small,
            ),
        )

    draw(18).save(TEMPLATE)
    draw(36).save(TEMPLATE_2X)
    bundled = ROOT / "Sources" / "QuotaBar" / "Resources"
    bundled.mkdir(parents=True, exist_ok=True)
    draw(18).save(bundled / "MenuTemplate.png")
    draw(36).save(bundled / "MenuTemplate@2x.png")


def main() -> None:
    image = master()
    image.save(ROOT / "assets" / "AppIcon-1024.png")
    write_iconset(image)
    write_template(image)
    print(ICNS)
    print(TEMPLATE)


if __name__ == "__main__":
    main()
