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
        let result = blendSeaFloor(base(), with: finer(-500), over: frame)
        for column in 0..<result.field.columns {
            XCTAssertEqual(result.field[0, column], 100, "the land was overwritten")
        }
    }

    func testTheSeaTakesTheFinerAnswer() {
        let result = blendSeaFloor(base(), with: finer(-500), over: frame)
        XCTAssertGreaterThan(result.replaced, 0)
        // Away from the coverage edge, where the feather is fully open.
        XCTAssertEqual(result.field[6, 4], -500, accuracy: 1e-9)
    }

    /// A positive cell in the coverage is land in the coverage, and it must not
    /// be written into the sea half either.
    func testAPositiveCellInTheCoverageIsIgnored() {
        let result = blendSeaFloor(base(), with: finer(250), over: frame)
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.field[6, 4], -100)
    }

    /// A hole in the coverage keeps whatever was there, rather than punching a
    /// hole in the map. The contour tracer reads NaN as "no ground here".
    func testAHoleInTheCoverageChangesNothing() {
        let result = blendSeaFloor(base(), with: finer(.nan), over: frame)
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.field[6, 4], -100)
    }

    /// And the reverse: a hole in the *base* is filled outright, because there
    /// is nothing to blend with and something is better than nothing.
    func testAHoleInTheMosaicIsFilledOutright() {
        let holed = Field2D(rows: 8, columns: 8) { row, _ in row < 4 ? 100 : .nan }
        let result = blendSeaFloor(holed, with: finer(-500), over: frame)
        XCTAssertGreaterThan(result.replaced, 0)
        XCTAssertEqual(result.field[6, 4], -500, accuracy: 1e-9)
    }

    // MARK: - The edge of coverage

    /// A hard switch between two grids that disagree by a few metres draws a
    /// straight line across open water, and a straight line on a bathymetric
    /// sheet reads as a fault or a survey track — which is to say, as data.
    func testTheEdgeOfCoverageIsFeatheredRatherThanCut() {
        // Coverage over the eastern half only, so the seam runs down the middle.
        let half = BoundingBox(minLon: 0.5, minLat: 0, maxLon: 1, maxLat: 1)
        let result = blendSeaFloor(
            base(rows: 8, columns: 32), with: finer(-500, over: half), over: frame
        )

        // Walking east from the seam towards the middle. Not as far as the
        // eastern boundary: the feather applies at *every* edge, so the values
        // deepen going in and shallow again on the way out, which is right and
        // is not what this test is about.
        let row = 6
        let values = (16..<24).map { result.field[row, $0] }

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
        let result = blendSeaFloor(
            base(), with: finer(-500, over: elsewhere), over: frame
        )
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.field[6, 4], -100)
    }

    // MARK: - What the sheet may claim about its sea floor

    /// The nearest honest thing to GEBCO's TID grid.
    ///
    /// TID says per cell whether a depth was multibeamed, singlebeamed,
    /// interpolated or predicted from satellite gravity — and it is published as
    /// a picture. GEBCO's WCS offers no coverages and EMODnet's quality index is
    /// WMS only, so the codes are reachable only by reverse-engineering a colour
    /// ramp out of an image, which this codebase refuses elsewhere by name.
    /// What is known per cell is which of two grids a depth came from.
    func testTheMaskSaysWhichGridEachCellCameFrom() {
        let result = blendSeaFloor(base(), with: finer(-500), over: frame)
        XCTAssertEqual(result.surveyed[6, 4], 1.0, accuracy: 1e-9, "sea, inside coverage")
        XCTAssertEqual(result.surveyed[0, 4], 0.0, "land keeps the mosaic, and says so")
    }

    /// A feathered cell is genuinely part one grid and part the other, and
    /// rounding it to "surveyed" would be the same overclaim in miniature.
    func testAFeatheredCellIsNotFullySurveyed() {
        let half = BoundingBox(minLon: 0.5, minLat: 0, maxLon: 1, maxLat: 1)
        let result = blendSeaFloor(
            base(rows: 8, columns: 32), with: finer(-500, over: half), over: frame
        )
        let atSeam = result.surveyed[6, 16]
        XCTAssertGreaterThan(atSeam, 0)
        XCTAssertLessThan(atSeam, 1)
    }

    /// The weakest-claim rule, the same one a whole map already follows: a
    /// contour running from surveyed ground onto the global grid is not a
    /// surveyed contour.
    func testAFeatureClaimsMeasuredOnlyWhereAllOfItIsSurveyed() {
        XCTAssertEqual(BlendedSeaFloor.claim(forSamples: [1, 1, 1]), .measured)
        XCTAssertEqual(BlendedSeaFloor.claim(forSamples: [1, 1, 0.5]), .approximate)
        XCTAssertEqual(BlendedSeaFloor.claim(forSamples: [0, 0]), .approximate)
        XCTAssertEqual(BlendedSeaFloor.claim(forSamples: []), .approximate)
    }

    /// Averaged over the sea, not over the sheet: a frame that is mostly land
    /// would otherwise report a low share and read as though its water were
    /// poorly known.
    func testTheShareIsOfTheSeaAndNotOfTheSheet() {
        let result = blendSeaFloor(base(), with: finer(-500), over: frame)
        let share = surveyedShareOfSea(grid: result.field, surveyed: result.surveyed)
        XCTAssertEqual(share, 1.0, accuracy: 1e-9, "every sea cell came from the survey")

        // The same grid with no coverage at all.
        let untouched = surveyedShareOfSea(grid: base(), surveyed: .zeros(like: base()))
        XCTAssertEqual(untouched, 0.0)
    }

    func testAFrameWithNoSeaHasNoShareToReport() {
        let land = Field2D(rows: 4, columns: 4, repeating: 250)
        XCTAssertEqual(surveyedShareOfSea(grid: land, surveyed: .zeros(like: land)), 0)
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

    /// The feather has to fall outside the drawing.
    ///
    /// It ramps from the edge of whatever coverage comes back, and what comes
    /// back is exactly what was asked for — so asking for the frame alone put a
    /// diluted margin around every sheet, including sheets sitting in the middle
    /// of the coverage with nothing to feather against. The Myrtoan Sea reported
    /// 89% of its sea floor surveyed when the true figure was all of it.
    func testTheRequestIsWiderThanTheFrameSoTheFeatherFallsOffThePage() {
        let frame = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)
        let asked = EMODnetBathymetry.widened(frame)
        XCTAssertLessThan(asked.minLon, frame.minLon)
        XCTAssertGreaterThan(asked.maxLon, frame.maxLon)
        XCTAssertLessThan(asked.minLat, frame.minLat)
        XCTAssertGreaterThan(asked.maxLat, frame.maxLat)
        // Wider than the feather it has to make room for.
        XCTAssertGreaterThan(
            (asked.maxLon - asked.minLon) / (frame.maxLon - frame.minLon), 1.12
        )
    }

    /// Asking outside the service's own extent returns a complaint rather than a
    /// coverage, so the margin stops at the edge of the world it knows.
    func testTheMarginDoesNotAskBeyondTheServicesOwnExtent() {
        let atTheEdge = BoundingBox(minLon: 41.0, minLat: 88.0, maxLon: 43.0, maxLat: 90.0)
        let asked = EMODnetBathymetry.widened(atTheEdge)
        XCTAssertLessThanOrEqual(asked.maxLon, emodnetCoverage.maxLon)
        XCTAssertLessThanOrEqual(asked.maxLat, emodnetCoverage.maxLat)
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
