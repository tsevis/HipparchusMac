import Foundation

/// Cartographic smoothing primitives.
///
/// Ported from `src/hipparchus/geometry/smoothing.py`.
///
/// Chaikin corner-cutting, and the per-layer policy that decides where it is
/// allowed. Contours come off a sampling grid, so they carry a faint cell-scale
/// staircase that smoothing removes; buildings are drawn as they are surveyed and
/// rounding their corners is vandalism. The policy is the difference.

/// What smoothing is allowed on one layer.
public struct LayerSmoothingRule: Sendable, Equatable {
    public let layerName: String
    public let iterations: Int
    public let smoothPolygons: Bool

    public init(layerName: String, iterations: Int, smoothPolygons: Bool = false) {
        self.layerName = layerName
        self.iterations = iterations
        self.smoothPolygons = smoothPolygons
    }

    public var isEnabled: Bool { iterations > 0 }
}

/// The road hierarchy is eight layers to the renderer and one idea to a reader.
public let lineSmoothingPrefixes = ["roads_"]

public let lineSmoothingLayers: Set<String> = [
    "roads",
    "railways",
    "coastline",
    // Contours come off a sampling grid, so they carry a faint cell-scale
    // staircase that smoothing removes.
    "terrain_contours",
    "terrain_index_contours",
    "night_lights",
    "satellite_tracks",
    "bathymetry",
]

public let polygonSmoothingLayers: Set<String> = [
    "water", "parks", "forests", "fields", "natural", "landuse", "coastline",
]

/// Surveyed edges. Rounding these is not smoothing, it is fabrication.
public let neverSmoothLayers: Set<String> = [
    "buildings", "barriers", "power", "shops", "amenities", "places",
]

public func smoothingRule(for layerName: String, baseIterations: Int) -> LayerSmoothingRule {
    if neverSmoothLayers.contains(layerName) || baseIterations <= 0 {
        return LayerSmoothingRule(layerName: layerName, iterations: 0)
    }
    if lineSmoothingPrefixes.contains(where: layerName.hasPrefix) || lineSmoothingLayers.contains(layerName) {
        return LayerSmoothingRule(layerName: layerName, iterations: baseIterations)
    }
    if polygonSmoothingLayers.contains(layerName) {
        return LayerSmoothingRule(layerName: layerName, iterations: baseIterations, smoothPolygons: true)
    }
    // Anything unrecognised is left alone. A new layer that wants smoothing has to
    // ask for it, rather than getting it because nobody said otherwise.
    return LayerSmoothingRule(layerName: layerName, iterations: 0)
}

/// Deterministic Chaikin smoothing.
///
/// Polygons are only touched when `smoothPolygons` is set, because rounding the
/// corners of a building footprint is not the same operation as easing a contour.
public func smoothed(_ geometry: Geometry, iterations: Int, smoothPolygons: Bool = false) -> Geometry {
    guard iterations > 0, !geometry.isEmpty else { return geometry }

    switch geometry {
    case .point, .multiPoint, .empty:
        return geometry

    case .lineString(let line):
        let coordinates = chaikin(line.coordinates, iterations: iterations, closed: line.isClosed)
        return coordinates.count >= 2 ? .lineString(LineString(coordinates)) : geometry

    case .multiLineString(let lines):
        return .multiLineString(lines.filter { !$0.isEmpty }.map { line in
            let coordinates = chaikin(line.coordinates, iterations: iterations, closed: line.isClosed)
            return coordinates.count >= 2 ? LineString(coordinates) : line
        })

    case .polygon(let polygon):
        guard smoothPolygons else { return geometry }
        return .polygon(smoothedPolygon(polygon, iterations: iterations) ?? polygon)

    case .multiPolygon(let polygons):
        guard smoothPolygons else { return geometry }
        let smoothedPolygons = polygons
            .filter { !$0.isEmpty }
            .compactMap { smoothedPolygon($0, iterations: iterations) }
        return smoothedPolygons.isEmpty ? geometry : .multiPolygon(smoothedPolygons)

    case .collection(let parts):
        return .collection(parts.map { smoothed($0, iterations: iterations, smoothPolygons: smoothPolygons) })
    }
}

private func smoothedPolygon(_ polygon: Polygon, iterations: Int) -> Polygon? {
    let exterior = chaikin(polygon.exterior.coordinates, iterations: iterations, closed: true)
    guard exterior.count >= 4 else { return nil }
    let holes = polygon.holes
        .filter { $0.coordinates.count >= 4 }
        .map { chaikin($0.coordinates, iterations: iterations, closed: true) }
        .filter { $0.count >= 4 }
    return Polygon(exterior: Ring(exterior), holes: holes.map(Ring.init))
}

/// One Chaikin pass replaces every edge `p0 → p1` with two points at a quarter and
/// three quarters along it, so the corner is cut and the curve tightens towards the
/// original. Vertex count doubles per iteration, which is why two passes is a lot
/// and three is usually too many.
func chaikin(_ coordinates: [Coordinate], iterations: Int, closed: Bool) -> [Coordinate] {
    var points = coordinates
    // A closed ring repeats its first point; drop it for the walk and re-append
    // afterwards, or the duplicate gets cut like a real corner.
    if closed, let first = points.first, let last = points.last, first == last {
        points.removeLast()
    }
    guard points.count >= 3 else {
        if closed, let first = points.first {
            return points + [first]
        }
        return points
    }

    for _ in 0..<iterations {
        var next: [Coordinate] = []
        next.reserveCapacity(points.count * 2 + 2)
        // Open lines keep their endpoints pinned: a coastline that drifts away from
        // where it met the frame leaves a visible gap.
        if !closed { next.append(points[0]) }

        for index in 0..<points.count {
            let isLast = index == points.count - 1
            if isLast && !closed { break }
            let p0 = points[index]
            let p1 = points[isLast ? 0 : index + 1]
            next.append(Coordinate(x: 0.75 * p0.x + 0.25 * p1.x, y: 0.75 * p0.y + 0.25 * p1.y))
            next.append(Coordinate(x: 0.25 * p0.x + 0.75 * p1.x, y: 0.25 * p0.y + 0.75 * p1.y))
        }

        if !closed { next.append(points[points.count - 1]) }
        points = next
    }

    if closed, let first = points.first {
        points.append(first)
    }
    return points
}
