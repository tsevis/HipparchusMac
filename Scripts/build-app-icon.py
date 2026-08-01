#!/usr/bin/env python3
"""Compose the application icon from the app's own output.

The artwork is Paphos and its sea — coastline, bathymetry and contours in
white on turquoise — rendered by Hipparchus itself in the "Turquoise Sea"
preset. This crops a square out of that render, rounds it to the macOS icon
shape, and writes every size the asset catalogue asks for.

    python3 Scripts/build-app-icon.py

macOS does not mask app icons the way iOS does: the rounded shape and the
padding around it have to be in the pixels. Apple's grid puts a large square
icon at about 80% of the canvas, which is what SHAPE_INSET produces.

Reads Scripts/artwork/AppIcon-source.png and writes into the asset
catalogue. Keeping the untouched render in the repository means the framing
can change later without re-rendering from the app.
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:                                    # pragma: no cover
    sys.exit("needs Pillow and numpy: pip install Pillow numpy")

ROOT = Path(__file__).resolve().parents[1]
#: Two drawings of the same coast, at two weights.
#:
#: Apple ships different artwork per size for exactly this reason. A 3pt
#: coastline is the drawing anyone would want at 512 points and measures
#: nothing at all by 16: scaled by 64, a hairline is a fifth of a pixel. The
#: bold render draws the same coast at 22pt with only its index contours
#: under it, which is what survives being 32 pixels across.
SOURCE = ROOT / "Scripts/artwork/AppIcon-source.png"
SOURCE_BOLD = ROOT / "Scripts/artwork/AppIcon-source-bold.png"

#: Which weight each pixel size is cut from. The catalogue uses 16/32/64 only
#: for the 16pt and 32pt slots, so those are the ones that have to carry.
BOLD_SIZES = {16, 32, 64}
ICONSET = (ROOT / "App/HipparchusApp/Resources/Assets.xcassets/AppIcon.appiconset")

#: How far inside the renderer's frame to start, in source pixels. The frame
#: is a thin white rectangle around the map area; a couple of pixels of margin
#: keeps its antialiasing out of the crop as well as its core.
FRAME_MARGIN = 12

#: The canvas, and how much of it the rounded square occupies. Apple's macOS
#: icon grid leaves roughly a tenth of the canvas clear on each side.
CANVAS = 1024
SHAPE_INSET = 100
#: Corner radius as a fraction of the shape's side, matching the system's
#: rounded-rectangle icons closely enough at every size that ships.
CORNER = 0.225

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def squareInside(image: Image.Image) -> tuple[int, int, int, int]:
    """The largest square of map, with none of the frame around it.

    The renderer draws a thin rectangle around the map area, and one edge of it
    in shot reads as a rule ruled across the icon on purpose. It got in three
    times: hand-written crops that were a few pixels out, and then a detector
    that looked for near-white rows and columns. That detector was wrong twice
    over — a bold near-vertical coastline is white enough down a column to look
    like a frame, and the frame's own horizontal rule spans only the map's
    width, so it reads about 0.67 where the vertical one reads 0.89. No single
    whiteness threshold separates those.

    So the frame is found by shape instead of by colour. The renderer fills the
    whole canvas with the background and draws the map inside it, so everything
    that differs from the background is the map — and the outermost thing in it
    *is* the frame. Its bounding box, inset, is the usable region, whatever
    colour anything happens to be.
    """
    pixels = np.asarray(image).astype(int)
    height, width, _ = pixels.shape
    background = pixels[1, 1]
    drawn = np.abs(pixels - background).sum(axis=2) > 24

    rows = np.nonzero(drawn.any(axis=1))[0]
    columns = np.nonzero(drawn.any(axis=0))[0]
    if rows.size == 0 or columns.size == 0:
        sys.exit("the render is blank — nothing was drawn")

    left = int(columns[0]) + FRAME_MARGIN
    right = int(columns[-1]) - FRAME_MARGIN
    top = int(rows[0]) + FRAME_MARGIN
    bottom = int(rows[-1]) - FRAME_MARGIN

    side = min(right - left, bottom - top)
    if side < 64:
        sys.exit(f"no usable square inside the frame: x {left}..{right}, y {top}..{bottom}")
    cx, cy = (left + right) // 2, (top + bottom) // 2
    return (cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2)


def main() -> int:
    if not SOURCE.exists():
        sys.exit(f"no source artwork at {SOURCE}")

    if not SOURCE_BOLD.exists():
        sys.exit(f"no bold artwork at {SOURCE_BOLD}")

    side = CANVAS - 2 * SHAPE_INSET
    faces, crops = {}, {}
    for weight, path in (("thin", SOURCE), ("bold", SOURCE_BOLD)):
        whole = Image.open(path).convert("RGB")
        crops[weight] = squareInside(whole)
        faces[weight] = whole.crop(crops[weight]).resize((side, side), Image.LANCZOS)

    # The rounded square, drawn at 4x and downsampled: a mask drawn straight
    # at the final size has visibly stepped corners at 512 and above.
    scale = 4
    mask = Image.new("L", (side * scale, side * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, side * scale - 1, side * scale - 1),
        radius=int(side * scale * CORNER),
        fill=255,
    )
    mask = mask.resize((side, side), Image.LANCZOS)

    canvases = {}
    for weight, face in faces.items():
        canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        canvas.paste(face, (SHAPE_INSET, SHAPE_INSET), mask)
        canvases[weight] = canvas

    ICONSET.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        weight = "bold" if size in BOLD_SIZES else "thin"
        canvases[weight].resize((size, size), Image.LANCZOS).save(ICONSET / f"icon_{size}.png")

    small = ", ".join(str(s) for s in sorted(BOLD_SIZES))
    print(f"wrote {len(SIZES)} sizes into {ICONSET.relative_to(ROOT)}")
    for weight, crop in crops.items():
        print(f"  {weight:>4}: crop {crop}")
    print(f"  shape {side}px in {CANVAS}px  radius {CORNER:.3f}")
    print(f"  bold at {small}; thin above")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
