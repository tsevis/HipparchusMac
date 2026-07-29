#!/usr/bin/env python3
"""Regenerate the contour parity fixture from the Python this port follows.

The ported unit tests say the Swift tracer is correct. The parity fixture says it
is the *same* -- same lines, same order, same vertices -- which is what catches a
port that satisfies every assertion while drawing something subtly different.

Run from the repo root:

    python3 Scripts/generate-contour-parity-fixture.py

Needs numpy and the Python repo on disk. A diff in the output after running this
means one of the two tracers changed; find out which before accepting it.
"""

from __future__ import annotations

import json
import pathlib
import sys

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
OUTPUT = pathlib.Path("Tests/HipparchusGeometryTests/Fixtures/contour-parity.json")
LEVELS: tuple[float, ...] = (-0.5, 0.0, 0.25, 0.5, 0.9)
SIZE = 37

sys.path.insert(0, str(PYTHON_REPO / "src"))

import numpy as np  # noqa: E402

from hipparchus.geometry.contours import contour_polylines  # noqa: E402


def reference_field() -> np.ndarray:
    """A deliberately awkward field.

    Two ridges and a saddle so the ambiguous marching-squares cases are hit, one
    NaN hole so masked samples are exercised, and one sample sitting exactly on a
    level so the tangency nudge is exercised. ``ContourParityTests`` builds the
    same field in Swift; if you change this, change that.
    """
    axis = np.linspace(-3.0, 3.0, SIZE)
    xs, ys = np.meshgrid(axis, axis)
    grid = np.sin(xs * 1.7) * np.cos(ys * 1.3) + 0.25 * xs
    grid[5, 7] = np.nan
    grid[10, 10] = 0.5
    return grid


def main() -> int:
    if not PYTHON_REPO.exists():
        print(f"error: {PYTHON_REPO} not found", file=sys.stderr)
        return 1

    grid = reference_field()
    fixture = {
        str(level): [
            [[round(row, 12), round(col, 12)] for row, col in line]
            for line in contour_polylines(grid, level)
        ]
        for level in LEVELS
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture))

    lines = sum(len(level) for level in fixture.values())
    vertices = sum(len(line) for level in fixture.values() for line in level)
    print(f"wrote {OUTPUT}: {len(LEVELS)} levels, {lines} lines, {vertices} vertices")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
