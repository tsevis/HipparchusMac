import XCTest
import HipparchusGeometry
@testable import HipparchusGEOS

/// The bridge has no Python counterpart to port, so these are new: they pin the
/// conversion in both directions and every operation the elevation-band pipeline
/// depends on. If GEOS is ever relinked or rebuilt, this is what says so.
final class GEOSBridgeTests: XCTestCase {

    func testTheLibraryIsLinkedAndReportsItsVersion() {
        let version = GEOSContext().version
        XCTAssertTrue(version.hasPrefix("3.14.1"), "expected the pinned GEOS, got \(version)")
    }

    // MARK: - Round trips

    func testPointRoundTrips() throws {
        try assertRoundTrip(.point(Coordinate(x: 3.5, y: -7.25)))
    }

    func testLineStringRoundTrips() throws {
        try assertRoundTrip(.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 2), Coordinate(x: 4, y: 3),
        ])))
    }

    func testPolygonWithAHoleRoundTrips() throws {
        let polygon = Polygon(
            exterior: [
                Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0),
                Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10),
            ],
            holes: [[
                Coordinate(x: 3, y: 3), Coordinate(x: 7, y: 3),
                Coordinate(x: 7, y: 7), Coordinate(x: 3, y: 7),
            ]]
        )
        let context = GEOSContext()
        let managed = try context.make(.polygon(polygon))
        let back = try context.read(managed.borrowed)
        guard case .polygon(let result) = back else {
            return XCTFail("expected a polygon, got \(back.typeName)")
        }
        XCTAssertEqual(result.holes.count, 1)
        XCTAssertEqual(result.exterior.coordinates.count, 5, "the ring must be closed")
        // A hole means the area is the square minus the square.
        XCTAssertEqual(try context.area(.polygon(result)), 100.0 - 16.0, accuracy: 1e-9)
    }

    func testMultiPolygonRoundTrips() throws {
        let geometry = Geometry.multiPolygon([
            Polygon(exterior: [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 0, y: 1)]),
            Polygon(exterior: [Coordinate(x: 5, y: 5), Coordinate(x: 6, y: 5), Coordinate(x: 6, y: 6), Coordinate(x: 5, y: 6)]),
        ])
        try assertRoundTrip(geometry)
    }

    func testEmptyGeometryRoundTripsAsEmpty() throws {
        let context = GEOSContext()
        let managed = try context.make(.empty)
        XCTAssertEqual(try context.read(managed.borrowed), .empty)
    }

    // MARK: - Operations the band pipeline needs

    func testPolygonizeCutsCrossingRingsIntoFaces() throws {
        // Two rings sharing an edge cut into two faces, not one merged shape.
        let left = LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0),
            Coordinate(x: 1, y: 1), Coordinate(x: 0, y: 1), Coordinate(x: 0, y: 0),
        ])
        let right = LineString([
            Coordinate(x: 1, y: 0), Coordinate(x: 2, y: 0),
            Coordinate(x: 2, y: 1), Coordinate(x: 1, y: 1), Coordinate(x: 1, y: 0),
        ])
        let faces = try GEOSContext().polygonize([left, right])
        XCTAssertEqual(faces.count, 2)
    }

    func testPolygonizeOfNothingIsEmptyRatherThanAnError() throws {
        XCTAssertTrue(try GEOSContext().polygonize([]).isEmpty)
    }

    func testUnaryUnionDissolvesTouchingSquaresIntoOne() throws {
        let context = GEOSContext()
        let a = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 0, y: 1),
        ]))
        let b = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 1, y: 0), Coordinate(x: 2, y: 0), Coordinate(x: 2, y: 1), Coordinate(x: 1, y: 1),
        ]))
        let merged = try context.unaryUnion([a, b])
        XCTAssertEqual(merged.polygons.count, 1)
        XCTAssertEqual(try context.area(merged), 2.0, accuracy: 1e-9)
    }

    func testDifferenceLeavesAHoleWhereTheUpperRegionWas() throws {
        // This is exactly how a band is built: one region minus the region above it.
        let context = GEOSContext()
        let lower = Geometry.polygon(Polygon.box(Bounds(minX: 0, minY: 0, maxX: 10, maxY: 10)))
        let upper = Geometry.polygon(Polygon.box(Bounds(minX: 3, minY: 3, maxX: 7, maxY: 7)))
        let band = try context.difference(lower, upper)
        XCTAssertEqual(try context.area(band), 100.0 - 16.0, accuracy: 1e-9)
        XCTAssertEqual(band.polygons.first?.holes.count, 1, "the enclosed hollow must stay hollow")
    }

    func testIntersectionTrimsToTheExtent() throws {
        let context = GEOSContext()
        let shape = Geometry.polygon(Polygon.box(Bounds(minX: -5, minY: -5, maxX: 5, maxY: 5)))
        let extent = Geometry.polygon(Polygon.box(Bounds(minX: 0, minY: 0, maxX: 10, maxY: 10)))
        XCTAssertEqual(try context.area(try context.intersection(shape, extent)), 25.0, accuracy: 1e-9)
    }

    func testPointOnSurfaceLandsInsideAPolygonWithAHole() throws {
        let context = GEOSContext()
        let polygon = Geometry.polygon(Polygon(
            exterior: [Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0), Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10)],
            holes: [[Coordinate(x: 1, y: 1), Coordinate(x: 9, y: 1), Coordinate(x: 9, y: 9), Coordinate(x: 1, y: 9)]]
        ))
        let point = try XCTUnwrap(try context.pointOnSurface(polygon))
        // The centroid of this shape sits in the hole; a representative point cannot.
        XCTAssertTrue(try context.contains(polygon, .point(point)), "point on surface must be inside the geometry")
    }

    func testBufferZeroRepairsASelfIntersectingRing() throws {
        let context = GEOSContext()
        // A bow-tie: valid as a ring, invalid as a polygon.
        let bowTie = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 2, y: 2),
            Coordinate(x: 2, y: 0), Coordinate(x: 0, y: 2),
        ]))
        XCTAssertFalse(try context.isValid(bowTie))
        let repaired = try context.repaired(bowTie)
        XCTAssertTrue(try context.isValid(repaired))
        XCTAssertFalse(repaired.isEmpty)
    }

    func testTopologyPreservingSimplifyKeepsThePolygonAPolygon() throws {
        let context = GEOSContext()
        var ring: [Coordinate] = []
        for step in 0..<64 {
            let angle = Double(step) / 64.0 * 2.0 * Double.pi
            ring.append(Coordinate(x: 10 * Foundation.cos(angle), y: 10 * Foundation.sin(angle)))
        }
        let circle = Geometry.polygon(Polygon(exterior: ring))
        let simplified = try context.simplify(circle, tolerance: 1.0, preserveTopology: true)
        let before = try XCTUnwrap(circle.polygons.first).exterior.coordinates.count
        let after = try XCTUnwrap(simplified.polygons.first).exterior.coordinates.count
        XCTAssertLessThan(after, before)
        XCTAssertTrue(try context.isValid(simplified))
    }

    func testAGEOSExceptionSurfacesAsASwiftErrorCarryingItsMessage() throws {
        let context = GEOSContext()
        // Overlaying a bow-tie on itself is a genuine topology exception inside
        // GEOS. It must arrive as a thrown Swift error with GEOS's own words,
        // not as empty geometry that quietly deletes a layer.
        let bowTie = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 2, y: 2),
            Coordinate(x: 2, y: 0), Coordinate(x: 0, y: 2),
        ]))
        XCTAssertThrowsError(try context.intersection(bowTie, bowTie)) { error in
            guard case GEOSError.operation(let message) = error else {
                return XCTFail("expected .operation with a GEOS message, got \(error)")
            }
            XCTAssertTrue(message.contains("intersection"), "should name the operation: \(message)")
            XCTAssertGreaterThan(message.count, "intersection: ".count, "should carry GEOS's own message: \(message)")
        }
    }

    func testADegenerateRingBecomesEmptyGeometryRatherThanAnError() throws {
        // Two points cannot bound anything. Contour tracing does produce short
        // fragments, so this has to be empty geometry the pipeline can drop, not
        // an exception that aborts a whole band level.
        let context = GEOSContext()
        let degenerate = Geometry.polygon(Polygon(exterior: Ring([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1),
        ])))
        XCTAssertTrue(try context.isEmpty(degenerate))
        XCTAssertEqual(try context.area(degenerate), 0.0)
    }

    // MARK: -

    private func assertRoundTrip(_ geometry: Geometry, file: StaticString = #filePath, line: UInt = #line) throws {
        let context = GEOSContext()
        let managed = try context.make(geometry)
        XCTAssertEqual(try context.read(managed.borrowed), geometry, file: file, line: line)
    }
}

import Foundation
