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
#: Centred on the coastline rather than on the canvas, and inside the frame
#: the renderer draws — the frame lines sit at x=245..250 and y=1125..1130 in
#: this export, and either one in shot reads as a stray rule across the icon.
#: The coastline's own centre of mass is near (813, 624), so a 1000px square
#: about that point holds the headland and its harbour with sea on both sides.
FRAME_MARGIN = 256
CROP = (313, 124, 1313, 1124)

#: The canvas, and how much of it the rounded square occupies. Apple's macOS
#: icon grid leaves roughly a tenth of the canvas clear on each side.
CANVAS = 1024
SHAPE_INSET = 100
#: Corner radius as a fraction of the shape's side, matching the system's
#: rounded-rectangle icons closely enough at every size that ships.
CORNER = 0.225

SIZES = [16, 32, 64, 128, 256, 512, 1024]


#: How far the coastline is smoothed before it becomes an icon, in source
#: pixels of blur radius.
SMOOTHING = 9


def evened(art: Image.Image) -> Image.Image:
    """Redraw the coastline as one even line.

    A coastline is hundreds of short segments, each stroked and each with its
    own caps, so at icon weight the overlaps read as beads on a rope rather
    than as a line — obvious at 512 and 1024, invisible below. Blurring the
    white mask and thresholding it back rebuilds a line of constant width
    without moving where it runs: the bulges average out against the gaps
    beside them, and anything that survives the threshold was the line.
    """
    pixels = np.asarray(art).astype(np.float32)
    ink = Image.fromarray((pixels.min(axis=2) > 200).astype(np.uint8) * 255, mode="L")
    ink = ink.filter(ImageFilter.GaussianBlur(SMOOTHING))
    mask = ink.point(lambda v: 255 if v > 96 else 0)

    sea = np.asarray(art)[8, 8]
    out = Image.new("RGB", art.size, tuple(int(v) for v in sea))
    out.paste(Image.new("RGB", art.size, (255, 255, 255)), (0, 0), mask)
    return out


def main() -> int:
    if not SOURCE.exists():
        sys.exit(f"no source artwork at {SOURCE}")

    art = evened(Image.open(SOURCE).convert("RGB").crop(CROP))
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
