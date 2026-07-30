import Foundation
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
    public var deriveVoronoi: Bool
    public var deriveDelaunay: Bool
    public var deriveHexGrid: Bool
    public var deriveCirclePacking: Bool
    public var hexRadius: Double
    public var circleMinRadius: Double
    public var circleMaxRadius: Double
    public var maxOnScreenFeaturesPerLayer: Int
    /// Overrides the base iteration count for named layers. `Coastal Survey` smooths
    /// its coastline three times and its water twice.
    public var layerSmoothingIterations: [String: Int]

    public init(
        simplifyTolerancePreview: Double = 1.5,
        simplifyToleranceExport: Double = 0.6,
        smoothingIterations: Int = 1,
        deriveVoronoi: Bool = false,
        deriveDelaunay: Bool = false,
        deriveHexGrid: Bool = false,
        deriveCirclePacking: Bool = false,
        hexRadius: Double = 60.0,
        circleMinRadius: Double = 8.0,
        circleMaxRadius: Double = 30.0,
        maxOnScreenFeaturesPerLayer: Int = 10000,
        layerSmoothingIterations: [String: Int] = [:]
    ) {
        self.simplifyTolerancePreview = simplifyTolerancePreview
        self.simplifyToleranceExport = simplifyToleranceExport
        self.smoothingIterations = smoothingIterations
        self.deriveVoronoi = deriveVoronoi
        self.deriveDelaunay = deriveDelaunay
        self.deriveHexGrid = deriveHexGrid
        self.deriveCirclePacking = deriveCirclePacking
        self.hexRadius = hexRadius
        self.circleMinRadius = circleMinRadius
        self.circleMaxRadius = circleMaxRadius
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
        var fallback = LayerStyle()
        fallback.fillEnabled = false
        fallback.strokeWidth = 0.5
        fallback.strokeColor = RGBAColor(120, 120, 120, 200)
        return fallback
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
