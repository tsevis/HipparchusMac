import Foundation
import HipparchusGeometry

/// Filled elevation bands from a scalar field.
///
/// Ported from `src/hipparchus/geometry/bands.py`.
///
/// Contours give a landscape its shape; filled bands give it mass. The two are
/// not the same problem: a band is a *region*, and regions nest — a basin inside
/// a plateau is a hole in that plateau's band, not another band drawn on top of
/// it. Getting that wrong produces fills that look right until the first enclosed
/// hollow quietly fills itself in.
///
/// The approach avoids hand-rolling ring nesting entirely:
///
/// 1. Pad the field with a sentinel below its own minimum, so **every** contour at
///    a level closes into a ring — no open chains trailing off the edge to stitch
///    along the frame by hand.
/// 2. Let `GEOSPolygonize` cut those rings into the minimal set of faces.
/// 3. Keep the faces whose interior actually sits at or above the level, by
///    sampling the field at each face's `GEOSPointOnSurface`.
/// 4. Union the survivors. Holes, islands in holes and nesting to any depth all
///    fall out of that test, because containment was never assumed — it was
///    measured against the data.
///
/// A band is then one region minus the region above it, which GEOS resolves
/// including holes.
///
/// This lives in `HipparchusGEOS` rather than `HipparchusGeometry` because it is
/// defined in terms of `polygonize`, `unaryUnion`, `difference` and
/// `pointOnSurface`: it is not portable arithmetic, it is the geometry that needs
/// an engine.
///
/// Everything here works in fractional grid-index space, `(row, column)` as the
/// contour tracer produces it, mapped to the geometry's `(x = column, y = row)`.
/// Callers convert to geographic coordinates afterwards.

/// One filled band, and the values that bound it.
public struct ElevationBand: Sendable, Equatable {
    public let lower: Double
    public let upper: Double
    public let geometry: Geometry

    public init(lower: Double, upper: Double, geometry: Geometry) {
        self.lower = lower
        self.upper = upper
        self.geometry = geometry
    }

    public var midpoint: Double { (lower + upper) / 2.0 }
}

/// The area of `field` at or above `level`, as polygons in index space.
public func regionAtOrAbove(_ field: Field2D, level: Double, using geos: GEOSContext) throws -> Geometry {
    guard field.rows >= 2, field.columns >= 2 else { return .empty }
    guard let range = field.finiteRange else { return .empty }

    let extent = Geometry.polygon(Polygon.box(Bounds(
        minX: 0, minY: 0,
        maxX: Double(field.columns - 1), maxY: Double(field.rows - 1)
    )))
    if range.minimum >= level { return extent }
    if range.maximum < level { return .empty }

    let (padded, sentinel) = padBelow(field, level: level, range: range)

    // The x/y swap from tracer space to geometry space happens exactly here.
    let rings = contourPolylines(padded, level: level)
        .filter { $0.count >= 4 }
        .map { polyline in LineString(polyline.map { Coordinate(x: $0.column, y: $0.row) }) }
    guard !rings.isEmpty else { return .empty }

    let faces = try geos.polygonize(rings)
    guard !faces.isEmpty else { return .empty }

    // Containment measured, never assumed. This is the whole idea.
    var inside: [Geometry] = []
    for face in faces {
        let geometry = Geometry.polygon(face)
        guard let probe = try geos.pointOnSurface(geometry) else { continue }
        if samplesAtOrAbove(padded, at: probe, level: level, sentinel: sentinel) {
            inside.append(geometry)
        }
    }
    guard !inside.isEmpty else { return .empty }

    var region = try geos.unaryUnion(inside)
    if !(try geos.isValid(region)) {
        region = try geos.repaired(region)
    }
    // Back to unpadded index space, then trimmed to the grid itself: the sentinel
    // border pushes each ring a sliver outside the real data.
    region = region.mapCoordinates { Coordinate(x: $0.x - 1.0, y: $0.y - 1.0) }
    return try geos.intersection(region, extent)
}

/// Bands between consecutive `boundaries`, ascending.
///
/// `n` boundaries give `n - 1` bands. Each is the region above its lower bound
/// with the region above its upper bound removed, so bands tile the map without
/// overlapping and without leaving seams between them.
public func elevationBands(
    _ field: Field2D,
    boundaries: [Double],
    using geos: GEOSContext
) throws -> [ElevationBand] {
    let ordered = Array(Set(boundaries.filter(\.isFinite))).sorted()
    guard ordered.count >= 2 else { return [] }

    let regions = try ordered.map { try regionAtOrAbove(field, level: $0, using: geos) }

    var bands: [ElevationBand] = []
    for index in 0..<(ordered.count - 1) {
        let lowerRegion = regions[index]
        let upperRegion = regions[index + 1]
        if lowerRegion.isEmpty { continue }

        var geometry = upperRegion.isEmpty
            ? lowerRegion
            : try geos.difference(lowerRegion, upperRegion)
        if geometry.isEmpty { continue }
        if !(try geos.isValid(geometry)) {
            geometry = try geos.repaired(geometry)
        }
        if geometry.isEmpty { continue }

        bands.append(ElevationBand(lower: ordered[index], upper: ordered[index + 1], geometry: geometry))
    }
    return bands
}

/// Evenly spaced band edges spanning the observed range.
public func bandBoundaries(minimum: Double, maximum: Double, count: Int) -> [Double] {
    guard minimum.isFinite, maximum.isFinite, maximum > minimum, count >= 1 else { return [] }
    let step = (maximum - minimum) / Double(count)
    return (0...count).map { minimum + step * Double($0) }
}

/// Rebuild a geometry with every vertex passed through `mapper`.
///
/// `mapper` takes a point in `(row, column)` index space and returns `(lon, lat)`;
/// the geometry holds those as `(x = column, y = row)`, so the swap happens here
/// rather than at every call site. Getting it wrong transposes the map, which is
/// obvious — getting it wrong *once* in a pipeline of several steps is not.
public func mapIndexSpaceToLonLat(_ geometry: Geometry, _ mapper: (GridPoint) -> Coordinate) -> Geometry {
    geometry.mapCoordinates { point in
        mapper(GridPoint(row: point.y, column: point.x))
    }
}

// MARK: -

/// Ring-fence the field with a value below everything in it.
///
/// Without this, a landform running off the edge of the map produces an open chain
/// that has to be closed along the frame by hand, in the right order and the right
/// direction. With it, every contour closes on its own.
///
/// NaN samples become the sentinel too, so a hole reads as ground below the level
/// rather than as a gap that breaks a ring.
private func padBelow(
    _ field: Field2D,
    level: Double,
    range: (minimum: Double, maximum: Double)
) -> (Field2D, Double) {
    let sentinel = Swift.min(range.minimum, level) - Swift.max(1.0, range.maximum - range.minimum)
    return (field.padded(border: 1, with: sentinel), sentinel)
}

/// Is this face's interior above the level, judged from the data itself?
private func samplesAtOrAbove(
    _ padded: Field2D,
    at probe: Coordinate,
    level: Double,
    sentinel: Double
) -> Bool {
    let column = Int(probe.x.rounded())
    let row = Int(probe.y.rounded())
    let value = padded.clamped(row: row, column: column)
    // A face whose interior samples the sentinel is outside the real data: it is
    // the sliver between the true edge and the padding.
    if value == sentinel { return false }
    return value >= level
}
