import Foundation
import HipparchusData
import HipparchusGeometry

/// The preset system: what a map should look like.
///
/// Ported from `src/hipparchus/application/presets.py`. The model is here; the
/// sixteen presets and their style tables are in `PresetTables.swift`, which is
/// **generated** from the Python by `Scripts/generate-presets.py` — five hundred
/// lines of colour data transcribed by hand would be five hundred chances to
/// mistype a channel, and nothing downstream would notice.
///
/// A preset controls how things are drawn, not how much data is fetched. That is a
/// known limitation carried over deliberately: the Python needed a whole second map
/// model to raise the contour count for `Relief Sheet`, and the fix — letting a
/// preset carry an advisory source profile — belongs with the source stack rather
/// than here.

/// Which derivations run, and how hard the geometry pipeline works.
public struct GeometryPipelineProfile: Sendable, Equatable {
    public var simplifyTolerancePreview: Double
    public var simplifyToleranceExport: Double
    public var smoothingIterations: Int
    public var maxOnScreenFeaturesPerLayer: Int
    /// Overrides the base iteration count for named layers. `Coastal Survey` smooths
    /// its coastline three times and its water twice.
    public var layerSmoothingIterations: [String: Int]

    public init(
        simplifyTolerancePreview: Double = 1.5,
        simplifyToleranceExport: Double = 0.6,
        smoothingIterations: Int = 1,
        maxOnScreenFeaturesPerLayer: Int = 10000,
        layerSmoothingIterations: [String: Int] = [:]
    ) {
        self.simplifyTolerancePreview = simplifyTolerancePreview
        self.simplifyToleranceExport = simplifyToleranceExport
        self.smoothingIterations = smoothingIterations
        self.maxOnScreenFeaturesPerLayer = maxOnScreenFeaturesPerLayer
        self.layerSmoothingIterations = layerSmoothingIterations
    }

    /// The tolerance for a given quality profile, with its scale applied.
    public func simplifyTolerance(for quality: QualityProfile) -> Double {
        let base = quality.isExport ? simplifyToleranceExport : simplifyTolerancePreview
        return base * quality.simplifyScale
    }

    /// Smoothing iterations for one layer, with the quality scale applied.
    public func smoothingIterations(for layer: String, quality: QualityProfile) -> Int {
        let base = layerSmoothingIterations[layer] ?? smoothingIterations
        return Int((Double(base) * quality.smoothingScale).rounded())
    }
}

/// A named style set. The ground is part of it: a dark preset that forgot its
/// background exports pale strokes onto white paper.
public struct StyleProfile: Sendable {
    public var layerStyles: [String: LayerStyle]
    public var background: RGBAColor

    public init(layerStyles: [String: LayerStyle], background: RGBAColor = RGBAColor(250, 250, 250)) {
        self.layerStyles = layerStyles
        self.background = background
    }

    /// The style for a layer, or a sensible invisible default.
    ///
    /// A layer a preset says nothing about is drawn as a hairline rather than
    /// skipped, so a new source shows up as *something* the first time it appears
    /// instead of silently not rendering.
    public func style(for layer: String) -> LayerStyle {
        if let style = layerStyles[layer] { return style }
        // The layers with a better answer than a hairline. The bands are band
        // fills, and a hairline round every tone of one draws the seams and
        // none of the tones; the sea marks are chart symbols, and a hairline
        // draws a mark that reads as nothing in particular.
        if layer == TerrainLayer.hillshade { return derivedHillshade }
        if layer == TerrainLayer.depthBands { return derivedDepthBands }
        if let seamark = derivedSeamarkStyle(for: layer) { return seamark }

        var fallback = LayerStyle()
        fallback.fillEnabled = false
        fallback.strokeWidth = 0.5
        fallback.strokeColor = RGBAColor(120, 120, 120, 200)
        return fallback
    }

    /// Depth bands for a preset that has never heard of them.
    ///
    /// **Eleven of the built-in presets fill the land's bands and not one
    /// mentions the sea's**, for the same reason none mentions the hillshade:
    /// `PresetTables.swift` is generated from the Python registry, and the
    /// Python has no depth bands to name. So a hypsometric sheet drawn from a
    /// preset alone gave the land graduated mass and left the Elbe as bare
    /// hairline contours on white paper — the exact asymmetry the depth bands
    /// were built to end, surviving in the one path nobody had rendered.
    ///
    /// **It follows the land rather than overruling it.** `Contour Study` fills
    /// nothing, on purpose: it is linework, and forcing a filled sea onto it
    /// would be this fallback deciding what the sheet is. So the fill is enabled
    /// only where `elevation_bands` is filled, and a linework preset keeps its
    /// invisible depth bands — which is correct there and was never the bug.
    ///
    /// The two stops are read off what the preset already chose: its water for
    /// the hue, darkened towards its own contour ink for the deep end and
    /// lightened towards its paper for the shallow. Deep is darker, which is the
    /// one thing about a depth ramp a reader assumes without being told.
    public var derivedDepthBands: LayerStyle {
        var style = LayerStyle()
        // Bands share their edges. Stroking them draws every seam between tones.
        style.strokeWidth = 0.0

        let bands = layerStyles[TerrainLayer.elevationBands]
        style.fillEnabled = bands?.fillEnabled ?? false
        guard style.fillEnabled else { return style }

        // The sea's own colour, however the preset stated it: a filled water
        // layer carries it as a fill, an outlined one as a stroke.
        let water = layerStyles["water"].map { $0.fillEnabled ? $0.fillColor : $0.strokeColor }
            ?? RGBAColor(150, 180, 200)
        // The darkest line the preset draws on the sea, for the deep end. The
        // sub-sea contours if it has them, the coastline if not.
        let ink = layerStyles[TerrainLayer.bathymetry]?.strokeColor
            ?? layerStyles["coastline"]?.strokeColor
            ?? RGBAColor(40, 60, 80)

        // **Deep is darker, and which mix *is* darker depends on the sheet.**
        //
        // On a dark preset the ink is pale and the paper near-black, so naming
        // the ends "toward ink" and "toward ground" inverts the ramp and draws
        // the deep water bright. `PaletteSheet` shipped exactly that bug in five
        // of its seventeen palettes (`c08424b`); this is the same formula, so it
        // was the same bug, and it was still here after that fix because the
        // palette path and the preset path are two copies of one idea.
        //
        // So the mixes are computed and sorted by luminance rather than assigned
        // by name.
        let towardInk = water.mixed(towards: ink, amount: 0.5)
        let towardGround = water.mixed(towards: background, amount: 0.55)
        let inkIsDarker = Palette.luma(towardInk) <= Palette.luma(towardGround)
        style.fillColor = inkIsDarker ? towardInk : towardGround
        style.fillColorHigh = inkIsDarker ? towardGround : towardInk
        style.opacity = bands?.opacity ?? 0.9
        return style
    }

    /// Sea marks for a preset that has never heard of them, or `nil` for any
    /// other layer.
    ///
    /// **The same gap `derivedDepthBands` closed, and the same shape of bug.**
    /// `PresetTables.swift` is generated from the Python registry, and the
    /// Python has no sea marks either, so every one of the sixteen built-in
    /// presets falls through to the generic hairline: a translucent grey
    /// stroke round a chart symbol that needs to read as a can, a cone or a
    /// light's flare, not as an unstyled shape. `PaletteSheet.styleProfile()`
    /// already styles these six layers properly, in a palette's raw water,
    /// ink, ground and land — this reads the same four off what the preset
    /// itself already chose, the way `derivedDepthBands` reads its water and
    /// ink, so a preset with no palette override gets marks in its own voice
    /// rather than none at all.
    ///
    /// **Areas and harbours follow the land rather than overrule it**, the
    /// same rule `derivedDepthBands` follows for the sea's own fill: a
    /// linework preset that leaves `buildings` unfilled — `Contour Study` is
    /// exactly that — gets unfilled seamark areas too, because a solid area
    /// wash is precisely the kind of mass a linework sheet has decided not to
    /// draw. The four point marks — beacons, buoys, hazards, lights — are
    /// strokes and halos regardless of that choice, the same way a coastline
    /// is stroked on every preset whether or not it fills the sea: a chart
    /// symbol has to be there to be read at all, filled preset or not.
    private func derivedSeamarkStyle(for layer: String) -> LayerStyle? {
        guard Seamarks.allLayers.contains(layer) else { return nil }

        // The same water and ink `derivedDepthBands` reads, plus the ground
        // and the preset's own land, however it stated `buildings`.
        let water = layerStyles["water"].map { $0.fillEnabled ? $0.fillColor : $0.strokeColor }
            ?? RGBAColor(150, 180, 200)
        let ink = layerStyles[TerrainLayer.bathymetry]?.strokeColor
            ?? layerStyles["coastline"]?.strokeColor
            ?? RGBAColor(40, 60, 80)
        let land = layerStyles["buildings"].map { $0.fillEnabled ? $0.fillColor : $0.strokeColor }
            ?? RGBAColor(200, 190, 175)
        let ground = background
        let fillsAreas = layerStyles["buildings"]?.fillEnabled ?? true

        switch layer {
        case Seamarks.areas:
            var style = LayerStyle()
            style.strokeWidth = 0.7
            style.strokeColor = water.mixed(towards: ink, amount: 0.55)
            style.fillEnabled = fillsAreas
            if fillsAreas {
                let fill = water.mixed(towards: ink, amount: 0.3)
                style.fillColor = RGBAColor(fill.r, fill.g, fill.b, 28)
            }
            style.opacity = 0.75
            return style

        case Seamarks.harbours:
            var style = LayerStyle()
            style.strokeWidth = 0.8
            style.strokeColor = land.mixed(towards: ink, amount: 0.45)
            style.fillEnabled = fillsAreas
            if fillsAreas {
                let fill = ground.mixed(towards: land, amount: 0.35)
                style.fillColor = RGBAColor(fill.r, fill.g, fill.b, 70)
            }
            style.opacity = 0.85
            return style

        // Fixed to the ground, and drawn like it. Linework, not a fill: a
        // point is its stroke to this renderer, and the shape (not the
        // weight) is what makes a beacon read as a beacon.
        case Seamarks.beacons:
            var style = LayerStyle()
            style.strokeWidth = 1.0
            style.strokeColor = land.mixed(towards: ink, amount: 0.6)
            style.fillEnabled = false
            style.labelHaloColor = RGBAColor(ground.r, ground.g, ground.b, 225)
            style.labelHaloWidth = 2.0
            return style

        // Afloat, and lighter on the page for it.
        case Seamarks.buoys:
            var style = LayerStyle()
            style.strokeWidth = 0.9
            style.strokeColor = water.mixed(towards: ink, amount: 0.65)
            style.fillEnabled = false
            style.labelHaloColor = RGBAColor(ground.r, ground.g, ground.b, 225)
            style.labelHaloWidth = 2.0
            return style

        // Danger reads as weight. A wreck is the one mark that exists to say
        // "not here", so it takes the ink undiluted.
        case Seamarks.hazards:
            var style = LayerStyle()
            style.strokeWidth = 1.05
            style.strokeColor = ink
            style.fillEnabled = false
            style.opacity = 0.95
            style.labelHaloColor = RGBAColor(ground.r, ground.g, ground.b, 225)
            style.labelHaloWidth = 2.0
            return style

        // What a reader looks for first. The flare is filled, so its weight
        // comes from its area rather than from its edge.
        case Seamarks.lights:
            var style = LayerStyle()
            style.strokeWidth = 0.9
            style.strokeColor = ink
            style.fillEnabled = true
            let fill = ground.mixed(towards: ink, amount: 0.15)
            style.fillColor = RGBAColor(fill.r, fill.g, fill.b, 210)
            style.labelHaloColor = RGBAColor(ground.r, ground.g, ground.b, 225)
            style.labelHaloWidth = 2.0
            return style

        default:
            return nil
        }
    }

    /// Relief shading for a preset that has never heard of it.
    ///
    /// Every one of the sixteen built-in presets predates the hillshade —
    /// `PresetTables.swift` is generated from the Python registry, and the Python
    /// names this layer without ever producing one — so none of them says
    /// anything about how it should look. Rather than edit a generated file, or
    /// add dead style data to the other repo, the shade is derived from what the
    /// preset already chose.
    ///
    /// It is derived as a **wash that adds one tone and leaves the other alone**,
    /// which is the part that is easy to get wrong. Relief shading is drawn over
    /// the elevation bands, the water and the land cover — not over the
    /// background — so the untouched end of the ramp has to be *nothing at all*,
    /// carried as zero alpha. Setting it to the background colour instead paints
    /// the paper over whatever the map had already put there, and the sheet goes
    /// flat and grey while every individual colour still looks reasonable.
    ///
    /// Which end is the untouched one depends on what is underneath. Pale ground
    /// takes shadow: dark where it turns away, nothing where it faces the sun.
    /// Dark ground takes light: nothing in the shadows, which are already dark,
    /// and a highlight on the faces that catch the sun. Getting that backwards
    /// does not fail loudly — it produces a sheet where every colour is defensible
    /// and the relief reads inside out.
    ///
    /// "Underneath" is answerable rather than guessable: the hillshade sits
    /// directly above `elevation_bands` in the draw order, so that layer's fill
    /// *is* the ground, and the background only governs when the bands are not
    /// filled. Asking the background instead is wrong on any preset that pairs
    /// dark paper with a pale sheet — `Night` does exactly that, and judging by
    /// its background alone puts a white highlight onto near-white bands and
    /// shades nothing at all.
    ///
    /// A preset or plugin that *does* name `terrain_hillshade` overrides all of
    /// this and is used as written.
    public var derivedHillshade: LayerStyle {
        var style = LayerStyle()
        // Bands share their edges. Stroking them draws every seam between tones,
        // which is the one thing shading must not have.
        style.strokeWidth = 0.0
        style.fillEnabled = true

        // The ground as it actually ends up: a band fill that is not opaque is
        // sitting on the background, so the two are mixed rather than one chosen.
        var ground = background
        if let bands = layerStyles[TerrainLayer.elevationBands], bands.fillEnabled {
            ground = background.mixed(towards: bands.fillColor, amount: Double(bands.fillColor.a) / 255.0)
        }

        // Rec. 601 luma, the cheap standard answer to "is this light or dark",
        // and it agrees with the eye on every preset here.
        let luma = (299.0 * Double(ground.r) + 587.0 * Double(ground.g)
            + 114.0 * Double(ground.b)) / 255_000.0

        if luma >= 0.5 {
            // Band 0 is the deepest shadow, the last band the brightest.
            style.fillColor = RGBAColor(0, 0, 0, 140)
            style.fillColorHigh = RGBAColor(0, 0, 0, 0)
        } else {
            style.fillColor = RGBAColor(255, 255, 255, 0)
            style.fillColorHigh = RGBAColor(255, 255, 255, 105)
        }
        // Under the contours, not over them: relief is what the linework is drawn
        // on, and at full strength it buries the map it is supporting. The
        // deepest band lands at a little under a third of full black, which is
        // enough to lift a ridge off the page and not enough to muddy the
        // hypsometric colour underneath it.
        style.opacity = 0.55
        return style
    }
}

public struct ArtisticPreset: Sendable, Identifiable {
    public let name: String
    public let geometryProfile: GeometryPipelineProfile
    public let styleProfile: StyleProfile

    public var id: String { name }

    public init(name: String, geometryProfile: GeometryPipelineProfile, styleProfile: StyleProfile) {
        self.name = name
        self.geometryProfile = geometryProfile
        self.styleProfile = styleProfile
    }

    /// Which layers this preset illuminates. Used by the diagnostics, and by tests
    /// that want to know a preset's look without rendering it.
    public var illuminatedLayers: [String] {
        styleProfile.layerStyles
            .filter { $0.value.illumination > 0 }
            .keys
            .sorted()
    }
}

public enum Presets {
    public static let defaultName = "Urban Structure"

    /// Night ground, and the sodium/amber road palette lit against it.
    public static let nightGround = RGBAColor(14, 17, 23)

    /// Warm off-white for the contour sheet: a pure white ground makes hairlines
    /// read as dirt on the screen rather than as ink on paper.
    public static let contourPaper = RGBAColor(246, 244, 239)

    public static var names: [String] { registry.map(\.name) }

    public static func preset(_ name: String) -> ArtisticPreset {
        registry.first { $0.name == name } ?? registry.first { $0.name == defaultName } ?? registry[0]
    }

    public static var `default`: ArtisticPreset { preset(defaultName) }

    /// Map a requested name onto one that exists, or fall back.
    ///
    /// Backs the preset name arriving from a command line or a saved setting:
    /// matching is case-insensitive and tolerates padding, and anything unknown
    /// yields the fallback rather than leaving a picker on a name that is not in it.
    public static func resolveName(
        _ requested: String,
        available: [String]? = nil,
        fallback: String = defaultName
    ) -> String {
        let candidate = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return fallback }
        let options = available ?? names
        return options.first { $0.lowercased() == candidate.lowercased() } ?? fallback
    }
}
