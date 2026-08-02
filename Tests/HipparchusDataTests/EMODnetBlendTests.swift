import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry

/// Putting a finer sea floor under a coarser one.
///
/// Every rule here exists because of a way this goes wrong on a real sheet, and
/// two of them were learned from the data rather than reasoned about.
final class EMODnetBlendTests: XCTestCase {

    private let frame = BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)

    /// A coarse grid: half land at +100, half sea at −100.
    private func base(rows: Int = 8, columns: Int = 8) -> Field2D {
        Field2D(rows: rows, columns: columns) { row, _ in
            row < rows / 2 ? 100 : -100
        }
    }

    private func finer(
        _ value: Double, over bounds: BoundingBox? = nil, rows: Int = 16, columns: Int = 16
    ) -> GeoTIFFGrid {
        GeoTIFFGrid(
            field: Field2D(rows: rows, columns: columns, repeating: value),
            bounds: bounds ?? frame
        )
    }

    // MARK: - What it replaces

    /// EMODnet carries land, and its land is coarser than SRTM's. Taking every
    /// finite cell would answer a question the mosaic already answered better.
    func testLandKeepsTheMosaicsAnswer() {
        let (blended, _) = blendSeaFloor(base(), with: finer(-500), over: frame)
        for column in 0..<blended.columns {
            XCTAssertEqual(blended[0, column], 100, "the land was overwritten")
        }
    }

    func testTheSeaTakesTheFinerAnswer() {
        let (blended, replaced) = blendSeaFloor(base(), with: finer(-500), over: frame)
        XCTAssertGreaterThan(replaced, 0)
        // Away from the coverage edge, where the feather is fully open.
        XCTAssertEqual(blended[6, 4], -500, accuracy: 1e-9)
    }

    /// A positive cell in the coverage is land in the coverage, and it must not
    /// be written into the sea half either.
    func testAPositiveCellInTheCoverageIsIgnored() {
        let (blended, replaced) = blendSeaFloor(base(), with: finer(250), over: frame)
        XCTAssertEqual(replaced, 0)
        XCTAssertEqual(blended[6, 4], -100)
    }

    /// A hole in the coverage keeps whatever was there, rather than punching a
    /// hole in the map. The contour tracer reads NaN as "no ground here".
    func testAHoleInTheCoverageChangesNothing() {
        let (blended, replaced) = blendSeaFloor(base(), with: finer(.nan), over: frame)
        XCTAssertEqual(replaced, 0)
        XCTAssertEqual(blended[6, 4], -100)
    }

    /// And the reverse: a hole in the *base* is filled outright, because there
    /// is nothing to blend with and something is better than nothing.
    func testAHoleInTheMosaicIsFilledOutright() {
        let holed = Field2D(rows: 8, columns: 8) { row, _ in row < 4 ? 100 : .nan }
        let (blended, replaced) = blendSeaFloor(holed, with: finer(-500), over: frame)
        XCTAssertGreaterThan(replaced, 0)
        XCTAssertEqual(blended[6, 4], -500, accuracy: 1e-9)
    }

    // MARK: - The edge of coverage

    /// A hard switch between two grids that disagree by a few metres draws a
    /// straight line across open water, and a straight line on a bathymetric
    /// sheet reads as a fault or a survey track — which is to say, as data.
    func testTheEdgeOfCoverageIsFeatheredRatherThanCut() {
        // Coverage over the eastern half only, so the seam runs down the middle.
        let half = BoundingBox(minLon: 0.5, minLat: 0, maxLon: 1, maxLat: 1)
        let (blended, _) = blendSeaFloor(
            base(rows: 8, columns: 32), with: finer(-500, over: half), over: frame
        )

        // Walking east from the seam towards the middle. Not as far as the
        // eastern boundary: the feather applies at *every* edge, so the values
        // deepen going in and shallow again on the way out, which is right and
        // is not what this test is about.
        let row = 6
        let values = (16..<24).map { blended[row, $0] }

        // The property is "neither grid, at the edge": a cut would land exactly
        // on -500 from the first cell inside coverage.
        XCTAssertGreaterThan(values.first!, -500, "the seam is a cut, not a feather")
        XCTAssertLessThan(values.first!, -100, "and it should already be deepening")
        XCTAssertEqual(values.last!, -500, accuracy: 1e-6, "and reach the coverage a little way in")

        // Monotone, and no single step carrying most of the difference.
        let steps = zip(values, values.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(steps.allSatisfy { $0 <= 1e-9 }, "the blend should only deepen going in")
        let biggest = steps.map(abs).max() ?? 0
        XCTAssertLessThan(biggest, 400 * 0.8, "one step carried most of the seam")
    }

    func testGroundOutsideTheCoverageIsUntouched() {
        let elsewhere = BoundingBox(minLon: 40, minLat: 40, maxLon: 41, maxLat: 41)
        let (blended, replaced) = blendSeaFloor(
            base(), with: finer(-500, over: elsewhere), over: frame
        )
        XCTAssertEqual(replaced, 0)
        XCTAssertEqual(blended[6, 4], -100)
    }

    // MARK: - Asking at all

    /// A frame outside European waters should cost nothing: no round trip, no
    /// parse failure, no error document read as a grid.
    func testItDoesNotAskAboutWaterItDoesNotHave() {
        XCTAssertFalse(EMODnetBathymetry.covers(
            BoundingBox(minLon: -160, minLat: 18, maxLon: -154, maxLat: 22)   // Hawaii
        ))
        XCTAssertFalse(EMODnetBathymetry.covers(
            BoundingBox(minLon: 150, minLat: -35, maxLon: 152, maxLat: -33)   // Sydney
        ))
        XCTAssertTrue(EMODnetBathymetry.covers(
            BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)  // Myrtoan Sea
        ))
        XCTAssertTrue(EMODnetBathymetry.covers(
            BoundingBox(minLon: 32.9, minLat: 34.5, maxLon: 33.3, maxLat: 34.8)  // Cyprus
        ))
    }

    /// WCS 1.0.0 states a bbox longitude first, which is the opposite of the
    /// Overpass convention two files away — and getting it backwards returns a
    /// valid coverage of somewhere else.
    func testTheRequestStatesItsBoxLongitudeFirst() throws {
        let service = EMODnetBathymetry()
        let url = try XCTUnwrap(
            service.url(
                for: BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1),
                width: 100, height: 80
            )
        )
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("bbox=23.2,36.3,24.2,37.1"), query)
        XCTAssertTrue(query.contains("format=GeoTIFF"))
        XCTAssertTrue(query.contains("crs=EPSG:4326") || query.contains("crs=EPSG%3A4326"))
    }
}
