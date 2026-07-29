import CGEOS
import HipparchusGeometry

/// The planar-geometry operations the app actually uses.
///
/// This is the complete list the Python's Shapely usage reduces to. Nothing here
/// is reimplemented: GEOS is the same engine Shapely binds to, so the ported
/// pipeline gets bit-comparable answers rather than a second opinion.
extension GEOSContext {

    // MARK: - Predicates

    public func isValid(_ geometry: Geometry) throws -> Bool {
        let managed = try make(geometry)
        return try predicate(GEOSisValid_r(handle, managed.borrowed), "isValid")
    }

    public func isEmpty(_ geometry: Geometry) throws -> Bool {
        let managed = try make(geometry)
        return try predicate(GEOSisEmpty_r(handle, managed.borrowed), "isEmpty")
    }

    public func contains(_ container: Geometry, _ contained: Geometry) throws -> Bool {
        let a = try make(container)
        let b = try make(contained)
        return try predicate(GEOSContains_r(handle, a.borrowed, b.borrowed), "contains")
    }

    public func intersects(_ lhs: Geometry, _ rhs: Geometry) throws -> Bool {
        let a = try make(lhs)
        let b = try make(rhs)
        return try predicate(GEOSIntersects_r(handle, a.borrowed, b.borrowed), "intersects")
    }

    public func distance(_ lhs: Geometry, _ rhs: Geometry) throws -> Double {
        let a = try make(lhs)
        let b = try make(rhs)
        var result = 0.0
        guard GEOSDistance_r(handle, a.borrowed, b.borrowed, &result) != 0 else {
            throw takeError("distance")
        }
        return result
    }

    public func area(_ geometry: Geometry) throws -> Double {
        let managed = try make(geometry)
        var result = 0.0
        guard GEOSArea_r(handle, managed.borrowed, &result) != 0 else {
            throw takeError("area")
        }
        return result
    }

    // MARK: - Constructive

    public func intersection(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        let a = try make(lhs)
        let b = try make(rhs)
        return try consuming(GEOSIntersection_r(handle, a.borrowed, b.borrowed), "intersection")
    }

    public func difference(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        let a = try make(lhs)
        let b = try make(rhs)
        return try consuming(GEOSDifference_r(handle, a.borrowed, b.borrowed), "difference")
    }

    public func union(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        let a = try make(lhs)
        let b = try make(rhs)
        return try consuming(GEOSUnion_r(handle, a.borrowed, b.borrowed), "union")
    }

    public func unaryUnion(_ geometry: Geometry) throws -> Geometry {
        let managed = try make(geometry)
        return try consuming(GEOSUnaryUnion_r(handle, managed.borrowed), "unary union")
    }

    /// Dissolve a list into one geometry in a single pass. Folding `union` over a
    /// list instead is quadratic and gives a different answer at the seams.
    public func unaryUnion(_ geometries: [Geometry]) throws -> Geometry {
        guard !geometries.isEmpty else { return .empty }
        let parts = try geometries.map(make)
        let collection = try makeCollection(parts, type: GEOS_GEOMETRYCOLLECTION)
        return try consuming(GEOSUnaryUnion_r(handle, collection.borrowed), "unary union")
    }

    public func buffer(_ geometry: Geometry, distance: Double, quadrantSegments: Int32 = 8) throws -> Geometry {
        let managed = try make(geometry)
        return try consuming(
            GEOSBufferWithStyle_r(handle, managed.borrowed, distance, quadrantSegments, Int32(GEOSBUF_CAP_ROUND.rawValue), Int32(GEOSBUF_JOIN_ROUND.rawValue), 5.0),
            "buffer"
        )
    }

    /// `buffer(0)`, the repair Shapely leans on throughout the Python. Kept as a
    /// named call because "buffer by nothing" reads like a mistake otherwise.
    public func repaired(_ geometry: Geometry) throws -> Geometry {
        try buffer(geometry, distance: 0)
    }

    public func simplify(_ geometry: Geometry, tolerance: Double, preserveTopology: Bool) throws -> Geometry {
        let managed = try make(geometry)
        let simplified = preserveTopology
            ? GEOSTopologyPreserveSimplify_r(handle, managed.borrowed, tolerance)
            : GEOSSimplify_r(handle, managed.borrowed, tolerance)
        return try consuming(simplified, "simplify")
    }

    /// A point guaranteed to be inside the geometry — GEOS's `PointOnSurface`,
    /// which is Shapely's `representative_point`.
    ///
    /// Load-bearing: elevation bands decide whether to keep a polygonized face by
    /// sampling the elevation field *here*, so containment is measured against
    /// the data rather than inferred from ring nesting.
    public func pointOnSurface(_ geometry: Geometry) throws -> Coordinate? {
        let managed = try make(geometry)
        guard let pointer = GEOSPointOnSurface_r(handle, managed.borrowed) else {
            throw takeError("point on surface")
        }
        let point = ManagedGeometry(taking: pointer, in: self)
        if try predicate(GEOSisEmpty_r(handle, point.borrowed), "isEmpty") {
            return nil
        }
        return try readCoordinates(point.borrowed).first
    }

    public func centroid(_ geometry: Geometry) throws -> Coordinate? {
        let managed = try make(geometry)
        guard let pointer = GEOSGetCentroid_r(handle, managed.borrowed) else {
            throw takeError("centroid")
        }
        let point = ManagedGeometry(taking: pointer, in: self)
        if try predicate(GEOSisEmpty_r(handle, point.borrowed), "isEmpty") {
            return nil
        }
        return try readCoordinates(point.borrowed).first
    }

    public func interpolate(_ line: LineString, distance: Double) throws -> Coordinate? {
        let managed = try makeLineString(line)
        guard let pointer = GEOSInterpolate_r(handle, managed.borrowed, distance) else {
            throw takeError("interpolate")
        }
        let point = ManagedGeometry(taking: pointer, in: self)
        return try readCoordinates(point.borrowed).first
    }

    /// Cut a set of lines into the minimal set of faces they enclose.
    ///
    /// This is the step that makes elevation bands possible without hand-rolling
    /// ring nesting: closed contour rings go in, every face they bound comes out,
    /// and which faces to keep is then a question the data answers.
    public func polygonize(_ lines: [LineString]) throws -> [Polygon] {
        let usable = lines.filter { $0.coordinates.count >= 2 }
        guard !usable.isEmpty else { return [] }
        let managed = try usable.map(makeLineString)
        var pointers: [OpaquePointer?] = managed.map { $0.borrowed }
        let result: OpaquePointer? = pointers.withUnsafeMutableBufferPointer { buffer in
            // GEOSPolygonize borrows its inputs, so `managed` keeps owning them.
            GEOSPolygonize_r(handle, buffer.baseAddress, UInt32(buffer.count))
        }
        guard let result else { throw takeError("polygonize") }
        let collection = ManagedGeometry(taking: result, in: self)
        return try read(collection.borrowed).polygons
    }

    // MARK: -

    /// Wrap a freshly returned GEOS pointer, read it, and free it.
    private func consuming(_ pointer: OpaquePointer?, _ what: String) throws -> Geometry {
        guard let pointer else { throw takeError(what) }
        let managed = ManagedGeometry(taking: pointer, in: self)
        return try read(managed.borrowed)
    }
}
