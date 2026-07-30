import XCTest
@testable import HipparchusGeometry

/// Parity with the Python's illumination.
///
/// Illumination decides how thick every contour is drawn, so a difference here is
/// a difference in what the page looks like — and unlike a geometry bug it would
/// not show up as a wrong shape, only as wrong emphasis, which is exactly the kind
/// of thing that survives review.
///
/// The subject is a lopsided ring with a shoulder, so the weight changes several
/// times around it and the run boundaries are non-trivial. All four profiles the
/// shipped presets use are covered.
///
/// Regenerate with `Scripts/generate-illumination-parity-fixture.py`.
final class IlluminationParityTests: XCTestCase {

    private struct Run: Decodable {
        let weight: Double
        let vertices: Int
        let coordinates: [[Double]]
    }

    /// The same ring the reference script builds.
    private func subject() -> LineString {
        var points: [Coordinate] = []
        for step in 0...72 {
            let angle = 2.0 * Double.pi * Double(step) / 72.0
            let wobble = 1.0 + 0.16 * sin(angle * 2.0 + 0.6) + 0.07 * sin(angle * 3.0)
            let radius = 10.0 * wobble
            points.append(Coordinate(x: radius * cos(angle) * 1.18, y: radius * sin(angle) * 0.86))
        }
        return LineString(points)
    }

    func testRunsMatchThePythonInWeightBoundaryAndVertices() throws {
        let fixture = try loadFixture()
        let line = Geometry.lineString(subject())

        for (key, reference) in fixture {
            let parts = key.split(separator: "/").compactMap { Double($0) }
            XCTAssertEqual(parts.count, 4, "unreadable fixture key \(key)")
            let profile = IlluminationProfile(
                azimuthDegrees: parts[0],
                bands: Int(parts[1]),
                litScale: parts[2],
                shadowScale: parts[3]
            )

            let runs = illuminate([line], profile: profile)
            XCTAssertEqual(runs.count, reference.count, "run count differs for \(key)")
            guard runs.count == reference.count else { continue }

            for (index, (run, expected)) in zip(runs, reference).enumerated() {
                XCTAssertEqual(run.weight, expected.weight, accuracy: 1e-12, "\(key) run \(index): weight")
                XCTAssertEqual(
                    run.line.coordinates.count, expected.vertices,
                    "\(key) run \(index): vertex count — the run was cut in the wrong place"
                )
                guard run.line.coordinates.count == expected.vertices else { continue }
                for (vertex, (point, reference)) in zip(run.line.coordinates, expected.coordinates).enumerated() {
                    XCTAssertEqual(point.x, reference[0], accuracy: 1e-9, "\(key) run \(index) vertex \(vertex): x")
                    XCTAssertEqual(point.y, reference[1], accuracy: 1e-9, "\(key) run \(index) vertex \(vertex): y")
                }
            }
        }
    }

    /// Runs must tile the line: consecutive runs share their boundary vertex, so
    /// their lengths add up to the whole and no stretch is drawn twice or missed.
    func testRunsTileTheLineWithoutGapOrOverlap() throws {
        let line = subject()
        for bands in [1, 3, 5, 6, 12] {
            let profile = IlluminationProfile(bands: bands)
            let runs = illuminate([.lineString(line)], profile: profile)
            let total = runs.reduce(0.0) { $0 + $1.line.length }
            XCTAssertEqual(total, line.length, accuracy: 1e-9, "bands = \(bands)")

            for index in 0..<(runs.count - 1) {
                XCTAssertEqual(
                    runs[index].line.coordinates.last, runs[index + 1].line.coordinates.first,
                    "runs \(index) and \(index + 1) do not share a boundary vertex"
                )
            }
        }
    }

    private func loadFixture() throws -> [String: [Run]] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "illumination-parity", withExtension: "json"),
            "illumination-parity.json is missing from the test bundle"
        )
        return try JSONDecoder().decode([String: [Run]].self, from: try Data(contentsOf: url))
    }
}

import Foundation
