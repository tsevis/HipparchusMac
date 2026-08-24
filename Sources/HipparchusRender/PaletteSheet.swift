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
        // The sub-sea contours. A palette that states a sea-contour colour draws
        // them bright — the ocean's own linework on a black sea — and a little
        // heavier for it; any other palette keeps the derived, dim line.
        styles["bathymetry"] = style(
            stroke: (seaContour != nil ? 0.6 : 0.5) * contourWeight,
            strokeColor: seaContour ?? Self.mix(water, ground, 0.4), opacity: 0.9
        )
        // Depth as mass, on a ramp of its own. Index 0 is the deepest band, so
        // this runs dark water up to the shallows — the opposite direction from
        // the land, which is what makes the two meet at the coast instead of
        // colliding there.
        // **Deep is darker, and which mix *is* darker depends on the palette.**
        //
        // On a dark sheet the ink is pale and the paper is near-black, so naming
        // the ends "toward ink" and "toward ground" inverts the ramp and draws
        // the deep water bright — every colour still defensible, the sea floor
        // read inside out. Five of the seventeen shipped that way from the day
        // the depth bands landed: Tsevis Nocturne, Slate, Pytheas, Vespucci and
        // High Contrast Dark. It survived being looked at because the twelve
        // light palettes agree with the naming, and those are the ones anybody
        // renders.
        //
        // So the two mixes are computed and sorted by luminance rather than
        // assigned by name. Found by a test written for the Python port, run
        // against this one on the suspicion the formula had been copied — it
        // had.
        // An explicit ramp wins: a hypsometric palette states its own sea, deep
        // to shallow, rather than accepting the muted mix a chart palette earns.
        // Left unstated, the derivation below is exactly what it always was.
        let deep: RGBAColor
        let shallow: RGBAColor
        if let depthDeep, let depthShallow {
            deep = depthDeep
            shallow = depthShallow
        } else {
            let towardInk = Self.mix(water, ink, 0.5)
            let towardGround = Self.mix(water, ground, 0.55)
            deep = Self.luma(towardInk) <= Self.luma(towardGround) ? towardInk : towardGround
            shallow = deep == towardInk ? towardGround : towardInk
        }
        styles["depth_bands"] = style(
            stroke: 0, fill: deep, fillHigh: shallow, opacity: 0.9
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
        // A hypsometric palette colours the land plain-to-summit as a two-stop
        // ramp; every other palette keeps the single faint fill it always had.
        if let elevationLow, let elevationHigh {
            styles["elevation_bands"] = style(
                fill: elevationLow, fillHigh: elevationHigh, opacity: 0.9
            )
        } else {
            styles["elevation_bands"] = style(
                fill: Self.mix(ground, contour, 0.18), opacity: 0.6
            )
        }
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

        // An ocean scalar — sea surface temperature today, whatever ERDDAP is
        // pointed at next. Warm reads as the palette's land and cool as its
        // water, which is not a physical claim but is the association every
        // reader already has, and it keeps the sheet inside its eight colours
        // rather than importing a rainbow.
        styles["sst_bands"] = style(
            stroke: 0, fill: Self.mix(water, ink, 0.35),
            fillHigh: Self.mix(land, ink, 0.15), opacity: 0.42
        )
        styles["sst_contours"] = style(
            stroke: 0.4 * contourWeight,
            strokeColor: Self.mix(water, ink, 0.5), opacity: 0.65
        )
        // A streamline is the one line on the sheet whose width means
        // something, so the stroke here is the *base* a `stroke_scale`
        // multiplies: thin where the water is slack, heavy where it runs.
        styles["current_streamlines"] = style(
            stroke: 0.75, strokeColor: Self.mix(water, ink, 0.7), opacity: 0.85, cap: .round
        )

        // Sea marks. A chart's own hierarchy, in the palette's own colours: the
        // rules are ground, the marks are ink, and the emphasis runs from a
        // restricted area you should notice to a light you must not miss.
        //
        // No dashes, because `LayerStyle` has none — a translucent fill and a
        // stated edge carry the same "this is an area, not an object" without
        // one. No magenta either, which is what a real chart would use: this
        // sheet has eight colours and borrowing a ninth would break the one rule
        // the palette engine exists to keep.
        styles["seamark_areas"] = style(
            stroke: 0.7, strokeColor: Self.mix(water, ink, 0.55),
            fill: Self.mix(water, ink, 0.3), fillAlpha: 28, opacity: 0.75
        )
        styles["seamark_harbours"] = style(
            stroke: 0.8, strokeColor: Self.mix(land, ink, 0.45),
            fill: Self.mix(ground, land, 0.35), fillAlpha: 70, opacity: 0.85
        )
        // These were three and four points wide while a mark was a dot, because
        // a point *is* its stroke to this renderer and anything less was a speck
        // you had to be told was there. They are shapes now — a can, a pair of
        // cardinal cones, a wreck's masts — and the shape carries the size, so
        // the stroke goes back to being linework. Left heavy, a 4.2-point line
        // closed the light flare into a solid blob and thickened every mast
        // until the wrecks read as smudges. Measured by looking at the sheet,
        // twice, in both directions.
        //
        // Fixed to the ground, and drawn like it.
        styles["seamark_beacons"] = style(
            stroke: 1.0, strokeColor: Self.mix(land, ink, 0.6), halo: ground
        )
        // Afloat, and lighter on the page for it.
        styles["seamark_buoys"] = style(
            stroke: 0.9, strokeColor: Self.mix(water, ink, 0.65), halo: ground
        )
        // Danger reads as weight. A wreck is the one mark on the sheet that
        // exists to say "not here", so it takes the ink undiluted.
        styles["seamark_hazards"] = style(
            stroke: 1.05, strokeColor: ink, opacity: 0.95, halo: ground
        )
        // What a reader looks for first. The flare is filled, so its weight
        // comes from its area rather than from its edge.
        styles["seamark_lights"] = style(
            stroke: 0.9, strokeColor: ink,
            fill: Self.mix(ground, ink, 0.15), fillAlpha: 210, halo: ground
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
    /// Rec. 601 luma, the cheap standard answer to "is this light or dark".
    /// The same one `derivedHillshade` uses to decide which way relief shades.
    static func luma(_ colour: RGBAColor) -> Double {
        (299 * Double(colour.r) + 587 * Double(colour.g) + 114 * Double(colour.b)) / 1000
    }

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
        /// The far end of a two-stop ramp, for layers whose features carry a
        /// position in a sequence. The presets state this for `elevation_bands`;
        /// a palette has to state it for `depth_bands`, which no preset knows.
        fillHigh: RGBAColor? = nil,
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
        if let fillHigh {
            out.fillColorHigh = RGBAColor(fillHigh.r, fillHigh.g, fillHigh.b, fillAlpha)
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
