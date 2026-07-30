import CGEOS
import HipparchusGeometry

/// The planar-geometry operations the app actually uses.
///
/// This is the complete list the Python's Shapely usage reduces to. Nothing here
/// is reimplemented: GEOS is the same engine Shapely binds to, so the ported
/// pipeline gets bit-comparable answers rather than a second opinion.
///
/// Every C call goes through `withGeometry` / `withGeometries`, which keep the
/// inputs alive for the duration. See the note on `ManagedGeometry`: doing it by
/// hand worked in debug and segfaulted in release.
extension GEOSContext {

    // MARK: - Predicates

    public func isValid(_ geometry: Geometry) throws -> Bool {
        try withGeometry(geometry) { try predicate(GEOSisValid_r(handle, $0), "isValid") }
    }

    public func isEmpty(_ geometry: Geometry) throws -> Bool {
        try withGeometry(geometry) { try predicate(GEOSisEmpty_r(handle, $0), "isEmpty") }
    }

    public func contains(_ container: Geometry, _ contained: Geometry) throws -> Bool {
        try withGeometries(container, contained) {
            try predicate(GEOSContains_r(handle, $0, $1), "contains")
        }
    }

    public func intersects(_ lhs: Geometry, _ rhs: Geometry) throws -> Bool {
        try withGeometries(lhs, rhs) {
            try predicate(GEOSIntersects_r(handle, $0, $1), "intersects")
        }
    }

    public func distance(_ lhs: Geometry, _ rhs: Geometry) throws -> Double {
        try withGeometries(lhs, rhs) { first, second in
            var result = 0.0
            guard GEOSDistance_r(handle, first, second, &result) != 0 else {
                throw takeError("distance")
            }
            return result
        }
    }

    public func area(_ geometry: Geometry) throws -> Double {
        try withGeometry(geometry) { pointer in
            var result = 0.0
            guard GEOSArea_r(handle, pointer, &result) != 0 else {
                throw takeError("area")
            }
            return result
        }
    }

    public func length(_ geometry: Geometry) throws -> Double {
        try withGeometry(geometry) { pointer in
            var result = 0.0
            guard GEOSLength_r(handle, pointer, &result) != 0 else {
                throw takeError("length")
            }
            return result
        }
    }

    // MARK: - Constructive

    public func intersection(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        try withGeometries(lhs, rhs) {
            try consuming(GEOSIntersection_r(handle, $0, $1), "intersection")
        }
    }

    public func difference(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        try withGeometries(lhs, rhs) {
            try consuming(GEOSDifference_r(handle, $0, $1), "difference")
        }
    }

    public func union(_ lhs: Geometry, _ rhs: Geometry) throws -> Geometry {
        try withGeometries(lhs, rhs) {
            try consuming(GEOSUnion_r(handle, $0, $1), "union")
        }
    }

    public func unaryUnion(_ geometry: Geometry) throws -> Geometry {
        try withGeometry(geometry) {
            try consuming(GEOSUnaryUnion_r(handle, $0), "unary union")
        }
    }

    /// Dissolve a list into one geometry in a single pass. Folding `union` over a
    /// list instead is quadratic and gives a different answer at the seams.
    public func unaryUnion(_ geometries: [Geometry]) throws -> Geometry {
        guard !geometries.isEmpty else { return .empty }
        let parts = try geometries.map(make)
        let collection = try makeCollection(parts, type: GEOS_GEOMETRYCOLLECTION)
        return try collection.withPointer {
            try consuming(GEOSUnaryUnion_r(handle, $0), "unary union")
        }
    }

    public func buffer(_ geometry: Geometry, distance: Double, quadrantSegments: Int32 = 8) throws -> Geometry {
        try withGeometry(geometry) { pointer in
            try consuming(
                GEOSBufferWithStyle_r(
                    handle, pointer, distance, quadrantSegments,
                    Int32(GEOSBUF_CAP_ROUND.rawValue), Int32(GEOSBUF_JOIN_ROUND.rawValue), 5.0
                ),
                "buffer"
            )
        }
    }

    /// `buffer(0)`, the repair Shapely leans on throughout the Python. Kept as a
    /// named call because "buffer by nothing" reads like a mistake otherwise.
    public func repaired(_ geometry: Geometry) throws -> Geometry {
        try buffer(geometry, distance: 0)
    }

    public func simplify(_ geometry: Geometry, tolerance: Double, preserveTopology: Bool) throws -> Geometry {
        try withGeometry(geometry) { pointer in
            let simplified = preserveTopology
                ? GEOSTopologyPreserveSimplify_r(handle, pointer, tolerance)
                : GEOSSimplify_r(handle, pointer, tolerance)
            return try consuming(simplified, "simplify")
        }
    }

    /// A point guaranteed to be inside the geometry — GEOS's `PointOnSurface`,
    /// which is Shapely's `representative_point`.
    ///
    /// Load-bearing: elevation bands decide whether to keep a polygonized face by
    /// sampling the elevation field *here*, so containment is measured against the
    /// data rather than inferred from ring nesting.
    public func pointOnSurface(_ geometry: Geometry) throws -> Coordinate? {
        try withGeometry(geometry) { pointer in
            guard let result = GEOSPointOnSurface_r(handle, pointer) else {
                throw takeError("point on surface")
            }
            return try ManagedGeometry(taking: result, in: self).withPointer { point in
                if try predicate(GEOSisEmpty_r(handle, point), "isEmpty") { return nil }
                return try readCoordinates(point).first
            }
        }
    }

    public func centroid(_ geometry: Geometry) throws -> Coordinate? {
        try withGeometry(geometry) { pointer in
            guard let result = GEOSGetCentroid_r(handle, pointer) else {
                throw takeError("centroid")
            }
            return try ManagedGeometry(taking: result, in: self).withPointer { point in
                if try predicate(GEOSisEmpty_r(handle, point), "isEmpty") { return nil }
                return try readCoordinates(point).first
            }
        }
    }

    /// A point a given distance along a line, for label placement.
    public func interpolate(_ line: LineString, distance: Double) throws -> Coordinate? {
        try makeLineString(line).withPointer { pointer in
            guard let result = GEOSInterpolate_r(handle, pointer, distance) else {
                throw takeError("interpolate")
            }
            return try ManagedGeometry(taking: result, in: self).withPointer { point in
                try readCoordinates(point).first
            }
        }
    }

    /// Cut a set of lines into the minimal set of faces they enclose.
    ///
    /// This is the step that makes elevation bands possible without hand-rolling
    /// ring nesting: closed contour rings go in, every face they bound comes out,
    /// and which faces to keep is then a question the data answers.
    ///
    /// `GEOSPolygonize` **borrows** its inputs, so the whole input array has to
    /// stay alive across the call. This is where getting that wrong crashed.
    public func polygonize(_ lines: [LineString]) throws -> [Polygon] {
        let usable = lines.filter { $0.coordinates.count >= 2 }
        guard !usable.isEmpty else { return [] }
        let managed = try usable.map(makeLineString)

        return try withExtendedLifetime(managed) {
            var pointers: [OpaquePointer?] = managed.map { $0.withPointer { $0 } }
            let result: OpaquePointer? = pointers.withUnsafeMutableBufferPointer { buffer in
                GEOSPolygonize_r(handle, buffer.baseAddress, UInt32(buffer.count))
            }
            guard let result else { throw takeError("polygonize") }
            return try ManagedGeometry(taking: result, in: self).withPointer {
                try read($0).polygons
            }
        }
    }

    // MARK: -

    /// Wrap a freshly returned GEOS pointer, read it, and free it.
    private func consuming(_ pointer: OpaquePointer?, _ what: String) throws -> Geometry {
        guard let pointer else { throw takeError(what) }
        return try ManagedGeometry(taking: pointer, in: self).withPointer { try read($0) }
    }
}
