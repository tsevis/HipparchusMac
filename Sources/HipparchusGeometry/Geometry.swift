/// A closed ring of coordinates.
///
/// GEOS requires the first and last coordinate to be identical, so the
/// initialiser closes the ring rather than trusting the caller to have done it.
public struct Ring: Sendable, Equatable {
    public let coordinates: [Coordinate]

    public init(_ coordinates: [Coordinate]) {
        guard let first = coordinates.first, let last = coordinates.last else {
            self.coordinates = []
            return
        }
        if first == last {
            self.coordinates = coordinates
        } else {
            self.coordinates = coordinates + [first]
        }
    }

    public var isEmpty: Bool { coordinates.count < 4 }
    public var bounds: Bounds? { Bounds(coordinates) }

    /// Twice the signed area. Positive is counter-clockwise in a y-up frame.
    /// Used only where winding is the thing being asked about; nothing in the
    /// pipeline infers containment from it.
    public var signedDoubleArea: Double {
        guard coordinates.count >= 4 else { return 0 }
        var total = 0.0
        for index in 0..<(coordinates.count - 1) {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            total += a.x * b.y - b.x * a.y
        }
        return total
    }
}

public struct Polygon: Sendable, Equatable {
    public let exterior: Ring
    public let holes: [Ring]

    public init(exterior: Ring, holes: [Ring] = []) {
        self.exterior = exterior
        self.holes = holes.filter { !$0.isEmpty }
    }

    public init(exterior: [Coordinate], holes: [[Coordinate]] = []) {
        self.init(exterior: Ring(exterior), holes: holes.map(Ring.init))
    }

    public var isEmpty: Bool { exterior.isEmpty }

    public var bounds: Bounds? { exterior.bounds }

    /// An axis-aligned rectangle, the equivalent of shapely's `box`.
    public static func box(_ bounds: Bounds) -> Polygon {
        Polygon(exterior: [
            Coordinate(x: bounds.minX, y: bounds.minY),
            Coordinate(x: bounds.maxX, y: bounds.minY),
            Coordinate(x: bounds.maxX, y: bounds.maxY),
            Coordinate(x: bounds.minX, y: bounds.maxY),
        ])
    }
}

public struct LineString: Sendable, Equatable {
    public let coordinates: [Coordinate]

    public init(_ coordinates: [Coordinate]) {
        self.coordinates = coordinates
    }

    public var isEmpty: Bool { coordinates.count < 2 }
    public var bounds: Bounds? { Bounds(coordinates) }

    public var isClosed: Bool {
        guard let first = coordinates.first, let last = coordinates.last, coordinates.count >= 4 else {
            return false
        }
        return first == last
    }

    public var length: Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(coordinates.count - 1) {
            let a = coordinates[index]
            let b = coordinates[index + 1]
            total += ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
        }
        return total
    }
}

/// The geometry every layer of the app passes around.
///
/// A value type on purpose. GEOS geometry is a reference to C-allocated memory
/// with a context handle attached, which is neither `Sendable` nor safe to hold
/// across an actor boundary; converting at the bridge means the renderer, the
/// exporter and every test deal in plain Swift values that can be compared,
/// copied and sent freely.
public enum Geometry: Sendable, Equatable {
    case empty
    case point(Coordinate)
    case multiPoint([Coordinate])
    case lineString(LineString)
    case multiLineString([LineString])
    case polygon(Polygon)
    case multiPolygon([Polygon])
    case collection([Geometry])

    public var isEmpty: Bool {
        switch self {
        case .empty:
            return true
        case .point(let coordinate):
            return !coordinate.isFinite
        case .multiPoint(let coordinates):
            return coordinates.isEmpty
        case .lineString(let line):
            return line.isEmpty
        case .multiLineString(let lines):
            return lines.allSatisfy(\.isEmpty)
        case .polygon(let polygon):
            return polygon.isEmpty
        case .multiPolygon(let polygons):
            return polygons.allSatisfy(\.isEmpty)
        case .collection(let parts):
            return parts.allSatisfy(\.isEmpty)
        }
    }

    public var bounds: Bounds? {
        switch self {
        case .empty:
            return nil
        case .point(let coordinate):
            return Bounds([coordinate])
        case .multiPoint(let coordinates):
            return Bounds(coordinates)
        case .lineString(let line):
            return line.bounds
        case .multiLineString(let lines):
            return lines.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
        case .polygon(let polygon):
            return polygon.bounds
        case .multiPolygon(let polygons):
            return polygons.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
        case .collection(let parts):
            return parts.compactMap(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
        }
    }

    /// The GeoJSON type name, used by the SVG exporter and the diagnostics.
    public var typeName: String {
        switch self {
        case .empty: return "GeometryCollection"
        case .point: return "Point"
        case .multiPoint: return "MultiPoint"
        case .lineString: return "LineString"
        case .multiLineString: return "MultiLineString"
        case .polygon: return "Polygon"
        case .multiPolygon: return "MultiPolygon"
        case .collection: return "GeometryCollection"
        }
    }

    /// Every polygon in the geometry, whether it arrived alone, in a multi, or
    /// inside a collection. Boolean operations return any of the three.
    public var polygons: [Polygon] {
        switch self {
        case .polygon(let polygon):
            return polygon.isEmpty ? [] : [polygon]
        case .multiPolygon(let polygons):
            return polygons.filter { !$0.isEmpty }
        case .collection(let parts):
            return parts.flatMap(\.polygons)
        default:
            return []
        }
    }

    /// Does this enclose area?
    ///
    /// A layer style can say `fillEnabled`, but a style is a statement about a
    /// *layer* and a layer can hold both. Filling an open line closes it with an
    /// invisible chord and paints the wedge behind it — which is what an unclosed
    /// coastline did, drawing a pale triangle across the sea.
    public var hasArea: Bool { !polygons.isEmpty }

    /// Every line in the geometry, flattened the same way.
    public var lineStrings: [LineString] {
        switch self {
        case .lineString(let line):
            return line.isEmpty ? [] : [line]
        case .multiLineString(let lines):
            return lines.filter { !$0.isEmpty }
        case .collection(let parts):
            return parts.flatMap(\.lineStrings)
        default:
            return []
        }
    }

    /// Collapse a list of polygons into the narrowest case that fits, so an
    /// operation that happens to return one polygon does not hand back a
    /// single-element multi.
    public static func polygons(_ polygons: [Polygon]) -> Geometry {
        let kept = polygons.filter { !$0.isEmpty }
        switch kept.count {
        case 0: return .empty
        case 1: return .polygon(kept[0])
        default: return .multiPolygon(kept)
        }
    }

    public static func lines(_ lines: [LineString]) -> Geometry {
        let kept = lines.filter { !$0.isEmpty }
        switch kept.count {
        case 0: return .empty
        case 1: return .lineString(kept[0])
        default: return .multiLineString(kept)
        }
    }

    /// Rebuild the geometry with every vertex passed through `transform`.
    ///
    /// This is the equivalent of `shapely.ops.transform` and of `bands.map_coordinates`:
    /// the grid-index-to-lon/lat mapping goes through here, one vertex at a time,
    /// which is what keeps the Web Mercator inversion honest.
    public func mapCoordinates(_ transform: (Coordinate) -> Coordinate) -> Geometry {
        switch self {
        case .empty:
            return .empty
        case .point(let coordinate):
            return .point(transform(coordinate))
        case .multiPoint(let coordinates):
            return .multiPoint(coordinates.map(transform))
        case .lineString(let line):
            return .lineString(LineString(line.coordinates.map(transform)))
        case .multiLineString(let lines):
            return .multiLineString(lines.map { LineString($0.coordinates.map(transform)) })
        case .polygon(let polygon):
            return .polygon(polygon.mapCoordinates(transform))
        case .multiPolygon(let polygons):
            return .multiPolygon(polygons.map { $0.mapCoordinates(transform) })
        case .collection(let parts):
            return .collection(parts.map { $0.mapCoordinates(transform) })
        }
    }
}

extension Polygon {
    public func mapCoordinates(_ transform: (Coordinate) -> Coordinate) -> Polygon {
        Polygon(
            exterior: Ring(exterior.coordinates.map(transform)),
            holes: holes.map { Ring($0.coordinates.map(transform)) }
        )
    }
}
