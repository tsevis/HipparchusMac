import Foundation
import HipparchusData

/// A whole map's worth of layers, derived from a palette's eight colours.
///
/// The Swift half of `Scripts/build-style-packs.py`'s `sheet()`, mix for mix.
/// That function has always been a palette engine; it just ran once, in a build
/// script, and froze its answer into JSON. Running it at render time is what
/// turns colour into an axis you can move.
///
/// Everything is *derived* rather than chosen. A palette picked layer by layer
/// drifts — the water ends up a blue that belongs to no other colour on the
/// sheet — and a palette derived by mixing cannot. That is the whole argument
/// for doing it this way, and it is the reason the numbers below are worth
/// keeping identical to the script's.
extension Palette {

    /// The road classes, widest first. Every sheet draws all of them: one that
    /// styles `roads` but not `roads_motorway` loses its motorways silently.
    static let roadWidths: [(layer: String, width: Double)] = [
        ("roads_motorway", 3.2), ("roads_trunk", 2.8), ("roads_primary", 2.3),
        ("roads_secondary", 1.8), ("roads_tertiary", 1.3), ("roads_residential", 0.9),
        ("roads_service", 0.6), ("roads_other", 0.5), ("roads", 1.0),
    ]

    /// The style profile this palette makes on its own.
    public func styleProfile() -> StyleProfile {
        var styles: [String: LayerStyle] = [:]

        for road in Self.roadWidths {
            let width = road.width * roadScale
            styles[road.layer] = style(
                stroke: width, strokeColor: road_,
                casing: width + 1.1, casingColor: roadCasing, halo: ground
            )
        }

        styles["water"] = style(
            stroke: 0.6, strokeColor: Self.mix(water, ink, 0.25),
            fill: fillsSea ? water : nil
        )
        styles["coastline"] = style(stroke: 1.6, strokeColor: Self.mix(water, ink, 0.45))
        styles["bathymetry"] = style(
            stroke: 0.5 * contourWeight,
            strokeColor: Self.mix(water, ground, 0.4), opacity: 0.9
        )
        styles["buildings"] = style(
            stroke: 0.35, strokeColor: Self.mix(land, ink, 0.4),
            fill: land, opacity: 0.95
        )
        styles["parks"] = style(fill: Self.mix(ground, vegetation, 0.30))
        styles["forests"] = style(fill: Self.mix(ground, vegetation, 0.42))
        styles["fields"] = style(fill: Self.mix(ground, vegetation, 0.16))
        styles["natural"] = style(fill: Self.mix(ground, vegetation, 0.22))
        styles["landuse"] = style(fill: Self.mix(ground, land, 0.08))
        styles["railways"] = style(
            stroke: 0.7, strokeColor: Self.mix(land, ink, 0.55), cap: .butt
        )
        styles["ferry_routes"] = style(
            stroke: 0.6, strokeColor: Self.mix(water, ink, 0.2),
            opacity: 0.7, cap: .butt
        )
        styles["barriers"] = style(
            stroke: 0.4, strokeColor: Self.mix(ground, ink, 0.35), opacity: 0.7
        )
        styles["power"] = style(
            stroke: 0.4, strokeColor: Self.mix(ground, ink, 0.30), opacity: 0.6
        )
        styles["elevation_bands"] = style(
            fill: Self.mix(ground, contour, 0.18), opacity: 0.6
        )
        styles[TerrainLayer.hillshade] = hillshadeStyle()
        styles["terrain_contours"] = style(
            stroke: 0.3 * contourWeight, strokeColor: contour, opacity: 0.7
        )
        styles["terrain_index_contours"] = style(
            stroke: 0.7 * contourWeight,
            strokeColor: Self.mix(contour, ink, 0.3), opacity: 0.9
        )
        styles["summits"] = style(stroke: 0.5, strokeColor: ink, opacity: 0.85)
        styles["admin_boundaries"] = style(
            stroke: 0.8, strokeColor: Self.mix(land, ink, 0.15), opacity: 0.55
        )
        styles["night_lights"] = style(
            fill: Self.turquoise, fillAlpha: 90, opacity: 0.5
        )
        styles["places"] = style(strokeColor: ink, halo: ground)
        styles["street_names"] = style(
            strokeColor: Self.mix(ink, ground, 0.25), halo: ground
        )
        styles["amenities"] = style(strokeColor: Self.mix(land, ink, 0.2), halo: ground)
        styles["shops"] = style(strokeColor: Self.mix(land, ink, 0.2), halo: ground)
        styles["earthquakes_shallow"] = style(stroke: 1.0, strokeColor: Self.turquoise)
        styles["earthquakes_intermediate"] = style(
            stroke: 1.0, strokeColor: Self.mix(Self.turquoise, Self.blue, 0.5)
        )
        styles["earthquakes_deep"] = style(stroke: 1.0, strokeColor: Self.blue)
        styles["satellite_tracks"] = style(
            stroke: 0.6, strokeColor: Self.mix(ink, ground, 0.4), opacity: 0.8
        )
        styles["satellite_footprints"] = style(
            stroke: 0.4, strokeColor: Self.mix(ink, ground, 0.5),
            fill: ink, fillAlpha: 30, opacity: 0.5
        )

        return StyleProfile(layerStyles: styles, background: ground)
    }

    /// Relief shading in this palette's own ink, matching what the packs state.
    ///
    /// A pale sheet takes shadow and a dark sheet takes light, because the
    /// untouched end of the ramp has to be transparent — shading is drawn over
    /// the ground, not instead of it.
    private func hillshadeStyle() -> LayerStyle {
        var shade = LayerStyle()
        shade.strokeWidth = 0
        shade.strokeColor = ink.withOpacity(0)
        shade.fillEnabled = true
        shade.opacity = 0.55

        let luma = (299.0 * Double(ground.r) + 587.0 * Double(ground.g)
            + 114.0 * Double(ground.b)) / 255_000.0
        if luma < 0.5 {
            shade.fillColor = RGBAColor(ink.r, ink.g, ink.b, 0)
            shade.fillColorHigh = RGBAColor(ink.r, ink.g, ink.b, 105)
        } else {
            shade.fillColor = RGBAColor(ink.r, ink.g, ink.b, 140)
            shade.fillColorHigh = RGBAColor(ink.r, ink.g, ink.b, 0)
        }
        return shade
    }

    /// `road` shadows the `road` parameter name inside `styleProfile`; this is
    /// the property, spelled so the two cannot be confused.
    private var road_: RGBAColor { road }

    /// `t` of the way from `a` to `b`, rounded the way Python rounds.
    ///
    /// Half-to-even, not half-away-from-zero. The build script mixes with
    /// Python's `round()`, and the two disagree on exactly the halves: a channel
    /// that lands on 40.5 is 40 there and would be 41 here. One unit of red is
    /// invisible and would make this engine and the shipped packs quietly
    /// different, which is the whole thing the parity fixture exists to prevent.
    static func mix(_ a: RGBAColor, _ b: RGBAColor, _ t: Double) -> RGBAColor {
        func channel(_ from: UInt8, _ to: UInt8) -> UInt8 {
            let value = Double(from) + (Double(to) - Double(from)) * t
            return UInt8(Swift.min(Swift.max(value.rounded(.toNearestOrEven), 0), 255))
        }
        return RGBAColor(channel(a.r, b.r), channel(a.g, b.g), channel(a.b, b.b))
    }

    /// One layer, with only what it needs stated — the Swift twin of the
    /// script's `style()`.
    private func style(
        stroke: Double = 0,
        strokeColor: RGBAColor? = nil,
        fill: RGBAColor? = nil,
        fillAlpha: UInt8 = 255,
        opacity: Double = 1.0,
        cap: LayerStyle.LineCap = .round,
        casing: Double = 0,
        casingColor: RGBAColor? = nil,
        halo: RGBAColor? = nil
    ) -> LayerStyle {
        var out = LayerStyle()
        out.strokeWidth = stroke
        // The build script defaults an unstated stroke to its module-level INK
        // rather than to the sheet's own ink, and the shipped packs carry that.
        // Matching it is not endorsing it; it is refusing to have two answers.
        out.strokeColor = strokeColor ?? Self.deepInk
        out.opacity = opacity
        out.lineCap = cap
        out.casingWidth = casing
        out.fillEnabled = fill != nil
        if let fill {
            out.fillColor = RGBAColor(fill.r, fill.g, fill.b, fillAlpha)
        }
        if let casingColor {
            out.casingColor = casingColor
        }
        if let halo {
            out.labelHaloColor = RGBAColor(halo.r, halo.g, halo.b, 225)
            out.labelHaloWidth = 2.0
        }
        return out
    }
}

extension ArtisticPreset {
    /// This preset's geometry, in another palette's colours.
    ///
    /// The preset keeps everything that is not colour — how much to simplify,
    /// how much to smooth, how many features to draw — because that is what a
    /// preset is once colour has been lifted out of it. A palette of nil, or one
    /// that names nothing, returns the preset untouched.
    public func recoloured(with palette: Palette?) -> ArtisticPreset {
        guard let palette else { return self }
        return ArtisticPreset(
            name: name,
            geometryProfile: geometryProfile,
            styleProfile: palette.styleProfile()
        )
    }
}
