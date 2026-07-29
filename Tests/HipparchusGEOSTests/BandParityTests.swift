import XCTest
import HipparchusGeometry
@testable import HipparchusGEOS

/// Parity with the Python's Shapely-backed band builder.
///
/// This is the highest-risk part of the port: the algorithm is the same, but the
/// engine underneath is GEOS reached directly rather than through Shapely, and a
/// difference in how faces are polygonized or unioned would show up as a fill
/// that is subtly the wrong shape — the exact failure the whole
/// measure-containment approach exists to avoid.
///
/// Area, polygon count and hole count are compared rather than vertices. Those
/// three together pin the topology, which is what matters; vertex-level equality
/// would break on a GEOS point release for no real reason.
///
/// Regenerate with `Scripts/generate-band-parity-fixture.py`.
final class BandParityTests: XCTestCase {
    private var geos = GEOSContext()
    override func setUp() { geos = GEOSContext() }

    private struct RegionFacts: Decodable {
        let area: Double
        let polygons: Int
        let holes: Int
    }

    private struct BandFacts: Decodable {
        let lower: Double
        let upper: Double
        let area: Double
        let holes: Int
    }

    private struct Fixture: Decodable {
        let regions: [String: [String: RegionFacts]]
        let bands: [String: [BandFacts]]
    }

    private func fields() -> [String: Field2D] {
        ["cone": coneField(), "crater": craterField()]
    }

    func testRegionsMatchThePythonInAreaAndTopology() throws {
        let fixture = try loadFixture()
        let fields = self.fields()

        for (name, levels) in fixture.regions {
            let field = try XCTUnwrap(fields[name])
            for (levelText, expected) in levels {
                let level = try XCTUnwrap(Double(levelText))
                let region = try regionAtOrAbove(field, level: level, using: geos)
                let area = try geos.area(region)

                XCTAssertEqual(
                    area, expected.area, accuracy: max(1e-6, expected.area * 1e-9),
                    "\(name) at \(level) m: area"
                )
                XCTAssertEqual(region.polygons.count, expected.polygons, "\(name) at \(level) m: polygon count")
                XCTAssertEqual(
                    region.polygons.reduce(0) { $0 + $1.holes.count }, expected.holes,
                    "\(name) at \(level) m: hole count"
                )
            }
        }
    }

    func testBandsMatchThePythonBandForBand() throws {
        let fixture = try loadFixture()
        let fields = self.fields()

        for (name, expectedBands) in fixture.bands {
            let field = try XCTUnwrap(fields[name])
            let bands = try elevationBands(
                field,
                boundaries: bandBoundaries(minimum: 0.0, maximum: 100.0, count: 8),
                using: geos
            )

            XCTAssertEqual(bands.count, expectedBands.count, "\(name): band count")
            guard bands.count == expectedBands.count else { continue }

            for (index, (band, expected)) in zip(bands, expectedBands).enumerated() {
                XCTAssertEqual(band.lower, expected.lower, accuracy: 1e-9, "\(name) band \(index): lower")
                XCTAssertEqual(band.upper, expected.upper, accuracy: 1e-9, "\(name) band \(index): upper")
                XCTAssertEqual(
                    try geos.area(band.geometry), expected.area,
                    accuracy: max(1e-6, expected.area * 1e-9),
                    "\(name) band \(index) (\(expected.lower)-\(expected.upper) m): area"
                )
                XCTAssertEqual(
                    band.geometry.polygons.reduce(0) { $0 + $1.holes.count }, expected.holes,
                    "\(name) band \(index): hole count — the crater's hollow must stay hollow"
                )
            }
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "band-parity", withExtension: "json"),
            "band-parity.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }
}
