import Foundation

/// Presets the user made, kept between launches.
///
/// Ported from `application/preset_store.py`.
///
/// The sixteen built-in presets are code: they cannot be edited and do not
/// need saving. A style tuned by hand is the opposite of both, and until now
/// there was nowhere for one to live — changing a colour meant changing it
/// again next launch.
///
/// **The file is the Python's, key for key.** `stroke_width`, not
/// `strokeWidth`; colours as `{r, g, b, a}` objects; `schema_version` at the
/// top. Swift's synthesised `Codable` would have written neither, and the
/// difference matters: the two applications are the same application, and a
/// preset made in one should open in the other. That is also why the decoding
/// below is written by hand and forgivingly — the Python reads a preset saved
/// before backgrounds, hypsometric tints or illumination existed by falling
/// back rather than failing, and a reader that refused those files would be
/// the reason someone's work disappeared.
public struct PresetStore: Sendable {
    public static let schemaVersion = 1

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Beside the session, for the same reason it is: a project is a thing on
    /// disk you can find, copy and put in version control, not a defaults key.
    public static func defaultURL(subdirectory: String = "Hipparchus") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent(subdirectory).appendingPathComponent("presets.json")
    }

    // MARK: - Reading

    /// Every saved preset, by name. A missing file is no presets rather than
    /// an error — nobody has saved one yet is the normal first case.
    public func load() throws -> [ArtisticPreset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(PresetFile.self, from: data)
        return file.presets
            .compactMap(\.preset)
            .sorted { $0.name < $1.name }
    }

    // MARK: - Writing

    /// Replace the file with exactly these presets.
    ///
    /// Sorted by name and written atomically: the same set saved twice
    /// produces the same bytes, which is what makes the file diff readably and
    /// stops a half-written file from being what survives a crash.
    public func save(_ presets: [ArtisticPreset]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = PresetFile(
            schemaVersion: Self.schemaVersion,
            presets: presets.sorted { $0.name < $1.name }.map(StoredPreset.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}

// MARK: - The file's own shape

private struct PresetFile: Codable {
    let schemaVersion: Int
    let presets: [StoredPreset]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case presets
    }
}

/// One preset as it sits on disk — in a `presets.json`, or in a plugin's
/// `plugin.json`, which carries the same shape so that a plugin is simply a
/// pack of saved presets.
///
/// Every field is optional on the way in and defaulted on the way out, which
/// is the whole forward-compatibility story: a file written by an older build
/// simply has fewer keys, and each missing one falls back to what that build
/// would have meant by its absence.
struct StoredPreset: Codable {
    let name: String
    let geometryProfile: StoredGeometry?
    let styleProfile: StoredStyleProfile?

    enum CodingKeys: String, CodingKey {
        case name
        case geometryProfile = "geometry_profile"
        case styleProfile = "style_profile"
    }

    init(_ preset: ArtisticPreset) {
        name = preset.name
        geometryProfile = StoredGeometry(preset.geometryProfile)
        styleProfile = StoredStyleProfile(preset.styleProfile)
    }

    /// `nil` for an entry with no usable name — a preset nothing can select is
    /// not a preset, and dropping it beats refusing the whole file for it.
    var preset: ArtisticPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ArtisticPreset(
            name: trimmed,
            geometryProfile: geometryProfile?.profile ?? GeometryPipelineProfile(),
            styleProfile: styleProfile?.profile ?? StyleProfile(layerStyles: [:], background: Self.lightGround)
        )
    }

    /// What the Python falls back to for a preset saved before backgrounds
    /// existed.
    static let lightGround = RGBAColor(250, 250, 250, 255)
}

struct StoredGeometry: Codable {
    var simplifyTolerancePreview: Double?
    var simplifyToleranceExport: Double?
    var smoothingIterations: Int?
    var deriveVoronoi: Bool?
    var deriveDelaunay: Bool?
    var deriveHexGrid: Bool?
    var deriveCirclePacking: Bool?
    var hexRadius: Double?
    var circleMinRadius: Double?
    var circleMaxRadius: Double?
    var maxOnScreenFeaturesPerLayer: Int?
    var layerSmoothingIterations: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case simplifyTolerancePreview = "simplify_tolerance_preview"
        case simplifyToleranceExport = "simplify_tolerance_export"
        case smoothingIterations = "smoothing_iterations"
        case deriveVoronoi = "derive_voronoi"
        case deriveDelaunay = "derive_delaunay"
        case deriveHexGrid = "derive_hex_grid"
        case deriveCirclePacking = "derive_circle_packing"
        case hexRadius = "hex_radius"
        case circleMinRadius = "circle_min_radius"
        case circleMaxRadius = "circle_max_radius"
        case maxOnScreenFeaturesPerLayer = "max_on_screen_features_per_layer"
        case layerSmoothingIterations = "layer_smoothing_iterations"
    }

    init(_ profile: GeometryPipelineProfile) {
        simplifyTolerancePreview = profile.simplifyTolerancePreview
        simplifyToleranceExport = profile.simplifyToleranceExport
        smoothingIterations = profile.smoothingIterations
        deriveVoronoi = profile.deriveVoronoi
        deriveDelaunay = profile.deriveDelaunay
        deriveHexGrid = profile.deriveHexGrid
        deriveCirclePacking = profile.deriveCirclePacking
        hexRadius = profile.hexRadius
        circleMinRadius = profile.circleMinRadius
        circleMaxRadius = profile.circleMaxRadius
        maxOnScreenFeaturesPerLayer = profile.maxOnScreenFeaturesPerLayer
        layerSmoothingIterations = profile.layerSmoothingIterations
    }

    var profile: GeometryPipelineProfile {
        var result = GeometryPipelineProfile()
        if let simplifyTolerancePreview { result.simplifyTolerancePreview = simplifyTolerancePreview }
        if let simplifyToleranceExport { result.simplifyToleranceExport = simplifyToleranceExport }
        if let smoothingIterations { result.smoothingIterations = smoothingIterations }
        if let deriveVoronoi { result.deriveVoronoi = deriveVoronoi }
        if let deriveDelaunay { result.deriveDelaunay = deriveDelaunay }
        if let deriveHexGrid { result.deriveHexGrid = deriveHexGrid }
        if let deriveCirclePacking { result.deriveCirclePacking = deriveCirclePacking }
        if let hexRadius { result.hexRadius = hexRadius }
        if let circleMinRadius { result.circleMinRadius = circleMinRadius }
        if let circleMaxRadius { result.circleMaxRadius = circleMaxRadius }
        if let maxOnScreenFeaturesPerLayer { result.maxOnScreenFeaturesPerLayer = maxOnScreenFeaturesPerLayer }
        if let layerSmoothingIterations { result.layerSmoothingIterations = layerSmoothingIterations }
        return result
    }
}

struct StoredStyleProfile: Codable {
    var layerStyles: [String: StoredLayerStyle]?
    var background: StoredColor?

    enum CodingKeys: String, CodingKey {
        case layerStyles = "layer_styles"
        case background
    }

    init(_ profile: StyleProfile) {
        layerStyles = profile.layerStyles.mapValues(StoredLayerStyle.init)
        background = StoredColor(profile.background)
    }

    var profile: StyleProfile {
        StyleProfile(
            layerStyles: (layerStyles ?? [:]).mapValues(\.style),
            background: background?.color ?? StoredPreset.lightGround
        )
    }
}

struct StoredLayerStyle: Codable {
    var strokeWidth: Double?
    var strokeColor: StoredColor?
    var fillColor: StoredColor?
    var fillEnabled: Bool?
    var opacity: Double?
    var visible: Bool?
    var casingWidth: Double?
    var casingColor: StoredColor?
    var lineCap: String?
    var labelHaloColor: StoredColor?
    var labelHaloWidth: Double?
    var illumination: Double?
    var illuminationAzimuth: Double?
    var illuminationBands: Int?
    var illuminationLitScale: Double?
    var illuminationShadowScale: Double?
    var fillColorHigh: StoredColor?

    enum CodingKeys: String, CodingKey {
        case strokeWidth = "stroke_width"
        case strokeColor = "stroke_color"
        case fillColor = "fill_color"
        case fillEnabled = "fill_enabled"
        case opacity
        case visible
        case casingWidth = "casing_width"
        case casingColor = "casing_color"
        case lineCap = "line_cap"
        case labelHaloColor = "label_halo_color"
        case labelHaloWidth = "label_halo_width"
        case illumination
        case illuminationAzimuth = "illumination_azimuth"
        case illuminationBands = "illumination_bands"
        case illuminationLitScale = "illumination_lit_scale"
        case illuminationShadowScale = "illumination_shadow_scale"
        case fillColorHigh = "fill_color_high"
    }

    init(_ style: LayerStyle) {
        strokeWidth = style.strokeWidth
        strokeColor = StoredColor(style.strokeColor)
        fillColor = StoredColor(style.fillColor)
        fillEnabled = style.fillEnabled
        opacity = style.opacity
        visible = style.visible
        casingWidth = style.casingWidth
        casingColor = StoredColor(style.casingColor)
        lineCap = style.lineCap.rawValue
        labelHaloColor = StoredColor(style.labelHaloColor)
        labelHaloWidth = style.labelHaloWidth
        illumination = style.illumination
        illuminationAzimuth = style.illuminationAzimuth
        illuminationBands = style.illuminationBands
        illuminationLitScale = style.illuminationLitScale
        illuminationShadowScale = style.illuminationShadowScale
        fillColorHigh = style.fillColorHigh.map(StoredColor.init)
    }

    var style: LayerStyle {
        var result = LayerStyle()
        if let strokeWidth { result.strokeWidth = strokeWidth }
        if let strokeColor { result.strokeColor = strokeColor.color }
        if let fillColor { result.fillColor = fillColor.color }
        if let fillEnabled { result.fillEnabled = fillEnabled }
        if let opacity { result.opacity = opacity }
        if let visible { result.visible = visible }
        if let casingWidth { result.casingWidth = casingWidth }
        if let casingColor { result.casingColor = casingColor.color }
        if let lineCap, let cap = LayerStyle.LineCap(rawValue: lineCap) { result.lineCap = cap }
        if let labelHaloColor { result.labelHaloColor = labelHaloColor.color }
        if let labelHaloWidth { result.labelHaloWidth = labelHaloWidth }
        if let illumination { result.illumination = illumination }
        if let illuminationAzimuth { result.illuminationAzimuth = illuminationAzimuth }
        if let illuminationBands { result.illuminationBands = illuminationBands }
        if let illuminationLitScale { result.illuminationLitScale = illuminationLitScale }
        if let illuminationShadowScale { result.illuminationShadowScale = illuminationShadowScale }
        // Deliberately not defaulted: absent means "no hypsometric tint",
        // which is a real setting rather than a missing one.
        result.fillColorHigh = fillColorHigh?.color
        return result
    }
}

/// `{r, g, b, a}`, as the Python writes a colour.
struct StoredColor: Codable {
    var r: Int
    var g: Int
    var b: Int
    var a: Int

    init(_ color: RGBAColor) {
        r = Int(color.r)
        g = Int(color.g)
        b = Int(color.b)
        a = Int(color.a)
    }

    /// Clamped rather than trusted: a hand-edited file with `300` in it should
    /// give white, not crash on a `UInt8` conversion.
    var color: RGBAColor {
        func byte(_ value: Int) -> UInt8 { UInt8(Swift.min(Swift.max(value, 0), 255)) }
        return RGBAColor(byte(r), byte(g), byte(b), byte(a))
    }
}
