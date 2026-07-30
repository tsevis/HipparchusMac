#!/usr/bin/env python3
"""Regenerate the simulated-field parity fixture from the Python this port follows.

The ported unit tests say the Swift field is plausible terrain. This fixture says
it is the *same* terrain -- same hash, same octave ladder, same metres at the same
coordinates -- which is what catches a port that produces a perfectly good
landscape that is not the one a seed names.

Every layer of the generator is captured separately, so a diff points at the step
that moved rather than at the end of a long chain:

  - ``hash``: the integer lattice hash, which everything else rests on. A single
    wrong shift here changes the whole world and nothing else would say why.
  - ``noise``: value noise with quintic interpolation.
  - ``fbm``: the fractal sum, including the normaliser over the *whole* ladder.
  - ``wavelength`` / ``octaves`` / ``relief``: the window-to-landform ladder,
    including the half-way rungs where Python's banker's rounding matters.
  - ``grid``: full elevation samples for real windows, in metres.

Run from the repo root:

    python3 Scripts/generate-simulated-field-parity-fixture.py

Needs numpy and the Python repo on disk. A diff in the output after running this
means one of the two generators changed; find out which before accepting it.
"""

from __future__ import annotations

import json
import pathlib
import sys

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
OUTPUT = pathlib.Path("Tests/HipparchusGeometryTests/Fixtures/simulated-field-parity.json")

sys.path.insert(0, str(PYTHON_REPO / "src"))

import numpy as np  # noqa: E402

from hipparchus.data_sources import simulated_field as sf  # noqa: E402

# Real windows, spanning two orders of magnitude, plus one that sits on a
# half-way rung of the wavelength ladder.
WINDOWS: dict[str, tuple[float, float, float, float]] = {
    "santorini": (25.32, 36.33, 25.50, 36.48),
    "athens": (23.575, 37.816, 23.895, 38.136),
    "myrtoan": (23.2, 36.3, 24.2, 37.1),
    "tiny": (25.40, 36.39, 25.41, 36.40),
}

# Lattice points chosen to cross zero and go negative: a negative coordinate
# becomes a very large uint64, and getting that conversion wrong is silent.
HASH_POINTS = [(0, 0), (1, 0), (0, 1), (-1, -1), (17, -42), (-99999, 123456)]
SEEDS = [1729, 0, 7, 2_147_483_647]

NOISE_POINTS = [(0.0, 0.0), (0.5, 0.5), (1.25, -3.75), (-12.3, 45.6), (1e3, -1e3)]


def main() -> int:
    if not PYTHON_REPO.exists():
        print(f"error: {PYTHON_REPO} not found", file=sys.stderr)
        return 1

    settings = sf.TerrainFieldSettings()

    fixture: dict[str, object] = {
        "settings": {
            "seed": settings.seed,
            "grid_size": settings.grid_size,
            "relief_metres": settings.relief_metres,
            "base_wavelength_deg": settings.base_wavelength_deg,
            "landform_span_ratio": settings.landform_span_ratio,
            "relief_exponent": settings.relief_exponent,
            "max_octaves": settings.max_octaves,
            "warp_octaves": settings.warp_octaves,
            "min_cells_per_feature": settings.min_cells_per_feature,
            "lacunarity": settings.lacunarity,
            "gain": settings.gain,
            "warp_strength": settings.warp_strength,
            "ridge_weight": settings.ridge_weight,
            "shaping_exponent": settings.shaping_exponent,
        },
        "hash": [
            {
                "ix": ix,
                "iy": iy,
                "seed": seed,
                "value": float(
                    sf._hash_unit(np.array([ix], dtype=np.int64), np.array([iy], dtype=np.int64), seed)[0]
                ),
            }
            for seed in SEEDS
            for (ix, iy) in HASH_POINTS
        ],
        "noise": [
            {
                "x": x,
                "y": y,
                "seed": seed,
                "value": float(
                    sf._value_noise(np.array([x], dtype=float), np.array([y], dtype=float), seed)[0]
                ),
            }
            for seed in (1729, 42)
            for (x, y) in NOISE_POINTS
        ],
        "fbm": [
            {
                "x": x,
                "y": y,
                "octaves": octaves,
                "salt": salt,
                "value": float(
                    sf._fbm(
                        np.array([x], dtype=float),
                        np.array([y], dtype=float),
                        settings,
                        octaves=octaves,
                        salt=salt,
                    )[0]
                ),
            }
            for (x, y) in NOISE_POINTS
            for octaves in (1, 4, 12)
            for salt in (0, 101, 211)
        ],
        "windows": {},
    }

    windows: dict[str, object] = {}
    for name, bounds in WINDOWS.items():
        grid = sf.elevation_grid(bounds, settings=settings)
        # The whole grid is 320 x 320; a stride keeps the fixture readable while
        # still sampling every part of it.
        stride = max(1, grid.shape[0] // 16)
        sampled = grid[::stride, ::stride]

        windows[name] = {
            "bounds": list(bounds),
            "span_deg": sf.window_span_deg(bounds),
            "wavelength_deg": sf.field_wavelength_deg(bounds, settings=settings),
            "relief_metres": sf.relief_metres_for_window(bounds, settings=settings),
            "octaves": sf.resolvable_octaves(bounds, settings=settings),
            "min_metres": float(np.nanmin(grid)),
            "max_metres": float(np.nanmax(grid)),
            "stride": stride,
            "samples": [[float(value) for value in row] for row in sampled],
        }
    fixture["windows"] = windows

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, indent=1, sort_keys=True))

    print(
        f"wrote {OUTPUT}: {len(fixture['hash'])} hashes, {len(fixture['noise'])} noise samples, "
        f"{len(fixture['fbm'])} fBm samples, {len(windows)} windows"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
