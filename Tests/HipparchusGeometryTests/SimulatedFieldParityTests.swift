import XCTest
@testable import HipparchusGeometry

/// The generated landscape, compared against the Python's rather than against my
/// reading of it.
///
/// The unit tests say the Swift field is plausible terrain. This says it is the
/// *same* terrain — same hash, same octave ladder, same metres at the same
/// coordinates — which is what catches a port that produces a perfectly good
/// landscape that is not the one a seed names.
///
/// Every layer is checked separately, so a failure points at the step that moved
/// rather than at the end of a long chain. Regenerate with
/// `Scripts/generate-simulated-field-parity-fixture.py`.
final class SimulatedFieldParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Hash: Decodable {
            let ix: Int64
            let iy: Int64
            let seed: Int
            let value: Double
        }
        struct Noise: Decodable {
            let x: Double
            let y: Double
            let seed: Int
            let value: Double
        }
        struct FBM: Decodable {
            let x: Double
            let y: Double
            let octaves: Int
            let salt: Int
            let value: Double
        }
        struct Window: Decodable {
            let bounds: [Double]
            let spanDeg: Double
            let wavelengthDeg: Double
            let reliefMetres: Double
            let octaves: Int
            let minMetres: Double
            let maxMetres: Double
            let stride: Int
            let samples: [[Double]]

            enum CodingKeys: String, CodingKey {
                case bounds
                case spanDeg = "span_deg"
                case wavelengthDeg = "wavelength_deg"
                case reliefMetres = "relief_metres"
                case octaves
                case minMetres = "min_metres"
                case maxMetres = "max_metres"
                case stride
                case samples
            }
        }

        let hash: [Hash]
        let noise: [Noise]
        let fbm: [FBM]
        let windows: [String: Window]
    }

    private func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/simulated-field-parity.json")
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    /// The integer lattice hash, which everything else rests on. A single wrong
    /// shift changes the whole world, and nothing further down would say why.
    ///
    /// Exact equality, not a tolerance: this is integer arithmetic on both sides,
    /// and "nearly the same hash" is not a thing.
    func testTheLatticeHashMatchesBitForBit() throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.hash.isEmpty)

        for sample in fixture.hash {
            XCTAssertEqual(
                SimulatedField.hashUnit(sample.ix, sample.iy, sample.seed),
                sample.value,
                "hash(\(sample.ix), \(sample.iy), seed \(sample.seed))"
            )
        }
    }

    /// A negative coordinate becomes a very large `UInt64`, and getting that
    /// conversion wrong is silent — the field stays smooth, it is just a different
    /// world south and west of the origin.
    func testNegativeLatticePointsHashTheSameWay() throws {
        let negatives = try fixture().hash.filter { $0.ix < 0 || $0.iy < 0 }
        XCTAssertFalse(negatives.isEmpty, "the fixture must cover negative coordinates")

        for sample in negatives {
            XCTAssertEqual(
                SimulatedField.hashUnit(sample.ix, sample.iy, sample.seed), sample.value
            )
        }
    }

    func testValueNoiseMatches() throws {
        for sample in try fixture().noise {
            XCTAssertEqual(
                SimulatedField.valueNoise(x: sample.x, y: sample.y, seed: sample.seed),
                sample.value,
                accuracy: 1e-15,
                "noise(\(sample.x), \(sample.y), seed \(sample.seed))"
            )
        }
    }

    /// Including the normaliser, which runs over the *whole* octave ladder rather
    /// than the octaves summed. Normalising by the octaves used would rescale the
    /// field whenever the window changed how many are resolvable.
    func testTheFractalSumMatches() throws {
        let settings = TerrainFieldSettings()
        for sample in try fixture().fbm {
            XCTAssertEqual(
                SimulatedField.fbm(
                    x: sample.x, y: sample.y,
                    settings: settings, octaves: sample.octaves, salt: sample.salt
                ),
                sample.value,
                accuracy: 1e-15,
                "fbm(\(sample.x), \(sample.y), octaves \(sample.octaves), salt \(sample.salt))"
            )
        }
    }

    /// The window-to-landform ladder. Half-way rungs are the interesting case:
    /// Python rounds them to even, and Swift's default rounds away from zero.
    func testTheLandformLadderMatches() throws {
        let settings = TerrainFieldSettings()
        for (name, window) in try fixture().windows {
            let bounds = BoundingBox(
                minLon: window.bounds[0], minLat: window.bounds[1],
                maxLon: window.bounds[2], maxLat: window.bounds[3]
            )
            XCTAssertEqual(
                SimulatedField.windowSpanDegrees(bounds), window.spanDeg, accuracy: 1e-12, name
            )
            XCTAssertEqual(
                SimulatedField.wavelengthDegrees(bounds, settings: settings),
                window.wavelengthDeg, accuracy: 1e-12, name
            )
            XCTAssertEqual(
                SimulatedField.reliefMetres(bounds, settings: settings),
                window.reliefMetres, accuracy: 1e-9, name
            )
            XCTAssertEqual(
                SimulatedField.resolvableOctaves(bounds, settings: settings),
                window.octaves, name
            )
        }
    }

    /// The whole chain: the same metres at the same coordinates, for real windows
    /// spanning two orders of magnitude.
    func testTheElevationGridMatches() throws {
        let settings = TerrainFieldSettings()
        for (name, window) in try fixture().windows {
            let bounds = BoundingBox(
                minLon: window.bounds[0], minLat: window.bounds[1],
                maxLon: window.bounds[2], maxLat: window.bounds[3]
            )
            let grid = SimulatedField.elevationGrid(bounds, settings: settings)

            let finite = grid.values.filter(\.isFinite)
            XCTAssertEqual(finite.min() ?? .nan, window.minMetres, accuracy: 1e-9, "\(name) floor")
            XCTAssertEqual(finite.max() ?? .nan, window.maxMetres, accuracy: 1e-9, "\(name) ceiling")

            for (rowIndex, row) in window.samples.enumerated() {
                for (columnIndex, expected) in row.enumerated() {
                    let value = grid.clamped(
                        row: rowIndex * window.stride, column: columnIndex * window.stride
                    )
                    XCTAssertEqual(
                        value, expected, accuracy: 1e-9,
                        "\(name) at row \(rowIndex * window.stride), column \(columnIndex * window.stride)"
                    )
                }
            }
        }
    }
}
