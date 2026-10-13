#!/usr/bin/env python3
"""Regenerates Resources/AppIcon.icns.

Run with any Python that has Pillow, then iconutil (both ship with macOS
tooling, /usr/bin/iconutil is always present):

    python3 scripts/make-icon.py && bash scripts/make-icon.sh

or just `bash scripts/make-icon.sh`, which does both.
"""

import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
INSET = int(SIZE * 0.095)
BOX = (INSET, INSET, SIZE - INSET, SIZE - INSET)
WIDTH = BOX[2] - BOX[0]
HEIGHT = BOX[3] - BOX[1]
RADIUS = int(WIDTH * 0.225)

RED = (216, 54, 64, 255)
BLUE = (28, 115, 217, 255)
GRID = (204, 213, 232, 255)
AXIS = (104, 116, 140, 255)


def rounded_mask():
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(BOX, radius=RADIUS, fill=255)
    return mask


def plate(mask):
    """A very slightly tinted sheet, rounded to the platform's icon shape."""
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for y in range(BOX[1], BOX[3] + 1):
        t = (y - BOX[1]) / HEIGHT
        draw.line(
            [(BOX[0], y), (BOX[2], y)],
            fill=(int(255 - 16 * t), int(255 - 14 * t), int(255 - 2 * t), 255),
        )
    image.putalpha(mask)
    return image


def stamp(draw, points, colour, width):
    """Paints a thick polyline by stamping discs.

    PIL's joint handling leaves notches on heavy strokes, and a graph icon is
    nothing but heavy strokes.
    """
    radius = width / 2
    step = max(1.0, width / 5)
    for index in range(len(points) - 1):
        (x0, y0), (x1, y1) = points[index], points[index + 1]
        count = max(1, int(math.hypot(x1 - x0, y1 - y0) / step))
        for k in range(count + 1):
            t = k / count
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            draw.ellipse([x - radius, y - radius, x + radius, y + radius], fill=colour)


def artwork(mask):
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    centre_x = BOX[0] + WIDTH / 2
    centre_y = BOX[1] + HEIGHT / 2
    unit = WIDTH / 7.2

    def sx(u):
        return centre_x + u * unit

    def sy(v):
        return centre_y - v * unit

    for k in range(-4, 5):
        if k == 0:
            continue
        draw.line([(sx(k), sy(-3.4)), (sx(k), sy(3.4))], fill=GRID, width=3)
        draw.line([(sx(-3.4), sy(k)), (sx(3.4), sy(k))], fill=GRID, width=3)

    draw.line([(BOX[0] + 16, sy(0)), (BOX[2] - 16, sy(0))], fill=AXIS, width=8)
    draw.line([(sx(0), BOX[1] + 16), (sx(0), BOX[3] - 16)], fill=AXIS, width=8)

    parabola = [(sx(u), sy(0.42 * u * u - 1.85)) for u in (-3.15 + 6.3 * k / 220 for k in range(221))]
    stamp(draw, parabola, BLUE, 34)

    wave = [(sx(u), sy(1.85 * math.sin(u * 2.05))) for u in (-3.15 + 6.3 * k / 300 for k in range(301))]
    stamp(draw, wave, RED, 34)

    image.putalpha(ImageChops.multiply(image.getchannel("A"), mask))
    return image


ICONSET = "Sources/GrapherApp/Resources/Assets.xcassets/AppIcon.appiconset"
ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)

# 1x/2x 成对复用同一张图，跟 FreeMind / Perch 的 AppIcon.appiconset 一致。
CONTENTS_JSON = """{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

ASSETS_JSON = """{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""


def main():
    mask = rounded_mask()

    icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (BOX[0], BOX[1] + int(SIZE * 0.014), BOX[2], BOX[3] + int(SIZE * 0.014)),
        radius=RADIUS,
        fill=(24, 34, 60, 120),
    )
    icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(SIZE * 0.02)))
    icon = Image.alpha_composite(icon, plate(mask))
    icon = Image.alpha_composite(icon, artwork(mask))

    assets = os.path.dirname(ICONSET)
    os.makedirs(ICONSET, exist_ok=True)
    for size in ICON_SIZES:
        icon.resize((size, size), Image.LANCZOS).save(f"{ICONSET}/icon_{size}.png")
    with open(f"{ICONSET}/Contents.json", "w") as handle:
        handle.write(CONTENTS_JSON)
    with open(f"{assets}/Contents.json", "w") as handle:
        handle.write(ASSETS_JSON)
    print(f"wrote {ICONSET} ({len(ICON_SIZES)} sizes)")


if __name__ == "__main__":
    main()
