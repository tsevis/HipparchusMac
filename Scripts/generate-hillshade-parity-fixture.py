#!/usr/bin/env python3
"""Regenerate the hillshade parity fixture.

Unlike every other fixture here, this one does **not** come from the Python this
port follows: that repo names `terrain_hillshade` in three places and computes it
in none. There is nothing to port, so there is nothing to be in parity with.

What it pins instead is the published algorithm. `Hillshade.swift` is written as
the dot product it really is -- fit a plane to each 3x3 window, take its normal,
light it -- because that form can be read. The reference below is the same
quantity written the way ESRI and GDAL state it, as slope, aspect, zenith and a
cosine. Different algebra, same mathematics. Agreement to 1e-12 across tilted,
curved, noisy and holed ground says the derivation is right *and* that neither
side has a sign or an index slipped, which is the failure mode that would
otherwise ship looking merely a bit odd.

Horn's window, in reading order from the north-west:

    a b c
    d e f      dz/dx = ((c + 2f + i) - (a + 2d + g)) / (8 * cell)
    g h i      dz/dy = ((g + 2h + i) - (a + 2b + c)) / (8 * cell)

Run from the repo root:

    python3 Scripts/generate-hillshade-parity-fixture.py
"""

from __future__ import annotations

import json
import math
import pathlib

import numpy as np

OUTPUT = pathlib.Path("Tests/HipparchusGeometryTests/Fixtures/hillshade-parity.json")

# (azimuth, altitude, cell size in metres, exaggeration).
#
# The north-west 45 degree default first, then a low grazing sun, a near-overhead
# one, a light from the "wrong" side that inverts the relief for most readers, a
# coarse cell, and a vertical exaggeration.
CASES = (
    (315.0, 45.0, 30.0, 1.0),
    (315.0, 12.0, 30.0, 1.0),
    (315.0, 78.0, 30.0, 1.0),
    (135.0, 45.0, 30.0, 1.0),
    (45.0, 30.0, 90.0, 1.0),
    (315.0, 45.0, 30.0, 3.5),
    (0.0, 45.0, 30.0, 1.0),
    (270.0, 60.0, 12.5, 0.5),
)


def fields() -> dict[str, np.ndarray]:
    """The subjects. `HillshadeParityTests` builds these same grids in Swift;
    if you change one, change the other."""
    rows, columns = 11, 13

    row_index, column_index = np.meshgrid(
        np.arange(rows, dtype=float), np.arange(columns, dtype=float), indexing="ij"
    )

    # A plane tilted towards the east-south-east: every cell has the same
    # gradient, so a sign error anywhere shows as a uniformly wrong tone.
    plane = 12.0 * column_index + 5.0 * row_index

    # A cone, which sweeps the aspect through all four quadrants.
    centre_row, centre_column = (rows - 1) / 2.0, (columns - 1) / 2.0
    radius = np.hypot(row_index - centre_row, column_index - centre_column)
    cone = 900.0 - 70.0 * radius

    # A saddle: curvature of both signs, and the flat pass in the middle.
    saddle = 40.0 * ((column_index - centre_column) ** 2 - (row_index - centre_row) ** 2)

    # A ridge with step noise on it, of the kind a real DEM carries from its
    # source resolution.
    ridge = 600.0 * np.exp(-(((column_index - centre_column) / 3.0) ** 2))
    ridge = ridge + 25.0 * np.sin(row_index * 1.7) * np.cos(column_index * 2.3)

    # Flat ground. Shade must come out as sin(altitude) everywhere, whatever the
    # azimuth, the cell size or the exaggeration.
    flat = np.full((rows, columns), 250.0)

    # The same ridge with a bite taken out of it. A hole stays a hole, and its
    # rim reads the centre rather than a cliff.
    holed = ridge.copy()
    holed[3:6, 4:8] = np.nan
    holed[0, 0] = np.nan

    return {
        "plane": plane,
        "cone": cone,
        "saddle": saddle,
        "ridge": ridge,
        "flat": flat,
        "holed": holed,
    }


def horn_window(field: np.ndarray, row: int, column: int) -> list[float]:
    """The nine samples around a cell, edges clamped and holes filled from the
    centre -- matching `Hillshade.swift`, which flattens the rim of a missing
    tile rather than inventing a cliff at the edge of the data."""
    rows, columns = field.shape
    centre = field[row, column]
    window = []
    for row_offset in (-1, 0, 1):
        for column_offset in (-1, 0, 1):
            r = min(max(row + row_offset, 0), rows - 1)
            c = min(max(column + column_offset, 0), columns - 1)
            value = field[r, c]
            window.append(centre if math.isnan(value) else value)
    return window


def shade(field: np.ndarray, azimuth: float, altitude: float, cell: float,
          exaggeration: float) -> np.ndarray:
    """Hillshade the ESRI way: slope, aspect, zenith, cosine."""
    rows, columns = field.shape
    out = np.full((rows, columns), np.nan)

    zenith = math.radians(90.0 - altitude)
    # ESRI states the sun as a compass bearing and the arithmetic wants a
    # mathematical angle, counterclockwise from east.
    azimuth_math = math.radians(360.0 - azimuth + 90.0)

    for row in range(rows):
        for column in range(columns):
            if math.isnan(field[row, column]):
                continue
            a, b, c, d, _e, f, g, h, i = horn_window(field, row, column)

            dz_dx = ((c + 2.0 * f + i) - (a + 2.0 * d + g)) / (8.0 * cell)
            dz_dy = ((g + 2.0 * h + i) - (a + 2.0 * b + c)) / (8.0 * cell)

            slope = math.atan(exaggeration * math.hypot(dz_dx, dz_dy))
            # Exaggeration scales both gradients equally, so it cancels here.
            aspect = math.atan2(dz_dy, -dz_dx)

            lit = (math.cos(zenith) * math.cos(slope)
                   + math.sin(zenith) * math.sin(slope) * math.cos(azimuth_math - aspect))
            out[row, column] = min(max(lit, 0.0), 1.0)
    return out


def main() -> int:
    fixture = {}
    for name, field in fields().items():
        rows, columns = field.shape
        entry = {
            "rows": rows,
            "columns": columns,
            "cases": [],
        }
        for azimuth, altitude, cell, exaggeration in CASES:
            values = shade(field, azimuth, altitude, cell, exaggeration)
            entry["cases"].append({
                "azimuth": azimuth,
                "altitude": altitude,
                "cell_metres": cell,
                "exaggeration": exaggeration,
                "shade": [None if math.isnan(v) else round(float(v), 15)
                          for v in values.ravel()],
            })
        fixture[name] = entry

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture))

    cells = sum(len(c["shade"]) for e in fixture.values() for c in e["cases"])
    print(f"wrote {OUTPUT}: {len(fixture)} fields x {len(CASES)} suns, {cells} cells")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
