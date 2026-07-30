#!/usr/bin/env python3
"""Generate Sources/HipparchusRender/PresetTables.swift from the Python presets.

The sixteen presets are five hundred lines of colour and width data. Transcribing
that by hand would be five hundred chances to mistype a channel, and nothing
downstream would notice a green that is four units off -- it would just look very
slightly wrong forever.

So it is generated. This reads the Python's own preset registry through
introspection and emits Swift that says the same thing, which makes the tables
correct by construction rather than by proofreading.

Only fields that differ from the shared defaults are emitted, so the output stays
readable and a diff shows what a preset actually chose.

Run from the repo root:

    python3 Scripts/generate-presets.py

Re-run it after changing the Python presets. The output is committed, so a clean
clone needs neither Python nor the other repo to build.
"""

from __future__ import annotations

import dataclasses
import pathlib
import sys

PYTHON_REPO = pathlib.Path("/Users/tsevis/AI/ClaudeCode/Hipparchus")
OUTPUT = pathlib.Path("Sources/HipparchusRender/PresetTables.swift")

sys.path.insert(0, str(PYTHON_REPO / "src"))

from hipparchus.application import presets as py_presets  # noqa: E402
from hipparchus.rendering.models import LayerStyle, RGBAColor  # noqa: E402

# Python field name -> Swift label. Anything not listed keeps a camelCase mapping.
FIELD_NAMES = {
    "stroke_width": "strokeWidth",
    "stroke_color": "strokeColor",
    "fill_color": "fillColor",
    "fill_enabled": "fillEnabled",
    "opacity": "opacity",
    "visible": "visible",
    "casing_width": "casingWidth",
    "casing_color": "casingColor",
    "line_cap": "lineCap",
    "label_halo_color": "labelHaloColor",
    "label_halo_width": "labelHaloWidth",
    "illumination": "illumination",
    "illumination_azimuth": "illuminationAzimuth",
    "illumination_bands": "illuminationBands",
    "illumination_lit_scale": "illuminationLitScale",
    "illumination_shadow_scale": "illuminationShadowScale",
    "fill_color_high": "fillColorHigh",
}

GEOMETRY_FIELDS = {
    "simplify_tolerance_preview": "simplifyTolerancePreview",
    "simplify_tolerance_export": "simplifyToleranceExport",
    "smoothing_iterations": "smoothingIterations",
    "derive_voronoi": "deriveVoronoi",
    "derive_delaunay": "deriveDelaunay",
    "derive_hex_grid": "deriveHexGrid",
    "derive_circle_packing": "deriveCirclePacking",
    "hex_radius": "hexRadius",
    "circle_min_radius": "circleMinRadius",
    "circle_max_radius": "circleMaxRadius",
    "max_on_screen_features_per_layer": "maxOnScreenFeaturesPerLayer",
    "layer_smoothing_iterations": "layerSmoothingIterations",
}

NAMED_COLOURS = {
    (14, 17, 23, 255): "Presets.nightGround",
    (246, 244, 239, 255): "Presets.contourPaper",
}


def swift_number(value: float) -> str:
    """Emit a Double that reads like the source did."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if value == int(value):
        return f"{int(value)}.0"
    return repr(round(value, 10))


def swift_colour(colour: RGBAColor, *, allow_named: bool = True) -> str:
    key = (colour.r, colour.g, colour.b, colour.a)
    if allow_named and key in NAMED_COLOURS:
        return NAMED_COLOURS[key]
    if colour.a == 255:
        return f"RGBAColor({colour.r}, {colour.g}, {colour.b})"
    return f"RGBAColor({colour.r}, {colour.g}, {colour.b}, {colour.a})"


def style_arguments(style: LayerStyle) -> list[str]:
    """Only the fields that differ from the shared defaults."""
    default = LayerStyle()
    arguments: list[str] = []
    for field in dataclasses.fields(LayerStyle):
        name = field.name
        value = getattr(style, name)
        if value == getattr(default, name):
            continue
        label = FIELD_NAMES[name]
        if isinstance(value, RGBAColor):
            arguments.append(f"{label}: {swift_colour(value, allow_named=False)}")
        elif name == "line_cap":
            arguments.append(f"{label}: .{value}")
        elif value is None:
            continue
        else:
            arguments.append(f"{label}: {swift_number(value)}")
    return arguments


def geometry_arguments(profile) -> list[str]:  # noqa: ANN001
    default = py_presets.GeometryPipelineProfile()
    arguments: list[str] = []
    for field in dataclasses.fields(profile):
        name = field.name
        value = getattr(profile, name)
        if value == getattr(default, name):
            continue
        label = GEOMETRY_FIELDS[name]
        if name == "layer_smoothing_iterations":
            pairs = ", ".join(f'"{key}": {count}' for key, count in sorted(value.items()))
            arguments.append(f"{label}: [{pairs}]")
        else:
            arguments.append(f"{label}: {swift_number(value)}")
    return arguments


def render() -> str:
    registry = py_presets._preset_registry()  # noqa: SLF001

    lines = [
        "// GENERATED FILE — do not edit by hand.",
        "//",
        "// Produced by Scripts/generate-presets.py from the Python preset registry in",
        "// /Users/tsevis/AI/ClaudeCode/Hipparchus. Five hundred lines of colour data",
        "// transcribed by hand would be five hundred chances to mistype a channel, and",
        "// nothing downstream would notice. Re-run the script instead of editing this.",
        "//",
        "// Only fields that differ from LayerStyle's defaults are passed, so a diff here",
        "// shows what a preset actually chose.",
        "",
        "import HipparchusGeometry",
        "",
        "extension Presets {",
        "    /// The sixteen presets, in the order the picker lists them.",
        "    public static let registry: [ArtisticPreset] = [",
    ]

    for name, preset in registry.items():
        geometry = geometry_arguments(preset.geometry_profile)
        lines.append("        ArtisticPreset(")
        lines.append(f'            name: "{name}",')
        if geometry:
            lines.append("            geometryProfile: GeometryPipelineProfile(")
            for index, argument in enumerate(geometry):
                comma = "," if index < len(geometry) - 1 else ""
                lines.append(f"                {argument}{comma}")
            lines.append("            ),")
        else:
            lines.append("            geometryProfile: GeometryPipelineProfile(),")

        background = preset.style_profile.background
        lines.append("            styleProfile: StyleProfile(")
        lines.append("                layerStyles: [")
        for layer, style in sorted(preset.style_profile.layer_styles.items()):
            arguments = ", ".join(style_arguments(style))
            lines.append(f'                    "{layer}": LayerStyle({arguments}),')
        lines.append("                ],")
        lines.append(f"                background: {swift_colour(background)}")
        lines.append("            )")
        lines.append("        ),")

    lines.append("    ]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    if not PYTHON_REPO.exists():
        print(f"error: {PYTHON_REPO} not found", file=sys.stderr)
        return 1

    swift = render()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(swift)

    registry = py_presets._preset_registry()  # noqa: SLF001
    styles = sum(len(p.style_profile.layer_styles) for p in registry.values())
    print(f"wrote {OUTPUT}: {len(registry)} presets, {styles} layer styles, {len(swift.splitlines())} lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
