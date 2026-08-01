#!/usr/bin/env python3
"""Crop and tone the About window's key art.

The source is the application's own output — Cyprus in the Monochrome Figure
Ground preset, exported whole. The About window wants a wide band rather
than the whole island, so this crops to the southwest around Paphos, drops
the northern coast entirely, and darkens the sea a little so white type and
white contour lines both hold up against it.

    python3 Scripts/crop-about-artwork.py

Reads Scripts/artwork/CyprusAbout-source.png and writes the cropped result
into the asset catalogue. Keeping the untouched export in the repository
means the framing can be changed later without re-exporting from the app.
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError:                                    # pragma: no cover
    sys.exit("needs Pillow and numpy: pip install Pillow numpy")

ROOT = Path(__file__).resolve().parents[1]
#: The untouched export lives outside the asset catalogue on purpose: a
#: stray file inside an .imageset is an "unassigned child" warning at build.
SOURCE = ROOT / "Scripts/artwork/CyprusAbout-source.png"
TARGET = (ROOT / "App/HipparchusApp/Resources/Assets.xcassets"
          / "CyprusAbout.imageset/CyprusAbout.png")

#: Region of the full-island export to keep, in source pixels.
#: Left edge starts just off the west coast so Paphos sits in from the
#: margin; the top is below the Troodos ridge, so the northern half of the
#: island and its long sea gap never appear.
#:
#: Every edge sits *inside* the frame the renderer draws around the map —
#: white lines at x=57 and x=1222, y=116 and y=843 in this export. The first
#: version began at x=40, which put the left frame line in shot as a bright
#: vertical rule down the splash. The bounds are asserted below rather than
#: trusted, because the frame moves if the export size ever changes.
FRAME = (57, 116, 1222, 843)
CROP = (60, 470, 1012, 842)

#: The About header is 640x250pt, so 2x wants 1280x500.
OUTPUT = (1280, 500)

#: Gamma applied to darken the sea. Greater than 1 pulls the midtones down
#: while leaving 255 at 255, so the white coastline and contours stay white
#: and gain contrast rather than going grey with everything else.
GAMMA = 2.0


def main() -> int:
    if not SOURCE.exists():
        sys.exit(f"no source artwork at {SOURCE}")

    image = Image.open(SOURCE).convert("RGB")
    if not (CROP[0] > FRAME[0] and CROP[1] > FRAME[1]
            and CROP[2] < FRAME[2] and CROP[3] < FRAME[3]):
        sys.exit(f"crop {CROP} touches the rendered frame {FRAME} — "
                 "its border would show as a line across the artwork")
    expected = (CROP[2] - CROP[0]) / (CROP[3] - CROP[1])
    if abs(expected - OUTPUT[0] / OUTPUT[1]) > 0.01:
        sys.exit(f"crop aspect {expected:.3f} does not match output "
                 f"{OUTPUT[0] / OUTPUT[1]:.3f} — the image would be stretched")

    cropped = image.crop(CROP)
    values = np.asarray(cropped).astype(np.float32) / 255.0
    darkened = Image.fromarray((np.power(values, GAMMA) * 255).astype(np.uint8))
    darkened.resize(OUTPUT, Image.LANCZOS).save(TARGET)

    print(f"wrote {TARGET.relative_to(ROOT)}")
    print(f"  crop {CROP}  gamma {GAMMA}  -> {OUTPUT[0]}x{OUTPUT[1]}")
    print(f"  sea was {tuple(np.asarray(image)[5, 5][:3])}, "
          f"now {darkened.getpixel((5, 5))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
