#!/usr/bin/env python3
"""Fetch a real terrarium tile and record what it should decode to.

A round-trip through our own encoder proves the two halves agree with each other,
which they would even if both were wrong. This produces the independent answer:
the tile is decoded with **skia** (what the Python uses) and with **PIL**, the two
are required to agree exactly, and the result is what Core Graphics is held to in
`RealTileDecodeTests`.

The tile is zoom 11, x 1159, y 790 -- Athens, the tile the Python's own
`test_tile_indices_match_the_published_scheme` names.

Run from the repo root (needs network, skia-python and Pillow):

    python3 Scripts/generate-tile-fixture.py
"""

from __future__ import annotations

import io
import json
import pathlib
import sys
import urllib.request

ZOOM, TILE_X, TILE_Y = 11, 1159, 790
URL = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{ZOOM}/{TILE_X}/{TILE_Y}.png"
USER_AGENT = "HipparchusMac/0.1 (native map generator)"

FIXTURES = pathlib.Path("Tests/HipparchusDataTests/Fixtures")
TILE = FIXTURES / f"athens-{ZOOM}-{TILE_X}-{TILE_Y}.png"
EXPECTED = FIXTURES / "athens-tile-expected.json"

# Corners, centre, and two arbitrary interior points -- enough to catch a flip, a
# transpose or an off-by-one row as well as a value shift.
SAMPLE_POINTS = ((0, 0), (0, 255), (255, 0), (255, 255), (128, 128), (37, 91), (200, 17))

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
sys.path.insert(0, str(PYTHON_REPO / "src"))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

from hipparchus.data_sources.terrain_tiles import _decode_terrarium  # noqa: E402


def decode_with_pil(raw: bytes) -> np.ndarray:
    """The same arithmetic, through an unrelated decoder."""
    pixels = np.asarray(Image.open(io.BytesIO(raw)).convert("RGB"), dtype=float)
    return pixels[:, :, 0] * 256.0 + pixels[:, :, 1] + pixels[:, :, 2] / 256.0 - 32768.0


def main() -> int:
    FIXTURES.mkdir(parents=True, exist_ok=True)

    if TILE.exists():
        raw = TILE.read_bytes()
        print(f"reusing {TILE}")
    else:
        print(f"fetching {URL}")
        request = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
            raw = response.read()
        TILE.write_bytes(raw)

    from_skia = _decode_terrarium(raw)
    from_pil = decode_with_pil(raw)
    if not np.array_equal(from_skia, from_pil):
        print("error: skia and PIL disagree on this tile; do not trust either", file=sys.stderr)
        return 1

    expected = {
        "shape": list(from_pil.shape),
        "min": float(from_pil.min()),
        "max": float(from_pil.max()),
        "samples": {f"{row},{col}": float(from_pil[row, col]) for row, col in SAMPLE_POINTS},
    }
    EXPECTED.write_text(json.dumps(expected, indent=1))

    print(f"wrote {EXPECTED}")
    print(f"  {expected['shape'][0]}x{expected['shape'][1]}, "
          f"{expected['min']:.4f} m to {expected['max']:.4f} m")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
