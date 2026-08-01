import Foundation
import HipparchusData
import HipparchusGeometry

/// Core rendering models for layered vector scenes.
///
/// Ported from `src/hipparchus/rendering/models.py`.

public struct RGBAColor: Sendable, Equatable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func withOpacity(_ opacity: Double) -> RGBAColor {
        let bounded = Swift.min(Swift.max(opacity, 0.0), 1.0)
        return RGBAColor(r, g, b, UInt8((Double(a) * bounded).rounded()))
    }

    /// `#rrggbb`. Alpha is carried separately, as an SVG `opacity` attribute.
    public var hex: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }

    /// Interpolate towards another colour. Elevation bands use this to walk a
    /// two-stop ramp from low ground to high.
    public func mixed(towards other: RGBAColor, amount: Double) -> RGBAColor {
        let t = Swift.min(Swift.max(amount, 0.0), 1.0)
        func lerp(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8((Double(from) + (Double(to) - Double(from)) * t).rounded())
        }
        return RGBAColor(lerp(r, other.r), lerp(g, other.g), lerp(b, other.b), lerp(a, other.a))
    }
}

public struct LayerStyle: Sendable, Equatable {
    public var strokeWidth: Double = 1.0
    public var strokeColor = RGBAColor(20, 20, 20)
    public var fillColor = RGBAColor(220, 220, 220, 200)
    public var fillEnabled = true
    public var opacity: Double = 1.0
    public var visible = true
    /// Road casing: a wider stroke drawn underneath, OSM-style.
    public var casingWidth: Double = 0.0
    public var casingColor = RGBAColor(0, 0, 0)
    public var lineCap: LineCap = .butt
    public var labelHaloColor = RGBAColor(255, 255, 255, 230)
    public var labelHaloWidth: Double = 2.0
    /// Illuminated contours: 0 leaves the layer at one uniform weight; above 0
    /// varies stroke weight along each line by how its slope faces the light.
    /// The machinery is plumbed here; the illumination pass itself is a later slice.
    public var illumination: Double = 0.0
    public var illuminationAzimuth: Double = 315.0
    public var illuminationBands: Int = 5
    public var illuminationLitScale: Double = 0.4
    public var illuminationShadowScale: Double = 1.9
    /// High end of a two-stop fill ramp. Layers whose features carry a position in
    /// a sequence — elevation bands — interpolate from `fillColor` to this;
    /// everything else ignores it.
    public var fillColorHigh: RGBAColor?

    public enum LineCap: String, Sendable {
        case butt
        case round
    }

    public init() {}

    /// Every field, with the defaults the Python uses.
    ///
    /// The preset tables in `PresetTables.swift` are generated against this
    /// signature and pass only the fields that differ, so a default changed here
    /// changes every preset that was relying on it. That is intended — they are
    /// the same defaults in both codebases — but it is worth knowing.
    public init(
        strokeWidth: Double = 1.0,
        strokeColor: RGBAColor = RGBAColor(20, 20, 20),
        fillColor: RGBAColor = RGBAColor(220, 220, 220, 200),
        fillEnabled: Bool = true,
        opacity: Double = 1.0,
        visible: Bool = true,
        casingWidth: Double = 0.0,
        casingColor: RGBAColor = RGBAColor(0, 0, 0),
        lineCap: LineCap = .butt,
        labelHaloColor: RGBAColor = RGBAColor(255, 255, 255, 230),
        labelHaloWidth: Double = 2.0,
        illumination: Double = 0.0,
        illuminationAzimuth: Double = 315.0,
        illuminationBands: Int = 5,
        illuminationLitScale: Double = 0.4,
        illuminationShadowScale: Double = 1.9,
        fillColorHigh: RGBAColor? = nil
    ) {
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.fillEnabled = fillEnabled
        self.opacity = opacity
        self.visible = visible
        self.casingWidth = casingWidth
        self.casingColor = casingColor
        self.lineCap = lineCap
        self.labelHaloColor = labelHaloColor
        self.labelHaloWidth = labelHaloWidth
        self.illumination = illumination
        self.illuminationAzimuth = illuminationAzimuth
        self.illuminationBands = illuminationBands
        self.illuminationLitScale = illuminationLitScale
        self.illuminationShadowScale = illuminationShadowScale
        self.fillColorHigh = fillColorHigh
    }
}

public struct PlaceLabel: Sendable, Equatable {
    public var name: String
    /// World coordinates, in the scene's projection.
    public var position: Coordinate
    public var placeType: String
    /// Degrees, for labels set along a line. Zero is horizontal.
    public var rotation: Double

    public init(name: String, position: Coordinate, placeType: String = "", rotation: Double = 0) {
        self.name = name
        self.position = position
        self.placeType = placeType
        self.rotation = rotation
    }
}

/// A named layer with its style and geometry.
///
/// `weights` and `fillColors` are parallel to `geometries` and may be empty.
///
/// **Kickoff detail 6.** These arrays must be built in lockstep with the geometry
/// and after every other geometry step. Clipping can split one feature into two and
/// smoothing can drop one; either shifts a parallel array out of step, and the map
/// then draws the right shapes in the wrong colours. It bit the Python twice.
/// `append(_:weight:fillColor:)` exists so the three are appended together and
/// cannot be added separately.
public struct RenderLayer: Sendable {
    public let name: String
    public var style: LayerStyle
    public private(set) var geometries: [Geometry]
    public private(set) var weights: [Double]
    public private(set) var fillColors: [RGBAColor]
    public var labels: [PlaceLabel]
    /// How many features arrived from the provider, before the pipeline clipped,
    /// dropped, split or capped any of them.
    ///
    /// Worth keeping separate from `featureCount`: illumination turns one contour
    /// into a dozen runs and clipping can split a band in two, so a layer that says
    /// "798 features" may have been fetched as 178. The layer panel shows what was
    /// fetched; the exporter records both.
    public var rawFeatureCount: Int

    public init(
        name: String,
        style: LayerStyle = LayerStyle(),
        labels: [PlaceLabel] = [],
        rawFeatureCount: Int = 0
    ) {
        self.name = name
        self.style = style
        self.geometries = []
        self.weights = []
        self.fillColors = []
        self.labels = labels
        self.rawFeatureCount = rawFeatureCount
    }

    /// The only way to add geometry. A weight or a fill of `nil` records "use the
    /// layer's own", which keeps the arrays the same length as `geometries` so
    /// they can never slip relative to it.
    public mutating func append(_ geometry: Geometry, weight: Double? = nil, fillColor: RGBAColor? = nil) {
        geometries.append(geometry)
        weights.append(weight ?? 1.0)
        fillColors.append(fillColor ?? style.fillColor)
    }

    public func weight(at index: Int) -> Double {
        index < weights.count ? weights[index] : 1.0
    }

    public func fillColor(at index: Int) -> RGBAColor {
        index < fillColors.count ? fillColors[index] : style.fillColor
    }

    public var isEmpty: Bool { geometries.isEmpty && labels.isEmpty }

    /// What the layer row in the interface counts.
    public var featureCount: Int { geometries.isEmpty ? labels.count : geometries.count }
}

/// Viewport transform parameters, in world coordinate space.
public struct ViewportState: Sendable, Equatable {
    public var zoom: Double
    public var panX: Double
    public var panY: Double
    /// Degrees.
    public var rotation: Double

    public init(zoom: Double = 1.0, panX: Double = 0, panY: Double = 0, rotation: Double = 0) {
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
        self.rotation = rotation
    }

    public func zoomed(by factor: Double) -> ViewportState {
        ViewportState(
            zoom: Swift.min(Swift.max(zoom * factor, 0.05), 64.0),
            panX: panX, panY: panY, rotation: rotation
        )
    }

    public func panned(dx: Double, dy: Double) -> ViewportState {
        ViewportState(zoom: zoom, panX: panX + dx, panY: panY + dy, rotation: rotation)
    }

    /// Turn to a bearing.
    ///
    /// Normalised into the half-turn either side of north, because the number is
    /// read as a bearing: after a dozen steps of 15° the map should say −165°
    /// rather than counting on to 195°, and −180° and 180° are the same way round.
    public func rotated(to degrees: Double) -> ViewportState {
        ViewportState(
            zoom: zoom, panX: panX, panY: panY, rotation: Self.normalisedBearing(degrees)
        )
    }

    /// Turn by a step, which is what the rotate controls do.
    public func rotated(by degrees: Double) -> ViewportState {
        rotated(to: rotation + degrees)
    }

    /// Into `(-180, 180]`.
    static func normalisedBearing(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var bearing = degrees.truncatingRemainder(dividingBy: 360)
        if bearing <= -180 { bearing += 360 }
        if bearing > 180 { bearing -= 360 }
        return bearing
    }
}

/// An ordered layer stack, ready to draw or export.
public struct RenderScene: Sendable {
    public var layers: [RenderLayer]
    /// The geographic area requested.
    public var bbox: BoundingBox?
    /// The projection the geometry was built with. Carried so a click on the canvas
    /// can be turned back into longitude and latitude without guessing which
    /// projection produced the picture.
    public var projection: ProjectionProfile
    /// Ground the layers are drawn on. Carried on the scene so the preview renderer
    /// and the SVG exporter agree without consulting the preset.
    public var background: RGBAColor
    public var metadata: [String: PropertyValue]
    public var diagnostics: [String: PropertyValue]

    public init(
        layers: [RenderLayer] = [],
        bbox: BoundingBox? = nil,
        projection: ProjectionProfile = ProjectionProfile(),
        background: RGBAColor = RGBAColor(250, 250, 250),
        metadata: [String: PropertyValue] = [:],
        diagnostics: [String: PropertyValue] = [:]
    ) {
        self.layers = layers
        self.bbox = bbox
        self.projection = projection
        self.background = background
        self.metadata = metadata
        self.diagnostics = diagnostics
    }

    public var visibleLayers: [RenderLayer] {
        layers.filter { $0.style.visible }
    }

    /// The same scene with the relief lifted over the built environment.
    ///
    /// Relief is ground and buildings sit on it, so shading belongs underneath
    /// them and that is where the draw order puts it. In open country that is
    /// simply right. In a dense city it means the shading is almost entirely
    /// hidden: twenty thousand opaque building fills over a street grid leave it
    /// showing in the parks, the water and the street corridors and nowhere
    /// else — most of the work, invisible.
    ///
    /// Which of those you want is a question about the drawing rather than about
    /// the ground, so it is a switch and not a rule. Lifted, the shading becomes
    /// a wash over the whole sheet, buildings included; it is a transparent ramp,
    /// so the city reads through it and the hills read through the city.
    ///
    /// Labels stay on top either way. Nothing is worth burying a place name for.
    ///
    /// Applied to the built scene, so the switch is live and costs a redraw
    /// rather than a rebuild.
    public func raisingReliefOverTheBuiltEnvironment() -> RenderScene {
        guard let from = layers.firstIndex(where: { $0.name == TerrainLayer.hillshade }) else {
            return self
        }
        var copy = self
        let relief = copy.layers.remove(at: from)
        // Just under the first label layer, which is as high as anything drawn
        // gets before the type starts.
        let firstLabel = copy.layers.firstIndex { SceneBuilder.labelLayers.contains($0.name) }
        copy.layers.insert(relief, at: firstLabel ?? copy.layers.count)
        return copy
    }

    /// The same scene with every stroke multiplied.
    ///
    /// **No Python counterpart.** There, and here until now, line weight is
    /// entirely a property of the preset: sixteen sets of stroke widths, each
    /// chosen for a look, none adjustable. That is right for the look and wrong
    /// for the medium — the weight that reads on a screen is not the weight that
    /// reads on a metre of paper, and a sheet exported at 24 × 36 has hairlines
    /// a third of a millimetre wide.
    ///
    /// One multiplier over every stroke keeps the preset's *relative* weights,
    /// which are the design, and moves only the absolute scale, which is the
    /// medium. Applied to the built scene rather than during the build, so the
    /// control is live: nothing is re-simplified or re-smoothed, the strokes are
    /// simply drawn wider.
    ///
    /// Casings scale with the roads they underlie. Halos deliberately do not —
    /// a label halo is sized against the type, and type is not getting bigger.
    public func scalingLineWeights(by scale: Double) -> RenderScene {
        guard scale != 1.0, scale > 0, scale.isFinite else { return self }
        var copy = self
        for index in copy.layers.indices {
            copy.layers[index].style.strokeWidth *= scale
            copy.layers[index].style.casingWidth *= scale
        }
        return copy
    }

    /// The extent of everything drawable, in world (projected) coordinates.
    public var contentBounds: Bounds? {
        var result: Bounds?
        for layer in visibleLayers {
            for geometry in layer.geometries {
                guard let bounds = geometry.bounds else { continue }
                result = result?.union(bounds) ?? bounds
            }
            for label in layer.labels {
                guard let bounds = Bounds([label.position]) else { continue }
                result = result?.union(bounds) ?? bounds
            }
        }
        return result
    }

    /// One line: how much is on the map. Ported from `layer_inventory.summarise`.
    public var summary: String {
        let populated = layers.filter { $0.featureCount > 0 }
        guard !populated.isEmpty else { return "Nothing to draw" }
        let total = populated.reduce(0) { $0 + $1.featureCount }
        let plural = populated.count == 1 ? "" : "s"
        return "\(populated.count) layer\(plural) · \(spacedThousands(total)) features"
    }
}

/// `100 000` reads faster than `100000`. A plain space, not a thin one — a thin
/// space breaks copy-paste and font fallback.
public func spacedThousands(_ value: Int) -> String {
    let digits = String(value)
    guard digits.count > 4 else { return digits }
    var out = ""
    for (offset, character) in digits.enumerated() {
        if offset > 0 && (digits.count - offset) % 3 == 0 { out.append(" ") }
        out.append(character)
    }
    return out
}
