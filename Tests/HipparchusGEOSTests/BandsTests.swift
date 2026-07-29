import XCTest
import HipparchusGeometry
@testable import HipparchusGEOS

/// Ported from `tests/test_bands.py`.
///
/// Filled elevation bands: regions nest, and the nesting has to be measured.

/// A single peak at the centre falling away radially.
func coneField(size: Int = 61, peak: Double = 100.0) -> Field2D {
    let axis = linspace(-1.0, 1.0, size)
    return Field2D(rows: size, columns: size) { row, column in
        let x = axis[column]
        let y = axis[row]
        let radius = (x * x + y * y).squareRoot()
        return Swift.max(peak * (1.0 - radius), 0.0)
    }
}

/// A ring-shaped rim with a hollow inside: the case that breaks naive fills.
/// Rises to the rim at r = 0.55 and drops away both outside and inside.
func craterField(size: Int = 81, rim: Double = 100.0) -> Field2D {
    let axis = linspace(-1.0, 1.0, size)
    return Field2D(rows: size, columns: size) { row, column in
        let x = axis[column]
        let y = axis[row]
        let radius = (x * x + y * y).squareRoot()
        return rim * Swift.max(1.0 - abs(radius - 0.55) / 0.45, 0.0)
    }
}

final class RegionTests: XCTestCase {
    private var geos = GEOSContext()
    override func setUp() { geos = GEOSContext() }

    func testAConeGivesOneDiscPerLevel() throws {
        let grid = coneField()
        let region = try regionAtOrAbove(grid, level: 50.0, using: geos)
        XCTAssertFalse(region.isEmpty)
        XCTAssertTrue(try geos.isValid(region))
        // Half height on a cone is half the radius, so a quarter of the area of
        // the full base disc.
        let base = try regionAtOrAbove(grid, level: 0.1, using: geos)
        XCTAssertEqual(try geos.area(region) / geos.area(base), 0.25, accuracy: 0.06)
    }

    func testHigherLevelsNestInsideLowerOnes() throws {
        let grid = coneField()
        let low = try regionAtOrAbove(grid, level: 20.0, using: geos)
        let high = try regionAtOrAbove(grid, level: 70.0, using: geos)
        XCTAssertLessThan(try geos.area(high), try geos.area(low))
        XCTAssertTrue(try geos.contains(try geos.buffer(low, distance: 0.5), high))
    }

    /// The failure this whole approach exists to avoid: filling the hollow.
    func testACraterRimRegionHasAHole() throws {
        let region = try regionAtOrAbove(craterField(), level: 60.0, using: geos)
        XCTAssertFalse(region.isEmpty)
        XCTAssertTrue(
            region.polygons.contains { !$0.holes.isEmpty },
            "a rim enclosing lower ground must produce a hole, not a filled disc"
        )
    }

    func testTheHollowInsideACraterIsNotCovered() throws {
        let grid = craterField()
        let region = try regionAtOrAbove(grid, level: 60.0, using: geos)
        let centre = Coordinate(x: Double(grid.columns - 1) / 2.0, y: Double(grid.rows - 1) / 2.0)
        XCTAssertFalse(try geos.contains(region, .point(centre)))
    }

    func testAFieldEntirelyAboveTheLevelFillsTheMap() throws {
        let grid = Field2D(rows: 20, columns: 30, repeating: 500.0)
        let region = try regionAtOrAbove(grid, level: 100.0, using: geos)
        XCTAssertEqual(try geos.area(region), 29.0 * 19.0, accuracy: 1e-6)
    }

    func testAFieldEntirelyBelowTheLevelIsEmpty() throws {
        let grid = Field2D(rows: 20, columns: 30, repeating: 5.0)
        XCTAssertTrue(try regionAtOrAbove(grid, level: 100.0, using: geos).isEmpty)
    }

    /// Without the sentinel border this leaves an open chain and no polygon.
    func testALandformRunningOffTheEdgeIsClosedAgainstTheFrame() throws {
        let ramp = linspace(0.0, 100.0, 40)
        let grid = Field2D(rows: 30, columns: 40) { _, column in ramp[column] }
        let region = try regionAtOrAbove(grid, level: 50.0, using: geos)
        XCTAssertFalse(region.isEmpty)
        XCTAssertTrue(try geos.isValid(region))
        // The eastern half is above 50, so about half the map.
        XCTAssertEqual(try geos.area(region) / (39.0 * 29.0), 0.5, accuracy: 0.05)
    }

    func testRegionsStayInsideTheGrid() throws {
        let grid = coneField()
        let region = try regionAtOrAbove(grid, level: 10.0, using: geos)
        let bounds = try XCTUnwrap(region.bounds)
        XCTAssertGreaterThanOrEqual(bounds.minX, -1e-6)
        XCTAssertGreaterThanOrEqual(bounds.minY, -1e-6)
        XCTAssertLessThanOrEqual(bounds.maxX, Double(grid.columns - 1) + 1e-6)
        XCTAssertLessThanOrEqual(bounds.maxY, Double(grid.rows - 1) + 1e-6)
    }

    func testNonFiniteSamplesAreTreatedAsAbsent() throws {
        var values = coneField().values
        for row in 0..<5 { for column in 0..<5 { values[row * 61 + column] = .nan } }
        let grid = Field2D(rows: 61, columns: 61, values: values)
        XCTAssertTrue(try geos.isValid(try regionAtOrAbove(grid, level: 10.0, using: geos)))
    }

    func testDegenerateGridsAreSafe() throws {
        XCTAssertTrue(try regionAtOrAbove(Field2D(rows: 1, columns: 5, repeating: 0), level: 0.5, using: geos).isEmpty)
        XCTAssertTrue(try regionAtOrAbove(Field2D(rows: 5, columns: 5, repeating: .nan), level: 0.5, using: geos).isEmpty)
    }
}

final class BandTests: XCTestCase {
    private var geos = GEOSContext()
    override func setUp() { geos = GEOSContext() }

    func testBandsTileTheGroundWithoutOverlapping() throws {
        let grid = coneField()
        let bands = try elevationBands(grid, boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 8), using: geos)
        XCTAssertGreaterThan(bands.count, 4)
        for first in bands.indices {
            for second in (first + 1)..<bands.count {
                let overlap = try geos.area(try geos.intersection(bands[first].geometry, bands[second].geometry))
                XCTAssertLessThan(overlap, 0.5, "bands must not overlap")
            }
        }
    }

    func testBandsCoverTheGroundTheyDescribe() throws {
        let grid = coneField()
        let bands = try elevationBands(grid, boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 8), using: geos)
        var total = 0.0
        for band in bands { total += try geos.area(band.geometry) }
        let base = try geos.area(try regionAtOrAbove(grid, level: 0.0, using: geos))
        XCTAssertEqual(total / base, 1.0, accuracy: 0.05)
    }

    func testEachBandSitsBetweenItsOwnBounds() throws {
        let bands = try elevationBands(coneField(), boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 5), using: geos)
        for band in bands {
            XCTAssertLessThan(band.lower, band.upper)
            XCTAssertGreaterThan(band.midpoint, band.lower)
            XCTAssertLessThan(band.midpoint, band.upper)
        }
    }

    func testBandsAreReturnedLowToHigh() throws {
        let bands = try elevationBands(coneField(), boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 6), using: geos)
        XCTAssertEqual(bands.map(\.lower), bands.map(\.lower).sorted())
    }

    func testABandOverACraterKeepsItsHole() throws {
        let bands = try elevationBands(craterField(), boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 5), using: geos)
        XCTAssertFalse(bands.isEmpty)
        XCTAssertTrue(
            bands.contains { band in band.geometry.polygons.contains { !$0.holes.isEmpty } },
            "a ring-shaped landform must yield a banded ring"
        )
    }

    func testEveryBandIsValidGeometry() throws {
        for band in try elevationBands(coneField(), boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 10), using: geos) {
            XCTAssertTrue(try geos.isValid(band.geometry))
            XCTAssertFalse(band.geometry.isEmpty)
        }
    }

    func testTooFewBoundariesYieldNothing() throws {
        XCTAssertTrue(try elevationBands(coneField(), boundaries: [50.0], using: geos).isEmpty)
        XCTAssertTrue(try elevationBands(coneField(), boundaries: [], using: geos).isEmpty)
    }

    func testDuplicateBoundariesAreCollapsed() throws {
        let bands = try elevationBands(coneField(), boundaries: [0.0, 50.0, 50.0, 100.0], using: geos)
        XCTAssertEqual(bands.count, 2)
    }
}

final class BoundaryTests: XCTestCase {

    func testBoundariesSpanTheRange() {
        XCTAssertEqual(bandBoundaries(minimum: 0.0, maximum: 100.0, count: 4), [0.0, 25.0, 50.0, 75.0, 100.0])
    }

    func testDegenerateRangesYieldNothing() {
        XCTAssertEqual(bandBoundaries(minimum: 50.0, maximum: 50.0, count: 4), [])
        XCTAssertEqual(bandBoundaries(minimum: 100.0, maximum: 0.0, count: 4), [])
        XCTAssertEqual(bandBoundaries(minimum: 0.0, maximum: 100.0, count: 0), [])
    }
}

final class CoordinateMappingTests: XCTestCase {

    /// The swap that has to happen exactly once: the mapper reads `(row, column)`
    /// while the geometry holds `(x = column, y = row)`.
    func testIndexSpacePolygonsAreRemappedWithHolesIntact() throws {
        let polygon = Geometry.polygon(Polygon(
            exterior: [Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0), Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10)],
            holes: [[Coordinate(x: 3, y: 3), Coordinate(x: 6, y: 3), Coordinate(x: 6, y: 6), Coordinate(x: 3, y: 6)]]
        ))

        let mapped = mapIndexSpaceToLonLat(polygon) { point in
            Coordinate(lon: point.column * 0.1, lat: 50.0 - point.row * 0.1)
        }

        let result = try XCTUnwrap(mapped.polygons.first)
        XCTAssertEqual(result.holes.count, 1)
        XCTAssertEqual(result.exterior.coordinates[0].lon, 0.0, accuracy: 1e-12)
        XCTAssertEqual(result.exterior.coordinates[0].lat, 50.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(mapped.bounds).maxX, 1.0, accuracy: 1e-12)
    }
}

// MARK: -

/// `np.linspace`, for the ported tests.
func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
    guard count > 1 else { return count == 1 ? [start] : [] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { start + Double($0) * step }
}
