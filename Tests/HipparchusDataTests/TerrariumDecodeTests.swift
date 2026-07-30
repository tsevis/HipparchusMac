import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Ported from `TerrariumDecodeTests` in `tests/test_terrain_tiles.py`, plus the
/// cases Core Graphics makes necessary that skia did not.
///
/// The Python builds its test tiles with skia; these build them with
/// `CGImageDestination`, so the whole suite still runs offline with nothing on
/// disk.
final class TerrariumDecodeTests: XCTestCase {

    func testKnownElevationsSurviveARoundTrip() throws {
        let original = Field2D(rows: 2, columns: 2, values: [0.0, 100.0, -50.0, 8848.0])
        let decoded = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(original)))
        XCTAssertEqual(decoded.rows, 2)
        XCTAssertEqual(decoded.columns, 2)
        for index in original.values.indices {
            XCTAssertEqual(decoded.values[index], original.values[index], accuracy: 0.01)
        }
    }

    func testSeaLevelAndBelowDecodeCorrectly() throws {
        let decoded = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(
            Field2D(rows: 1, columns: 2, values: [0.0, -430.0])
        )))
        XCTAssertEqual(decoded[0, 0], 0.0, accuracy: 0.01)
        XCTAssertEqual(decoded[0, 1], -430.0, accuracy: 0.01)
    }

    func testANonImageResponseIsReported() {
        // What the tile bucket actually returns for a missing tile.
        let xml = Data("<Error><Code>NoSuchKey</Code></Error>".utf8)
        XCTAssertThrowsError(try decodeTerrarium(xml)) { error in
            guard case TerrainTileError.notAnImage = error else {
                return XCTFail("expected .notAnImage, got \(error)")
            }
        }
    }

    func testEmptyDataIsReportedRatherThanCrashing() {
        XCTAssertThrowsError(try decodeTerrarium(Data()))
    }

    /// The decode has to be byte-exact, and this is the test that says so.
    ///
    /// Every channel value from 0 to 255 is put through the encoder and read back.
    /// A gamma curve, an sRGB-to-linear matrix or a premultiply would all shift
    /// mid-range values while leaving 0 and 255 alone, so checking the endpoints
    /// would miss it. One unit of red is 256 m of elevation.
    func testEveryChannelValueSurvivesUnchanged() throws {
        // Red drives the coarse elevation: 256 m per unit.
        let redRamp = Field2D(rows: 1, columns: 256) { _, column in
            Double(column) * 256.0 - 32768.0
        }
        let decodedRed = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(redRamp)))
        for column in 0..<256 {
            XCTAssertEqual(
                decodedRed[0, column], redRamp[0, column], accuracy: 1e-9,
                "red channel \(column) shifted — that is \(256) m of elevation per unit"
            )
        }

        // Green is 1 m per unit, blue is 1/256 m per unit.
        let fineRamp = Field2D(rows: 1, columns: 256) { _, column in
            Double(column) + Double(column) / 256.0
        }
        let decodedFine = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(fineRamp)))
        for column in 0..<256 {
            XCTAssertEqual(decodedFine[0, column], fineRamp[0, column], accuracy: 1e-9, "fine channels at \(column)")
        }
    }

    func testTheFullEncodableRangeRoundTrips() throws {
        // Terrarium spans -32768 m to +32767.996 m. The extremes of the real
        // mosaic are about -11,000 m (Challenger Deep) and 8,849 m (Everest).
        let values: [Double] = [-32768.0, -11_000.0, -1310.0, -79.0, 0.0, 284.0, 1091.0, 8848.0, 30_000.0]
        let field = Field2D(rows: 1, columns: values.count, values: ContiguousArray(values))
        let decoded = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(field)))
        for (index, value) in values.enumerated() {
            XCTAssertEqual(decoded[0, index], value, accuracy: 0.01, "\(value) m")
        }
    }

    func testAnOpaqueTileIsNotPremultiplied() throws {
        // A premultiplying context would scale every channel by alpha/255. The
        // encoder writes alpha 255 and the decoder ignores alpha entirely; this
        // pins that neither changes.
        let field = Field2D(rows: 4, columns: 4) { row, column in
            Double(row * 4 + column) * 137.0 - 500.0
        }
        let decoded = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(field)))
        for index in field.values.indices {
            XCTAssertEqual(decoded.values[index], field.values[index], accuracy: 0.01)
        }
    }

    func testRowOrderIsPreservedTopToBottom() throws {
        // Core Graphics has a bottom-left origin and the tile scheme has a
        // top-left one. A flipped decode puts every contour upside down, and a
        // symmetric test field would not notice.
        let field = Field2D(rows: 3, columns: 2, values: [
            1000.0, 1000.0,
            500.0, 500.0,
            0.0, 0.0,
        ])
        let decoded = try decodeTerrarium(try XCTUnwrap(encodeTerrariumPNG(field)))
        XCTAssertEqual(decoded[0, 0], 1000.0, accuracy: 0.01, "row 0 must stay the top row")
        XCTAssertEqual(decoded[2, 0], 0.0, accuracy: 0.01, "the last row must stay the bottom row")
    }
}
