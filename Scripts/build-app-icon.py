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
SOURCE = ROOT / "Scripts/artwork/AppIcon-source.png"
ICONSET = (ROOT / "App/HipparchusApp/Resources/Assets.xcassets/AppIcon.appiconset")

#: Square region of the render to keep, in source pixels.
#:
#: Every edge is inside the frame the renderer draws around the map. That
#: frame is a white rule, and one edge of it in shot reads as a line ruling
#: off the sea — which is exactly what it did in the first two attempts. The
#: bounds are found in the image below rather than written down here, because
#: they move whenever the export size or the area changes.
CROP = (260, 120, 1260, 1120)

#: The canvas, and how much of it the rounded square occupies. Apple's macOS
#: icon grid leaves roughly a tenth of the canvas clear on each side.
CANVAS = 1024
SHAPE_INSET = 100
#: Corner radius as a fraction of the shape's side, matching the system's
#: rounded-rectangle icons closely enough at every size that ships.
CORNER = 0.225

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def verify_inside_frame(image: Image.Image) -> None:
    """Refuse a crop that would put the renderer's own frame in the icon.

    The frame is a thin white rectangle around the map area. Cropping across
    one of its edges leaves a bright rule down the side of the icon that looks
    like a border someone drew on purpose, and it is easy to reintroduce by
    nudging the crop a few pixels. Checked rather than remembered.
    """
    pixels = np.asarray(image).astype(int)
    height, width, _ = pixels.shape
    white = pixels.min(axis=2) > 235
    columns = [x for x in range(width) if white[:, x].mean() > 0.30]
    rows = [y for y in range(height) if white[y, :].mean() > 0.30]

    for x in columns:
        if CROP[0] <= x <= CROP[2]:
            sys.exit(f"crop {CROP} crosses the frame's vertical rule at x={x}")
    for y in rows:
        if CROP[1] <= y <= CROP[3]:
            sys.exit(f"crop {CROP} crosses the frame's horizontal rule at y={y}")


def main() -> int:
    if not SOURCE.exists():
        sys.exit(f"no source artwork at {SOURCE}")

    whole = Image.open(SOURCE).convert("RGB")
    verify_inside_frame(whole)

    art = Image.open(SOURCE).convert("RGB").crop(CROP)
    side = CANVAS - 2 * SHAPE_INSET
    art = art.resize((side, side), Image.LANCZOS)

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

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.paste(art, (SHAPE_INSET, SHAPE_INSET), mask)

    ICONSET.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        out = canvas.resize((size, size), Image.LANCZOS)
        out.save(ICONSET / f"icon_{size}.png")

    print(f"wrote {len(SIZES)} sizes into {ICONSET.relative_to(ROOT)}")
    print(f"  crop {CROP}  shape {side}px in {CANVAS}px  radius {CORNER:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
