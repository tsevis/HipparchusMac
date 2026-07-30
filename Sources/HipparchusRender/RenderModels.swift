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

    public init(name: String, style: LayerStyle = LayerStyle(), labels: [PlaceLabel] = []) {
        self.name = name
        self.style = style
        self.geometries = []
        self.weights = []
        self.fillColors = []
        self.labels = labels
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

    public func rotated(to degrees: Double) -> ViewportState {
        ViewportState(zoom: zoom, panX: panX, panY: panY, rotation: degrees)
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
