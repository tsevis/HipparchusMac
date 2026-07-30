#!/usr/bin/env python3
"""Regenerate the illumination parity fixture from the Python this port follows.

Illumination decides how thick every contour is drawn, so a difference here is a
difference in what the page looks like -- and unlike a geometry bug it would not
show up as a wrong shape, only as wrong emphasis. Worth pinning exactly.

The subject is a lopsided closed ring with a shoulder, so the weight changes
several times around it and the run boundaries are non-trivial.

Run from the repo root:

    python3 Scripts/generate-illumination-parity-fixture.py
"""

from __future__ import annotations

import json
import math
import pathlib
import sys

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
OUTPUT = pathlib.Path("Tests/HipparchusGeometryTests/Fixtures/illumination-parity.json")

sys.path.insert(0, str(PYTHON_REPO / "src"))

from shapely.geometry import LineString  # noqa: E402

from hipparchus.geometry.illumination import (  # noqa: E402
    IlluminationProfile,
    illuminate_geometries,
)

# (azimuth, bands, lit, shadow) -- the four combinations the shipped presets use.
PROFILES = (
    (315.0, 5, 0.4, 1.9),
    (315.0, 6, 0.25, 2.1),
    (315.0, 5, 0.35, 1.9),
    (45.0, 3, 0.5, 1.6),
)


def subject() -> LineString:
    """A lopsided ring with a shoulder: weight changes several times around it.

    ``IlluminationParityTests`` builds the same ring in Swift; if you change this,
    change that.
    """
    points = []
    for step in range(73):
        angle = 2.0 * math.pi * step / 72.0
        wobble = 1.0 + 0.16 * math.sin(angle * 2.0 + 0.6) + 0.07 * math.sin(angle * 3.0)
        radius = 10.0 * wobble
        points.append((radius * math.cos(angle) * 1.18, radius * math.sin(angle) * 0.86))
    return LineString(points)


def main() -> int:
    if not PYTHON_REPO.exists():
        print(f"error: {PYTHON_REPO} not found", file=sys.stderr)
        return 1

    line = subject()
    fixture = {}
    for azimuth, bands, lit, shadow in PROFILES:
        profile = IlluminationProfile(
            azimuth_deg=azimuth, bands=bands, lit_scale=lit, shadow_scale=shadow
        )
        chunks, weights = illuminate_geometries([line], profile)
        fixture[f"{azimuth}/{bands}/{lit}/{shadow}"] = [
            {
                "weight": weight,
                "vertices": len(chunk.coords),
                "coordinates": [[round(x, 12), round(y, 12)] for x, y in chunk.coords],
            }
            for chunk, weight in zip(chunks, weights)
        ]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture))

    runs = sum(len(v) for v in fixture.values())
    print(f"wrote {OUTPUT}: {len(PROFILES)} profiles, {runs} runs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
