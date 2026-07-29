import XCTest
@testable import HipparchusGeometry

/// Parity with the Python this is ported from.
///
/// The ported unit tests say the tracer is *correct*. This says it is the *same*:
/// the reference JSON was produced by running `contour_polylines` from
/// `/Users/tsevis/AI/ClaudeCode/Hipparchus` over an awkward field — two ridges, a
/// saddle, a NaN hole, and a sample sitting exactly on a level — and it pins line
/// count, line order, vertex order and vertex values.
///
/// It is the check that catches a port that passes every assertion while drawing
/// something subtly different, which is the failure mode that matters when the
/// output is a map someone prints.
///
/// Regenerate with `Scripts/generate-contour-parity-fixture.py` if the Python's
/// tracer ever changes; a diff here otherwise means this port drifted.
final class ContourParityTests: XCTestCase {

    /// The same field the reference script builds.
    private func referenceField() -> Field2D {
        let n = 37
        let axis = linspace(-3.0, 3.0, n)
        var field = Field2D(rows: n, columns: n) { row, column in
            let x = axis[column]
            let y = axis[row]
            return Foundation.sin(x * 1.7) * Foundation.cos(y * 1.3) + 0.25 * x
        }
        var values = field.values
        values[5 * n + 7] = .nan
        values[10 * n + 10] = 0.5
        field = Field2D(rows: n, columns: n, values: values)
        return field
    }

    func testTracerMatchesThePythonLineForLineAndVertexForVertex() throws {
        let expected = try loadFixture()
        let field = referenceField()

        for level in [-0.5, 0.0, 0.25, 0.5, 0.9] {
            let key = String(level)
            let reference = try XCTUnwrap(expected[key], "fixture has no level \(key)")
            let traced = contourPolylines(field, level: level)

            XCTAssertEqual(traced.count, reference.count, "line count differs at level \(level)")
            guard traced.count == reference.count else { continue }

            for (lineIndex, (line, referenceLine)) in zip(traced, reference).enumerated() {
                XCTAssertEqual(
                    line.count, referenceLine.count,
                    "level \(level) line \(lineIndex): vertex count \(line.count) vs \(referenceLine.count)"
                )
                guard line.count == referenceLine.count else { continue }
                for (vertexIndex, (point, referencePoint)) in zip(line, referenceLine).enumerated() {
                    XCTAssertEqual(
                        point.row, referencePoint[0], accuracy: 1e-9,
                        "level \(level) line \(lineIndex) vertex \(vertexIndex): row"
                    )
                    XCTAssertEqual(
                        point.column, referencePoint[1], accuracy: 1e-9,
                        "level \(level) line \(lineIndex) vertex \(vertexIndex): column"
                    )
                }
            }
        }
    }

    private func loadFixture() throws -> [String: [[[Double]]]] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "contour-parity", withExtension: "json"),
            "contour-parity.json is missing from the test bundle"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: [[[Double]]]].self, from: data)
    }
}

import Foundation
