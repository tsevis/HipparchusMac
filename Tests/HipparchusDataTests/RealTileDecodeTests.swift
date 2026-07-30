import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Decode a real production tile, and hold it to numbers produced independently.
///
/// A round-trip through my own encoder proves the two halves agree with each
/// other, which they would even if both were wrong. This is the check that
/// matters: `Fixtures/athens-11-1159-790.png` is the actual tile AWS serves for
/// zoom 11, x 1159, y 790 — the Athens tile the Python's own test names — and the
/// expected values were produced by decoding it with **skia** (what the Python
/// uses) and with **PIL** independently. Those two agree exactly, and Core
/// Graphics has to agree with them.
///
/// It also happens to be the only place in the suite where a real tile's PNG
/// encoding is exercised: 8-bit RGB with no alpha channel at all, which is not
/// what the synthesised tiles produce.
final class RealTileDecodeTests: XCTestCase {

    private struct Expected: Decodable {
        let shape: [Int]
        let min: Double
        let max: Double
        let samples: [String: Double]
    }

    func testARealTileDecodesToTheSameMetresAsSkiaAndPIL() throws {
        let tileURL = try XCTUnwrap(
            Bundle.module.url(forResource: "athens-11-1159-790", withExtension: "png"),
            "the real tile fixture is missing"
        )
        let expectedURL = try XCTUnwrap(
            Bundle.module.url(forResource: "athens-tile-expected", withExtension: "json")
        )
        let expected = try JSONDecoder().decode(Expected.self, from: try Data(contentsOf: expectedURL))

        let field = try decodeTerrarium(try Data(contentsOf: tileURL))

        XCTAssertEqual(field.rows, expected.shape[0])
        XCTAssertEqual(field.columns, expected.shape[1])

        let range = try XCTUnwrap(field.finiteRange)
        XCTAssertEqual(range.minimum, expected.min, accuracy: 1e-9, "tile minimum")
        XCTAssertEqual(range.maximum, expected.max, accuracy: 1e-9, "tile maximum")

        for (key, value) in expected.samples {
            let parts = key.split(separator: ",").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(
                field[parts[0], parts[1]], value, accuracy: 1e-9,
                "sample at row \(parts[0]), column \(parts[1])"
            )
        }
    }

    /// The tile is real Athens ground, so it can be sanity-checked against the
    /// world rather than only against another decoder.
    func testTheRealTileLooksLikeAthens() throws {
        let tileURL = try XCTUnwrap(Bundle.module.url(forResource: "athens-11-1159-790", withExtension: "png"))
        let field = try decodeTerrarium(try Data(contentsOf: tileURL))
        let range = try XCTUnwrap(field.finiteRange)

        // Sea level at the coast, and Hymettus reaching about 1,000 m.
        XCTAssertEqual(range.minimum, 0.0, accuracy: 1.0, "the tile includes the coastline")
        XCTAssertGreaterThan(range.maximum, 900.0)
        XCTAssertLessThan(range.maximum, 1100.0, "Hymettus is 1,026 m; nothing here is higher")

        // A surface model over a city: every sample is a real number, no holes.
        XCTAssertEqual(field.values.count(where: { $0.isFinite }), 256 * 256)
    }
}
