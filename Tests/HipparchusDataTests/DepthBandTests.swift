import XCTest
@testable import HipparchusData
@testable import HipparchusGEOS
@testable import HipparchusGeometry

/// Filled depth below the waterline, which the sea has never had.
///
/// `elevation_bands` has always spanned the whole measured range, so on a
/// coastal sheet the sea floor was already being banded — in the land ramp,
/// under the land's own colours, as though a trench were a kind of hill. The sea
/// got contours where the land got mass, and what mass it did get was wearing
/// the wrong clothes.
///
/// The split is the same one `separateBathymetry` already makes for contours,
/// one level up: land bands stay where they were, sub-sea bands become their
/// own layer with their own count and their own ramp.
final class DepthBandTests: XCTestCase {

    /// A cone rising out of water: the middle is land, the rim is sea floor, so
    /// any split has something on both sides of it to get wrong.
    private func island(rows: Int = 24, columns: Int = 24) -> Field2D {
        Field2D(rows: rows, columns: columns) { row, column in
            let dr = Double(row) - Double(rows - 1) / 2
            let dc = Double(column) - Double(columns - 1) / 2
            return 400.0 - 42.0 * (dr * dr + dc * dc).squareRoot()
        }
    }

    private func boundaries(_ field: Field2D, land: Int, sea: Int) -> (land: [Double], sea: [Double]) {
        let range = field.finiteRange!
        return (
            landBandBoundaries(minimum: range.minimum, maximum: range.maximum, count: land),
            depthBandBoundaries(minimum: range.minimum, maximum: range.maximum, count: sea)
        )
    }

    // MARK: - Where the split falls

    func testTheWaterlineIsABoundaryOnBothSides() {
        let (land, sea) = boundaries(island(), land: 5, sea: 4)
        XCTAssertEqual(land.first, 0, "land should start at the waterline")
        XCTAssertEqual(sea.last, 0, "the sea should end at the waterline")
    }

    func testLandBandsStayAboveTheWaterAndDepthBandsBelowIt() {
        let (land, sea) = boundaries(island(), land: 5, sea: 4)
        for value in land { XCTAssertGreaterThanOrEqual(value, 0) }
        for value in sea { XCTAssertLessThanOrEqual(value, 0) }
    }

    func testEachSideGetsTheCountItWasAskedFor() {
        let (land, sea) = boundaries(island(), land: 5, sea: 3)
        XCTAssertEqual(land.count, 6, "five bands need six boundaries")
        XCTAssertEqual(sea.count, 4)
    }

    /// Ground entirely above water has no sea to band, and must not invent one.
    func testGroundWithNoSeaProducesNoDepthBands() {
        let boundaries = depthBandBoundaries(minimum: 120, maximum: 3400, count: 6)
        XCTAssertTrue(boundaries.isEmpty)
    }

    /// And the reverse: an open-ocean frame has no land to band.
    func testSeaWithNoLandProducesNoLandBands() {
        let boundaries = landBandBoundaries(minimum: -4200, maximum: -180, count: 6)
        XCTAssertTrue(boundaries.isEmpty)
    }

    /// The depths a chart states, rather than whatever an even division lands
    /// on. Reading "0 to 4.3 m" where a chart says "0 to 5" is a number nobody
    /// asked for, and the shallow end is where the numbers matter.
    func testChartModeUsesTheDepthsAChartWouldState() {
        let boundaries = depthBandBoundaries(
            minimum: -60, maximum: 300, count: 6, mode: .chart
        )
        XCTAssertEqual(boundaries.last, 0)
        // Every stated depth is a round number a chart would print.
        for value in boundaries {
            let depth = -value
            XCTAssertEqual(depth, depth.rounded(), "\(depth) is not a stated depth")
        }
        XCTAssertTrue(boundaries.contains(-5), "5 m is the first depth that matters")
        XCTAssertTrue(boundaries.contains(-10))
    }

    /// Chart mode stops at the deepest water actually in the frame; a harbour
    /// sheet should not carry a 200 m band it has no ground for.
    func testChartModeDoesNotReachPastTheWaterInTheFrame() {
        let boundaries = depthBandBoundaries(minimum: -12, maximum: 40, count: 8, mode: .chart)
        XCTAssertGreaterThanOrEqual(boundaries.first ?? 0, -12)
    }

    // MARK: - What comes out

    func testTheBandsCoverTheSeaFloorAndNotTheLand() throws {
        let field = island()
        let geos = GEOSContext()
        let range = field.finiteRange!
        let bands = try elevationBands(
            field,
            boundaries: depthBandBoundaries(
                minimum: range.minimum, maximum: range.maximum, count: 3
            ),
            using: geos
        )
        XCTAssertFalse(bands.isEmpty, "an island in water should band its sea floor")
        for band in bands {
            XCTAssertLessThanOrEqual(band.upper, 0.001, "a depth band reached above the waterline")
        }
    }

    /// The two sets together still describe the whole field, with no gap at the
    /// waterline and no band counted twice.
    func testTogetherTheyCoverEverythingExactlyOnce() throws {
        let field = island()
        let range = field.finiteRange!
        let land = landBandBoundaries(minimum: range.minimum, maximum: range.maximum, count: 4)
        let sea = depthBandBoundaries(minimum: range.minimum, maximum: range.maximum, count: 4)
        XCTAssertEqual(try XCTUnwrap(sea.first), range.minimum, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(land.last), range.maximum, accuracy: 1e-9)
        XCTAssertEqual(sea.last, land.first, "a gap or an overlap at the waterline")
    }
}
