import CGEOS
import HipparchusGeometry

// Conversion goes through GEOS coordinate sequences rather than WKB.
//
// WKB would be less code — the Python already round-trips it for its process
// pool — but a band level polygonizes thousands of contour rings, and paying a
// serialise/parse for each one is a cost the pipeline can see. Coordinate
// sequences write straight into the geometry GEOS is about to operate on.
extension GEOSContext {

    // MARK: - Swift to GEOS

    func make(_ geometry: Geometry) throws -> ManagedGeometry {
        switch geometry {
        case .empty:
            return ManagedGeometry(taking: try require(GEOSGeom_createEmptyCollection_r(handle, Int32(GEOS_GEOMETRYCOLLECTION.rawValue)), "empty collection"), in: self)

        case .point(let coordinate):
            guard coordinate.isFinite else {
                return ManagedGeometry(taking: try require(GEOSGeom_createEmptyPoint_r(handle), "empty point"), in: self)
            }
            let sequence = try makeCoordinateSequence([coordinate])
            return ManagedGeometry(taking: try require(GEOSGeom_createPoint_r(handle, sequence), "point"), in: self)

        case .multiPoint(let coordinates):
            let parts = try coordinates.filter(\.isFinite).map { coordinate -> ManagedGeometry in
                let sequence = try makeCoordinateSequence([coordinate])
                return ManagedGeometry(taking: try require(GEOSGeom_createPoint_r(handle, sequence), "point"), in: self)
            }
            return try makeCollection(parts, type: GEOS_MULTIPOINT)

        case .lineString(let line):
            return try makeLineString(line)

        case .multiLineString(let lines):
            return try makeCollection(try lines.map(makeLineString), type: GEOS_MULTILINESTRING)

        case .polygon(let polygon):
            return try makePolygon(polygon)

        case .multiPolygon(let polygons):
            return try makeCollection(try polygons.map(makePolygon), type: GEOS_MULTIPOLYGON)

        case .collection(let parts):
            return try makeCollection(try parts.map(make), type: GEOS_GEOMETRYCOLLECTION)
        }
    }

    func makeLineString(_ line: LineString) throws -> ManagedGeometry {
        guard line.coordinates.count >= 2 else {
            return ManagedGeometry(taking: try require(GEOSGeom_createEmptyLineString_r(handle), "empty line"), in: self)
        }
        let sequence = try makeCoordinateSequence(line.coordinates)
        return ManagedGeometry(taking: try require(GEOSGeom_createLineString_r(handle, sequence), "line string"), in: self)
    }

    func makePolygon(_ polygon: Polygon) throws -> ManagedGeometry {
        guard !polygon.isEmpty else {
            return ManagedGeometry(taking: try require(GEOSGeom_createEmptyPolygon_r(handle), "empty polygon"), in: self)
        }
        let shell = try makeRing(polygon.exterior)
        let holes = try polygon.holes.map(makeRing)
        // createPolygon takes ownership of the shell and of every hole, so they
        // are released here and freed by GEOS with the polygon.
        var holePointers: [OpaquePointer?] = holes.map { $0.release() }
        let shellPointer = shell.release()
        let created: OpaquePointer? = holePointers.withUnsafeMutableBufferPointer { buffer in
            GEOSGeom_createPolygon_r(handle, shellPointer, buffer.baseAddress, UInt32(buffer.count))
        }
        guard let created else {
            // Ownership never transferred, so the parts are still ours to free.
            GEOSGeom_destroy_r(handle, shellPointer)
            for pointer in holePointers { pointer.map { GEOSGeom_destroy_r(handle, $0) } }
            throw takeError("polygon")
        }
        return ManagedGeometry(taking: created, in: self)
    }

    private func makeRing(_ ring: Ring) throws -> ManagedGeometry {
        let sequence = try makeCoordinateSequence(ring.coordinates)
        return ManagedGeometry(taking: try require(GEOSGeom_createLinearRing_r(handle, sequence), "linear ring"), in: self)
    }

    private func makeCoordinateSequence(_ coordinates: [Coordinate]) throws -> OpaquePointer {
        let sequence = try require(GEOSCoordSeq_create_r(handle, UInt32(coordinates.count), 2), "coordinate sequence")
        for (index, coordinate) in coordinates.enumerated() {
            if GEOSCoordSeq_setXY_r(handle, sequence, UInt32(index), coordinate.x, coordinate.y) == 0 {
                GEOSCoordSeq_destroy_r(handle, sequence)
                throw takeError("coordinate sequence write")
            }
        }
        return sequence
    }

    func makeCollection(_ parts: [ManagedGeometry], type: GEOSGeomTypes) throws -> ManagedGeometry {
        guard !parts.isEmpty else {
            return ManagedGeometry(taking: try require(GEOSGeom_createEmptyCollection_r(handle, Int32(type.rawValue)), "empty collection"), in: self)
        }
        var pointers: [OpaquePointer?] = parts.map { $0.release() }
        let created: OpaquePointer? = pointers.withUnsafeMutableBufferPointer { buffer in
            GEOSGeom_createCollection_r(handle, Int32(type.rawValue), buffer.baseAddress, UInt32(buffer.count))
        }
        guard let created else {
            for pointer in pointers { pointer.map { GEOSGeom_destroy_r(handle, $0) } }
            throw takeError("collection")
        }
        return ManagedGeometry(taking: created, in: self)
    }

    // MARK: - GEOS to Swift

    func read(_ pointer: OpaquePointer) throws -> Geometry {
        if try predicate(GEOSisEmpty_r(handle, pointer), "isEmpty") {
            return .empty
        }
        let typeId = GEOSGeomTypeId_r(handle, pointer)
        guard typeId >= 0 else { throw takeError("geometry type") }

        switch UInt32(typeId) {
        case GEOS_POINT.rawValue:
            let coordinates = try readCoordinates(pointer)
            guard let first = coordinates.first else { return .empty }
            return .point(first)

        case GEOS_LINESTRING.rawValue, GEOS_LINEARRING.rawValue:
            return .lineString(LineString(try readCoordinates(pointer)))

        case GEOS_POLYGON.rawValue:
            return .polygon(try readPolygon(pointer))

        case GEOS_MULTIPOINT.rawValue:
            return .multiPoint(try readParts(pointer).compactMap { part in
                try readCoordinates(part).first
            })

        case GEOS_MULTILINESTRING.rawValue:
            return .multiLineString(try readParts(pointer).map { LineString(try readCoordinates($0)) })

        case GEOS_MULTIPOLYGON.rawValue:
            return .multiPolygon(try readParts(pointer).map(readPolygon))

        case GEOS_GEOMETRYCOLLECTION.rawValue:
            return .collection(try readParts(pointer).map(read))

        default:
            throw GEOSError.unsupportedType(typeId)
        }
    }

    private func readPolygon(_ pointer: OpaquePointer) throws -> Polygon {
        // The exterior ring and the interior rings are borrowed from the polygon.
        // Destroying them would free part of a geometry GEOS still owns.
        guard let shell = GEOSGetExteriorRing_r(handle, pointer) else {
            throw takeError("exterior ring")
        }
        let holeCount = GEOSGetNumInteriorRings_r(handle, pointer)
        guard holeCount >= 0 else { throw takeError("interior ring count") }
        var holes: [Ring] = []
        holes.reserveCapacity(Int(holeCount))
        for index in 0..<holeCount {
            guard let hole = GEOSGetInteriorRingN_r(handle, pointer, index) else {
                throw takeError("interior ring")
            }
            holes.append(Ring(try readCoordinates(hole)))
        }
        return Polygon(exterior: Ring(try readCoordinates(shell)), holes: holes)
    }

    private func readParts(_ pointer: OpaquePointer) throws -> [OpaquePointer] {
        let count = GEOSGetNumGeometries_r(handle, pointer)
        guard count >= 0 else { throw takeError("geometry count") }
        var parts: [OpaquePointer] = []
        parts.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let part = GEOSGetGeometryN_r(handle, pointer, index) else {
                throw takeError("geometry at index")
            }
            parts.append(part)
        }
        return parts
    }

    func readCoordinates(_ pointer: OpaquePointer) throws -> [Coordinate] {
        guard let sequence = GEOSGeom_getCoordSeq_r(handle, pointer) else {
            throw takeError("coordinate sequence read")
        }
        var size: UInt32 = 0
        guard GEOSCoordSeq_getSize_r(handle, sequence, &size) != 0 else {
            throw takeError("coordinate sequence size")
        }
        var coordinates: [Coordinate] = []
        coordinates.reserveCapacity(Int(size))
        for index in 0..<size {
            var x = 0.0
            var y = 0.0
            guard GEOSCoordSeq_getXY_r(handle, sequence, index, &x, &y) != 0 else {
                throw takeError("coordinate sequence read")
            }
            coordinates.append(Coordinate(x: x, y: y))
        }
        return coordinates
    }
}
