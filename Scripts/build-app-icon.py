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
    from PIL import Image, ImageDraw
except ImportError:                                    # pragma: no cover
    sys.exit("needs Pillow: pip install Pillow")

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Scripts/artwork/AppIcon-source.png"
ICONSET = (ROOT / "App/HipparchusApp/Resources/Assets.xcassets/AppIcon.appiconset")

#: Square region of the render to keep, in source pixels. Chosen so the
#: coastline runs corner to corner rather than sitting flat across the middle:
#: a diagonal reads as a coast at 16 points, where a horizontal reads as a
#: horizon or a scratch.
CROP = (470, 200, 1380, 1110)

#: The canvas, and how much of it the rounded square occupies. Apple's macOS
#: icon grid leaves roughly a tenth of the canvas clear on each side.
CANVAS = 1024
SHAPE_INSET = 100
#: Corner radius as a fraction of the shape's side, matching the system's
#: rounded-rectangle icons closely enough at every size that ships.
CORNER = 0.225

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def main() -> int:
    if not SOURCE.exists():
        sys.exit(f"no source artwork at {SOURCE}")

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
