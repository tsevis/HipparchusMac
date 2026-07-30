import XCTest
@testable import HipparchusGeometry

/// The Chaikin pass and the per-layer policy are pure arithmetic, so they are
/// tested here rather than beside the GEOS-backed repair wrapper.
final class ChaikinTests: XCTestCase {

    func testAnOpenLineKeepsItsEndpointsPinned() {
        let coordinates = [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 2, y: 0)]
        let result = chaikin(coordinates, iterations: 2, closed: false)
        // A coastline that drifts away from where it met the frame leaves a gap.
        XCTAssertEqual(result.first, coordinates.first)
        XCTAssertEqual(result.last, coordinates.last)
    }

    func testAClosedRingStaysClosed() {
        let ring = [
            Coordinate(x: 0, y: 0), Coordinate(x: 4, y: 0),
            Coordinate(x: 4, y: 4), Coordinate(x: 0, y: 4), Coordinate(x: 0, y: 0),
        ]
        let result = chaikin(ring, iterations: 2, closed: true)
        XCTAssertEqual(result.first, result.last)
        XCTAssertGreaterThan(result.count, ring.count)
    }

    func testVertexCountRoughlyDoublesPerIteration() {
        let ring = (0..<8).map { Coordinate(x: cos(Double($0)), y: sin(Double($0))) }
        let once = chaikin(ring, iterations: 1, closed: false).count
        let twice = chaikin(ring, iterations: 2, closed: false).count
        XCTAssertGreaterThan(twice, once)
        // Two passes is a lot and three is usually too many; this is why.
        XCTAssertGreaterThan(Double(twice), Double(once) * 1.7)
    }

    func testSmoothingPullsTheCurveInsideTheCorner() {
        // The point of corner cutting: the sharp vertex is replaced by two points
        // that sit on the edges either side of it.
        let corner = [Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0), Coordinate(x: 10, y: 10)]
        let result = chaikin(corner, iterations: 1, closed: false)
        XCTAssertFalse(result.contains(Coordinate(x: 10, y: 0)), "the corner itself should be gone")
        for point in result {
            XCTAssertLessThanOrEqual(point.x, 10.0 + 1e-9)
            XCTAssertLessThanOrEqual(point.y, 10.0 + 1e-9)
        }
    }

    func testTooFewPointsToCutAreReturnedUnchanged() {
        XCTAssertEqual(chaikin([], iterations: 2, closed: false), [])
        let single = [Coordinate(x: 1, y: 1)]
        XCTAssertEqual(chaikin(single, iterations: 2, closed: false), single)
        let pair = [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1)]
        XCTAssertEqual(chaikin(pair, iterations: 2, closed: false), pair)
    }

    func testSmoothingIsDeterministic() {
        let ring = (0..<20).map { Coordinate(x: cos(Double($0) * 0.3), y: sin(Double($0) * 0.3)) }
        XCTAssertEqual(
            chaikin(ring, iterations: 3, closed: true),
            chaikin(ring, iterations: 3, closed: true)
        )
    }
}

final class SmoothingPolicyTests: XCTestCase {

    func testLineLayersSmoothLinesOnly() {
        for layer in ["roads", "railways", "terrain_contours", "night_lights", "satellite_tracks", "bathymetry"] {
            let rule = smoothingRule(for: layer, baseIterations: 2)
            XCTAssertEqual(rule.iterations, 2, layer)
            XCTAssertFalse(rule.smoothPolygons, layer)
        }
    }

    func testTheRoadHierarchyIsMatchedByPrefix() {
        // Eight layers to the renderer, one idea to a reader.
        for layer in ["roads_motorway", "roads_residential", "roads_service"] {
            XCTAssertEqual(smoothingRule(for: layer, baseIterations: 1).iterations, 1, layer)
        }
    }

    func testPolygonLayersSmoothTheirBoundaries() {
        for layer in ["water", "parks", "forests", "fields", "natural", "landuse"] {
            let rule = smoothingRule(for: layer, baseIterations: 2)
            XCTAssertEqual(rule.iterations, 2, layer)
            XCTAssertTrue(rule.smoothPolygons, layer)
        }
    }

    func testCoastlineIsBothALineAndAPolygonLayer() {
        // It arrives either way depending on the source, and the line rule wins —
        // which is checked here so a reordering of the lookup is noticed.
        let rule = smoothingRule(for: "coastline", baseIterations: 3)
        XCTAssertEqual(rule.iterations, 3)
        XCTAssertFalse(rule.smoothPolygons)
    }

    func testSurveyedLayersAreNeverSmoothed() {
        for layer in ["buildings", "barriers", "power", "shops", "amenities", "places"] {
            XCTAssertEqual(smoothingRule(for: layer, baseIterations: 5).iterations, 0, layer)
        }
    }
}

import Foundation
