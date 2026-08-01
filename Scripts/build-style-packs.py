#!/usr/bin/env python3
"""Generate the style-pack plugins in Plugins/.

    python3 Scripts/build-style-packs.py

Every preset here is built by *deriving* all thirty-seven layer styles from a
handful of named colours rather than by choosing each one. That is the whole
reason this is a script and not thirty-seven hand-written JSON objects: a
palette picked layer by layer drifts — the water ends up a blue that belongs
to no other colour on the sheet — and a palette derived by mixing cannot.

Each pack is a folder with a `plugin.json`, which is what the application
reads. Install one by copying it into

    ~/Library/Containers/com.hipparchus.HipparchusMac/Data/Library/
        Application Support/Hipparchus/Plugins/

or press "Show plugins folder" under Style → Plugins.
"""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Plugins"

TURQUOISE = (26, 175, 165)      # the application's accent
BLUE = (55, 97, 160)            # #3761A0, from the logo
WHITE = (255, 255, 255)
INK = (17, 34, 51)

#: The road classes, widest first. Every pack draws all of them: a map that
#: styles `roads` but not `roads_motorway` loses its motorways silently.
ROADS = {
    "roads_motorway": 3.2, "roads_trunk": 2.8, "roads_primary": 2.3,
    "roads_secondary": 1.8, "roads_tertiary": 1.3, "roads_residential": 0.9,
    "roads_service": 0.6, "roads_other": 0.5, "roads": 1.0,
}


def rgba(colour: tuple[int, int, int], alpha: int = 255) -> dict[str, int]:
    return {"r": colour[0], "g": colour[1], "b": colour[2], "a": alpha}


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    """`t` of the way from `a` to `b`."""
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def style(**kwargs) -> dict:
    """One layer, with only what it needs stated."""
    out = {
        "stroke_width": kwargs.get("stroke", 0.0),
        "stroke_color": rgba(kwargs["strokeColor"]) if "strokeColor" in kwargs else rgba(INK),
        "opacity": kwargs.get("opacity", 1.0),
        "line_cap": kwargs.get("cap", "round"),
        "visible": kwargs.get("visible", True),
        "casing_width": kwargs.get("casing", 0.0),
        "fill_enabled": "fill" in kwargs,
    }
    if "fill" in kwargs:
        out["fill_color"] = rgba(kwargs["fill"], kwargs.get("fillAlpha", 255))
    if "casingColor" in kwargs:
        out["casing_color"] = rgba(kwargs["casingColor"])
    if "halo" in kwargs:
        out["label_halo_color"] = rgba(kwargs["halo"], 225)
        out["label_halo_width"] = 2.0
    return out


def sheet(
    *, ground, ink, water, land, road, roadCasing, vegetation,
    contour, roadScale=1.0, seaFill=True, contourWeight=1.0,
) -> dict[str, dict]:
    """A whole map's worth of layers, derived from eight colours."""
    styles = {
        layer: style(stroke=width * roadScale, strokeColor=road,
                     casing=(width * roadScale) + 1.1, casingColor=roadCasing, halo=ground)
        for layer, width in ROADS.items()
    }
    styles.update({
        "water": style(stroke=0.6, strokeColor=mix(water, ink, 0.25),
                       **({"fill": water} if seaFill else {})),
        "coastline": style(stroke=1.6, strokeColor=mix(water, ink, 0.45)),
        "bathymetry": style(stroke=0.5 * contourWeight, strokeColor=mix(water, ground, 0.4),
                            opacity=0.9),
        "buildings": style(stroke=0.35, strokeColor=mix(land, ink, 0.4), fill=land, opacity=0.95),
        "parks": style(fill=mix(ground, vegetation, 0.30)),
        "forests": style(fill=mix(ground, vegetation, 0.42)),
        "fields": style(fill=mix(ground, vegetation, 0.16)),
        "natural": style(fill=mix(ground, vegetation, 0.22)),
        "landuse": style(fill=mix(ground, land, 0.08)),
        "railways": style(stroke=0.7, strokeColor=mix(land, ink, 0.55), cap="butt"),
        "ferry_routes": style(stroke=0.6, strokeColor=mix(water, ink, 0.2), opacity=0.7, cap="butt"),
        "barriers": style(stroke=0.4, strokeColor=mix(ground, ink, 0.35), opacity=0.7),
        "power": style(stroke=0.4, strokeColor=mix(ground, ink, 0.30), opacity=0.6),
        "elevation_bands": style(fill=mix(ground, contour, 0.18), opacity=0.6),
        "terrain_contours": style(stroke=0.3 * contourWeight, strokeColor=contour, opacity=0.7),
        "terrain_index_contours": style(stroke=0.7 * contourWeight,
                                        strokeColor=mix(contour, ink, 0.3), opacity=0.9),
        "summits": style(stroke=0.5, strokeColor=ink, opacity=0.85),
        "admin_boundaries": style(stroke=0.8, strokeColor=mix(land, ink, 0.15), opacity=0.55),
        "night_lights": style(fill=TURQUOISE, fillAlpha=90, opacity=0.5),
        "places": style(strokeColor=ink, halo=ground),
        "street_names": style(strokeColor=mix(ink, ground, 0.25), halo=ground),
        "amenities": style(strokeColor=mix(land, ink, 0.2), halo=ground),
        "shops": style(strokeColor=mix(land, ink, 0.2), halo=ground),
        "earthquakes_shallow": style(stroke=1.0, strokeColor=TURQUOISE),
        "earthquakes_intermediate": style(stroke=1.0, strokeColor=mix(TURQUOISE, BLUE, 0.5)),
        "earthquakes_deep": style(stroke=1.0, strokeColor=BLUE),
        "satellite_tracks": style(stroke=0.6, strokeColor=mix(ink, ground, 0.4), opacity=0.8),
        "satellite_footprints": style(stroke=0.4, strokeColor=mix(ink, ground, 0.5),
                                      fill=ink, fillAlpha=30, opacity=0.5),
    })
    return styles


def preset(name: str, ground, styles, *, smoothing=1) -> dict:
    return {
        "name": name,
        "geometry_profile": {
            "smoothing_iterations": smoothing,
            "simplify_tolerance_preview": 1.2,
            "simplify_tolerance_export": 0.5,
        },
        "style_profile": {"background": rgba(ground), "layer_styles": styles},
    }


def write(folder: str, manifest: dict) -> None:
    path = OUT / folder
    path.mkdir(parents=True, exist_ok=True)
    (path / "plugin.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    presets = len(manifest.get("presets", []))
    places = len(manifest.get("places", []))
    print(f"  {folder:<22} {presets} preset(s){f', {places} place(s)' if places else ''}")


# --------------------------------------------------------------------------
# The packs
# --------------------------------------------------------------------------

def tsevis_palette() -> dict:
    """The two brand colours, and a pack of places to go with them.

    Daylight's first version read turquoise rather than blue: the vegetation
    was tinted toward turquoise, so a green city came out turquoise-dominant
    with blue buildings — the opposite of turquoise water against blue land.
    Vegetation is now a desaturated blue-green, and the ground a near-neutral
    paper, so the two brand colours are the only saturated things on the sheet.
    """
    daylight = sheet(
        ground=mix(WHITE, BLUE, 0.04), ink=mix(BLUE, INK, 0.55),
        water=TURQUOISE, land=BLUE, road=WHITE, roadCasing=mix(BLUE, WHITE, 0.62),
        vegetation=mix(TURQUOISE, mix(WHITE, INK, 0.25), 0.55),
        contour=mix(BLUE, WHITE, 0.55),
    )
    nocturne = sheet(
        ground=mix(INK, BLUE, 0.30), ink=mix(WHITE, TURQUOISE, 0.30),
        water=mix(TURQUOISE, INK, 0.50), land=mix(BLUE, INK, 0.40),
        road=mix(TURQUOISE, WHITE, 0.50), roadCasing=mix(INK, BLUE, 0.20),
        vegetation=mix(TURQUOISE, INK, 0.62), contour=mix(BLUE, TURQUOISE, 0.4),
    )
    return {
        "id": "com.tsevis.palette",
        "name": "Tsevis Palette",
        "presets": [
            preset("Tsevis Daylight", mix(WHITE, BLUE, 0.04), daylight),
            preset("Tsevis Nocturne", mix(INK, BLUE, 0.30), nocturne),
        ],
        # The other half of what a plugin can carry: areas, not only styles.
        "places": [
            {"name": "Lefkada", "west": 20.53, "south": 38.56, "east": 20.80, "north": 38.86},
            {"name": "Kefalonia", "west": 20.35, "south": 38.05, "east": 20.80, "north": 38.50},
            {"name": "Ithaca", "west": 20.60, "south": 38.32, "east": 20.80, "north": 38.52},
            {"name": "Corfu", "west": 19.62, "south": 39.35, "east": 20.12, "north": 39.82},
            {"name": "Zakynthos", "west": 20.60, "south": 37.68, "east": 20.98, "north": 37.95},
        ],
    }


def nautical() -> dict:
    """Depth first. Paper the colour of a chart, land reduced to a flat tint.

    The inversion of every other preset: on a chart the sea carries the
    information and the land is what is left over, so the bathymetry is heavy,
    the contours on land are faint, and the buildings barely register.
    """
    paper = (247, 241, 224)
    chart_ink = (26, 58, 82)
    shallow = (176, 214, 224)
    styles = sheet(
        ground=paper, ink=chart_ink, water=shallow, land=mix(paper, (198, 186, 150), 0.55),
        road=mix(paper, chart_ink, 0.35), roadCasing=paper,
        vegetation=mix(paper, (170, 180, 140), 0.35),
        contour=mix(paper, chart_ink, 0.30),
        roadScale=0.55, contourWeight=1.6,
    )
    # The sea is the subject: heavier soundings, a firmer coast, quieter land.
    styles["bathymetry"] = style(stroke=0.75, strokeColor=mix(shallow, chart_ink, 0.55), opacity=1.0)
    styles["coastline"] = style(stroke=2.2, strokeColor=chart_ink)
    styles["buildings"] = style(stroke=0.2, strokeColor=mix(paper, chart_ink, 0.35),
                                fill=mix(paper, chart_ink, 0.10), opacity=0.8)
    styles["summits"] = style(stroke=0.6, strokeColor=chart_ink, opacity=0.9)
    return {
        "id": "com.tsevis.nautical",
        "name": "Nautical",
        "presets": [preset("Admiralty Chart", paper, styles, smoothing=2)],
    }


def duotone() -> dict:
    """Two inks and paper, the way a risograph prints.

    Nothing is a shade of anything: every colour on the sheet is one of the two
    inks, or one of them let down toward the paper. That is what makes a
    duotone read as printed rather than as a photograph of a screen.
    """
    def pack(name: str, first, second, paper):
        styles = sheet(
            ground=paper, ink=mix(first, INK, 0.25), water=second, land=first,
            road=paper, roadCasing=mix(first, paper, 0.35),
            vegetation=mix(second, paper, 0.45), contour=mix(second, paper, 0.35),
        )
        # Overprint: where the inks would meet, the darker one wins outright
        # rather than blending, as it does on press.
        styles["buildings"] = style(stroke=0.3, strokeColor=mix(first, INK, 0.35), fill=first)
        styles["water"] = style(stroke=0.5, strokeColor=mix(second, INK, 0.2), fill=second)
        return preset(name, paper, styles)

    return {
        "id": "com.tsevis.duotone",
        "name": "Duotone Press",
        "presets": [
            pack("Riso Teal & Coral", (0, 160, 152), (255, 102, 94), (250, 246, 238)),
            pack("Riso Blue & Ochre", BLUE, (219, 158, 47), (248, 244, 235)),
        ],
    }


def highContrast() -> dict:
    """Built for legibility, not for taste.

    The sixteen presets are all compositions; none is built for low vision.
    Everything here is black on white or white on black, roads are far wider
    than they would be on any other sheet, and the fills that make a map
    pretty — vegetation, land use, elevation bands — are gone, because they
    are what reduce contrast between the things that matter.
    """
    def pack(name: str, ground, ink):
        styles = sheet(
            ground=ground, ink=ink, water=mix(ground, ink, 0.28), land=ground,
            road=ink, roadCasing=ground, vegetation=ground,
            contour=mix(ground, ink, 0.35), roadScale=1.8,
        )
        for layer in ("parks", "forests", "fields", "natural", "landuse", "elevation_bands"):
            styles[layer] = style(visible=False)
        styles["buildings"] = style(stroke=0.8, strokeColor=ink, fill=mix(ground, ink, 0.14))
        styles["coastline"] = style(stroke=3.0, strokeColor=ink)
        styles["water"] = style(stroke=1.2, strokeColor=ink, fill=mix(ground, ink, 0.22))
        styles["places"] = style(strokeColor=ink, halo=ground)
        styles["street_names"] = style(strokeColor=ink, halo=ground)
        return preset(name, ground, styles, smoothing=2)

    return {
        "id": "com.tsevis.high-contrast",
        "name": "High Contrast",
        "presets": [
            pack("High Contrast Light", (255, 255, 255), (0, 0, 0)),
            pack("High Contrast Dark", (0, 0, 0), (255, 255, 255)),
        ],
    }


def main() -> int:
    print(f"writing packs into {OUT.relative_to(ROOT)}/")
    write("tsevis-palette", tsevis_palette())
    write("nautical", nautical())
    write("duotone-press", duotone())
    write("high-contrast", highContrast())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
