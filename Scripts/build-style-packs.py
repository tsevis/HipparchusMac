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


def luma(colour: tuple[int, int, int]) -> float:
    """Rec. 601, the cheap standard answer to "is this light or dark"."""
    return (299 * colour[0] + 587 * colour[1] + 114 * colour[2]) / 255_000.0


def hillshade(ground: tuple[int, int, int], ink: tuple[int, int, int]) -> dict:
    """Relief shading in the pack's own ink.

    The application derives a hillshade for any preset that stays silent about
    it, and derives it in neutral black or white — which is right for a sheet
    whose colours it cannot know, and wrong here. A grey wash over a duotone is
    the one thing a duotone is not: on press those sheets carry two inks and
    paper, nothing else, and a third neutral tone reads as a photograph of a
    screen. Every pack states its own shade so it stays inside its palette.

    The mechanics are the derived style's, because they are not a matter of
    taste. Shading is drawn over the ground rather than instead of it, so the
    untouched end of the ramp is transparent — band 0 is the deepest shadow and
    the last band is the brightest, and *which* end is untouched depends on
    whether the sheet is dark or pale. Pale paper takes shadow; dark paper takes
    light, because its shadows are already dark.
    """
    dark_sheet = luma(ground) < 0.5
    # Bands share their edges, so a stroke would draw every seam between tones.
    out = {
        "stroke_width": 0.0,
        "stroke_color": rgba(ink, 0),
        "fill_enabled": True,
        "visible": True,
        "line_cap": "round",
        "casing_width": 0.0,
        # Under the linework, never over it: relief is what a map is drawn on.
        "opacity": 0.55,
    }
    if dark_sheet:
        out["fill_color"] = rgba(ink, 0)
        out["fill_color_high"] = rgba(ink, 105)
    else:
        out["fill_color"] = rgba(ink, 140)
        out["fill_color_high"] = rgba(ink, 0)
    return out


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
    if "fillHigh" in kwargs:
        out["fill_color_high"] = rgba(kwargs["fillHigh"], kwargs.get("fillAlpha", 255))
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
        # Depth as mass, on a ramp of its own -- the twin of the block in
        # `PaletteSheet.swift`. Index 0 is the deepest band, so this runs dark
        # water up to the shallows, the opposite direction from the land, which
        # is what makes the two meet at the coast instead of colliding there.
        # Deep is darker, and which mix *is* darker depends on the palette: on a
        # dark sheet the ink is pale and the paper near-black, so naming the ends
        # inverts the ramp. Sorted rather than named — see the matching comment
        # in PaletteSheet.swift, which this has to agree with exactly or the
        # parity fixture says so.
        "depth_bands": style(stroke=0,
                             fill=min(mix(water, ink, 0.5), mix(water, ground, 0.55), key=luma),
                             fillHigh=max(mix(water, ink, 0.5), mix(water, ground, 0.55), key=luma),
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
        "terrain_hillshade": hillshade(ground, ink),
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

        # An ocean scalar -- sea surface temperature today, whatever ERDDAP is
        # pointed at next. Warm reads as the pack's land and cool as its water,
        # which is not a physical claim but is the association every reader
        # already has, and it keeps the sheet inside its eight colours.
        "sst_bands": style(stroke=0, fill=mix(water, ink, 0.35),
                           fillHigh=mix(land, ink, 0.15), opacity=0.42),
        "sst_contours": style(stroke=0.4 * contourWeight,
                              strokeColor=mix(water, ink, 0.5), opacity=0.65),
        # A streamline is the one line on the sheet whose width means
        # something, so this stroke is the base a `stroke_scale` multiplies.
        "current_streamlines": style(stroke=0.75, strokeColor=mix(water, ink, 0.7),
                                     opacity=0.85, cap="round"),

        # Sea marks. The twin of the block in `PaletteSheet.swift`, mix for mix.
        # A chart's own hierarchy in the pack's own colours: the rules are
        # ground, the marks are ink, and the emphasis runs from a restricted
        # area you should notice to a light you must not miss.
        #
        # No magenta, which is what a real chart would use -- these sheets have
        # eight colours and a ninth would break the rule the whole derivation
        # exists to keep.
        "seamark_areas": style(stroke=0.7, strokeColor=mix(water, ink, 0.55),
                               fill=mix(water, ink, 0.3), fillAlpha=28, opacity=0.75),
        "seamark_harbours": style(stroke=0.8, strokeColor=mix(land, ink, 0.45),
                                  fill=mix(ground, land, 0.35), fillAlpha=70, opacity=0.85),
        # These were three and four points wide while a mark was a dot, because a
        # point is its stroke to the renderer. They are shapes now -- a can, a
        # pair of cardinal cones, a wreck's masts -- and the shape carries the
        # size, so the stroke goes back to being linework. Left heavy, a
        # 4.2-point line closed the light flare into a solid blob.
        #
        # Fixed to the ground, and drawn like it.
        "seamark_beacons": style(stroke=1.0, strokeColor=mix(land, ink, 0.6), halo=ground),
        # Afloat, and lighter on the page for it.
        "seamark_buoys": style(stroke=0.9, strokeColor=mix(water, ink, 0.65), halo=ground),
        # Danger reads as weight: a wreck is the one mark that exists to say
        # "not here", so it takes the ink undiluted.
        "seamark_hazards": style(stroke=1.05, strokeColor=ink, opacity=0.95, halo=ground),
        # What a reader looks for first. The flare is filled, so its weight comes
        # from its area rather than from its edge.
        "seamark_lights": style(stroke=0.9, strokeColor=ink,
                                fill=mix(ground, ink, 0.15), fillAlpha=210, halo=ground),
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


def cartographers() -> dict:
    """Seven palettes named for people who drew the world, or went and looked
    at it, ported from `Palettes.swift`'s own "Named for people who drew the
    world" section rather than invented here — the colours have to be the
    same objects, or a plugin pack and the built-in `--palette` recolouring
    would offer two different Ptolemys.

    Each is eight colours and nothing else, anchored on swatch sets rather
    than invented at the keyboard: `Scripts/ase-to-hex.swift` reads the
    `.ase` files these came from. Where a set had no colour for a role — a
    three-ink palette has no sea — the missing one is *mixed* from the ones
    it does have rather than picked, the same rule `sheet()` runs on.
    """
    return {
        "id": "com.tsevis.cartographers",
        "name": "Cartographers",
        "presets": [
            # Claudius Ptolemy, Alexandria, second century: the Geographia gave
            # the world its first grid of latitude and longitude. Cream
            # vellum, violet contours, a turquoise Mediterranean.
            preset("Ptolemy", (244, 239, 233), sheet(
                ground=(244, 239, 233), ink=(11, 4, 11),
                water=(98, 164, 231), land=(252, 187, 159),
                road=WHITE, roadCasing=(192, 183, 246),
                vegetation=(188, 227, 232), contour=(102, 46, 145),
            )),
            # Pytheas of Massalia sailed north until the sea froze and
            # reported a place where the sun did not set, which nobody
            # believed for centuries. A sheet for the dark.
            preset("Pytheas", (2, 0, 11), sheet(
                ground=(2, 0, 11), ink=(247, 244, 229),
                water=(44, 18, 178), land=(89, 28, 67),
                road=(197, 237, 237), roadCasing=(57, 20, 39),
                vegetation=(89, 184, 127), contour=(88, 124, 191),
            )),
            # Vincenzo Coronelli, Venice: globes four metres across for the
            # king of France, and a cosmographer's taste for colour that a
            # modern atlas would call excessive.
            preset("Coronelli", mix(WHITE, (234, 170, 163), 0.18), sheet(
                ground=mix(WHITE, (234, 170, 163), 0.18), ink=(22, 67, 177),
                water=(28, 94, 178), land=(203, 119, 6),
                road=WHITE, roadCasing=(241, 128, 101),
                vegetation=mix((42, 172, 9), WHITE, 0.45),
                # The swatch set's magenta, taken down towards the deep ink
                # rather than the palette's own blue -- see `Palettes.swift`
                # for why that axis was tried first and rejected.
                contour=mix((191, 35, 161), INK, 0.55),
            )),
            # Paolo dal Pozzo Toscanelli, Florence, who put Asia close enough
            # to the west of Europe that sailing there sounded reasonable.
            # Columbus carried a copy of his letter.
            preset("Toscanelli", mix(WHITE, (220, 143, 90), 0.12), sheet(
                ground=mix(WHITE, (220, 143, 90), 0.12), ink=(41, 25, 28),
                water=(116, 219, 174), land=(176, 90, 58),
                road=WHITE, roadCasing=(220, 143, 90),
                vegetation=mix((116, 219, 174), (41, 25, 28), 0.45),
                contour=mix((176, 90, 58), WHITE, 0.35),
            )),
            # Amerigo Vespucci, Florence, who worked out that the land in the
            # way was not Asia but somewhere else entirely -- and had two
            # continents named after him for saying so.
            preset("Vespucci", (41, 25, 28), sheet(
                ground=(41, 25, 28), ink=(220, 143, 90),
                water=(61, 120, 172), land=(109, 56, 45),
                road=(220, 143, 90), roadCasing=(33, 55, 96),
                vegetation=(68, 150, 81), contour=(116, 219, 174),
            )),
            # John Wesley Powell ran the Colorado through the Grand Canyon in
            # 1869 with one arm and no maps, and came back with the maps.
            # Canyon strata: sienna, ochre, and a green river.
            preset("Powell", (205, 227, 202), sheet(
                ground=(205, 227, 202), ink=(29, 21, 22),
                water=(54, 139, 154), land=(165, 93, 51),
                road=mix(WHITE, (205, 227, 202), 0.35), roadCasing=(133, 67, 41),
                vegetation=(29, 92, 83), contour=(205, 117, 62),
            )),
            # John C. Frémont surveyed the American West five times and was
            # called the Pathfinder for it. Clay, khaki and slate -- three
            # inks, which is all a field survey ever carried.
            preset("Frémont", mix(WHITE, (182, 165, 114), 0.22), sheet(
                ground=mix(WHITE, (182, 165, 114), 0.22), ink=(46, 42, 61),
                # No sea in a three-ink set, so the water is the slate let
                # down toward the paper rather than a fourth colour smuggled
                # in.
                water=mix((46, 42, 61), WHITE, 0.42), land=(144, 91, 75),
                road=WHITE, roadCasing=(182, 165, 114),
                vegetation=mix((182, 165, 114), (46, 42, 61), 0.35),
                contour=mix((144, 91, 75), WHITE, 0.30),
            )),
        ],
    }


def main() -> int:
    print(f"writing packs into {OUT.relative_to(ROOT)}/")
    write("tsevis-palette", tsevis_palette())
    write("nautical", nautical())
    write("duotone-press", duotone())
    write("high-contrast", highContrast())
    write("cartographers", cartographers())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
