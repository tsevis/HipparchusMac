import XCTest
import HipparchusGeometry
@testable import HipparchusGEOS

/// Ported from `tests/test_smoothing.py`, with the policy cases the Python covers
/// only indirectly through the presets.
final class SmoothingTests: XCTestCase {
    private var geos = GEOSContext()
    override func setUp() { geos = GEOSContext() }

    func testSmoothsRoadsDeterministically() throws {
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 2, y: 0),
        ]))
        let result = try geos.smoothLayer("roads_residential", geometries: [line], iterations: 1)

        XCTAssertEqual(result.smoothed, 1)
        XCTAssertEqual(result.invalid, 0)
        XCTAssertGreaterThan(
            result.geometries[0].lineStrings[0].coordinates.count,
            line.lineStrings[0].coordinates.count
        )
        // Deterministic: the same input smooths to the same output every time, or
        // the exported SVG changes between runs of the same map.
        let again = try geos.smoothLayer("roads_residential", geometries: [line], iterations: 1)
        XCTAssertEqual(result.geometries, again.geometries)
    }

    func testDoesNotSmoothBuildings() throws {
        let building = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 1, y: 1),
        ]))
        let result = try geos.smoothLayer("buildings", geometries: [building], iterations: 3)

        XCTAssertEqual(result.smoothed, 0)
        XCTAssertEqual(result.invalid, 0)
        XCTAssertEqual(result.geometries, [building], "a surveyed edge must come through untouched")
    }

    func testSmoothsWaterPolygonBoundaries() throws {
        let water = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 2, y: 0), Coordinate(x: 2, y: 1), Coordinate(x: 1, y: 2),
        ]))
        let result = try geos.smoothLayer("water", geometries: [water], iterations: 1)

        XCTAssertEqual(result.smoothed, 1)
        XCTAssertEqual(result.invalid, 0)
        XCTAssertGreaterThan(
            result.geometries[0].polygons[0].exterior.coordinates.count,
            water.polygons[0].exterior.coordinates.count
        )
        XCTAssertTrue(try geos.isValid(result.geometries[0]))
    }

    func testContoursAreSmoothedBecauseTheyComeOffASamplingGrid() throws {
        let staircase = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 1, y: 1),
            Coordinate(x: 2, y: 1), Coordinate(x: 2, y: 2),
        ]))
        for layer in ["terrain_contours", "terrain_index_contours", "bathymetry"] {
            let result = try geos.smoothLayer(layer, geometries: [staircase], iterations: 1)
            XCTAssertEqual(result.smoothed, 1, layer)
        }
    }

    func testAPolygonLayerIsNotSmoothedAsIfItWereALine() throws {
        // `terrain_contours` is a line layer, so a polygon handed to it is left
        // alone rather than having its rings cut.
        let square = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 2, y: 0), Coordinate(x: 2, y: 2), Coordinate(x: 0, y: 2),
        ]))
        let result = try geos.smoothLayer("terrain_contours", geometries: [square], iterations: 2)
        XCTAssertEqual(result.geometries, [square])
    }

    func testAnUnknownLayerIsLeftAlone() throws {
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 2, y: 0),
        ]))
        let result = try geos.smoothLayer("something_new", geometries: [line], iterations: 2)
        XCTAssertEqual(result.smoothed, 0)
        XCTAssertEqual(result.geometries, [line], "a new layer has to ask for smoothing")
    }

    func testZeroIterationsIsAPassThrough() throws {
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 2, y: 0),
        ]))
        for iterations in [0, -1] {
            let result = try geos.smoothLayer("terrain_contours", geometries: [line], iterations: iterations)
            XCTAssertEqual(result.geometries, [line])
            XCTAssertEqual(result.smoothed, 0)
        }
    }
}
