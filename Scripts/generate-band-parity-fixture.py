#!/usr/bin/env python3
"""Regenerate the elevation-band parity fixture from the Python this port follows.

Bands are the highest-risk part of the port. The algorithm is the same, but the
engine underneath is GEOS reached directly rather than through Shapely, and a
difference in how faces are polygonized or unioned would show up as a fill that
is subtly the wrong shape -- the exact failure the measure-containment approach
exists to avoid.

Area, polygon count and hole count are recorded rather than vertices. Those three
together pin the topology, which is what matters; vertex-level equality would
break on a GEOS point release for no real reason.

Run from the repo root:

    python3 Scripts/generate-band-parity-fixture.py
"""

from __future__ import annotations

import json
import pathlib
import sys

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
OUTPUT = pathlib.Path("Tests/HipparchusGEOSTests/Fixtures/band-parity.json")
LEVELS: tuple[float, ...] = (10.0, 30.0, 50.0, 60.0, 80.0)
BAND_COUNT = 8

sys.path.insert(0, str(PYTHON_REPO / "src"))

import numpy as np  # noqa: E402

from hipparchus.geometry.bands import (  # noqa: E402
    band_boundaries,
    elevation_bands,
    region_at_or_above,
)


def cone(size: int = 61, peak: float = 100.0) -> np.ndarray:
    """A single peak at the centre falling away radially.

    ``BandsTests.coneField`` builds the same field in Swift; if you change this,
    change that.
    """
    axis = np.linspace(-1.0, 1.0, size)
    xs, ys = np.meshgrid(axis, axis)
    return np.clip(peak * (1.0 - np.hypot(xs, ys)), 0.0, None)


def crater(size: int = 81, rim: float = 100.0) -> np.ndarray:
    """A ring-shaped rim with a hollow inside: the case that breaks naive fills."""
    axis = np.linspace(-1.0, 1.0, size)
    xs, ys = np.meshgrid(axis, axis)
    radius = np.hypot(xs, ys)
    return rim * np.clip(1.0 - np.abs(radius - 0.55) / 0.45, 0.0, None)


def parts(geometry):  # noqa: ANN001, ANN201
    """Polygons in a geometry, whether it is one, a multi, or empty."""
    if geometry.is_empty:
        return []
    return list(getattr(geometry, "geoms", [geometry]))


def main() -> int:
    if not PYTHON_REPO.exists():
        print(f"error: {PYTHON_REPO} not found", file=sys.stderr)
        return 1

    fields = {"cone": cone(), "crater": crater()}
    fixture: dict[str, dict] = {"regions": {}, "bands": {}}

    for name, grid in fields.items():
        fixture["regions"][name] = {}
        for level in LEVELS:
            region = region_at_or_above(grid, level)
            polygons = parts(region)
            fixture["regions"][name][str(level)] = {
                "area": region.area,
                "polygons": len(polygons),
                "holes": sum(len(polygon.interiors) for polygon in polygons),
            }

        fixture["bands"][name] = [
            {
                "lower": band.lower,
                "upper": band.upper,
                "area": band.geometry.area,
                "holes": sum(len(polygon.interiors) for polygon in parts(band.geometry)),
            }
            for band in elevation_bands(grid, band_boundaries(0.0, 100.0, BAND_COUNT))
        ]

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, indent=1))

    regions = sum(len(levels) for levels in fixture["regions"].values())
    bands = sum(len(entries) for entries in fixture["bands"].values())
    print(f"wrote {OUTPUT}: {regions} regions, {bands} bands")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
