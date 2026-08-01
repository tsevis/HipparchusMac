import XCTest
@testable import HipparchusGeometry

/// The hillshade, checked against the published algorithm.
///
/// Every other parity test here pins the port against the Python it follows.
/// This one cannot: the Python names `terrain_hillshade` and never computes one,
/// so there is nothing to be in parity *with*. What is pinned instead is the
/// algorithm itself.
///
/// `Hillshade.swift` writes the shade as the dot product it really is — fit a
/// plane to each 3×3 window, take its normal, light it. The fixture computes the
/// same quantity the way ESRI and GDAL state it, through slope, aspect, zenith
/// and a cosine. Two different pieces of algebra for one number: if they agree
/// to 1e-12 over tilted, curved, noisy and holed ground then the derivation is
/// right and neither side has an index or a sign slipped — which is the failure
/// that would otherwise ship looking merely a bit odd, and stay.
///
/// Regenerate with `Scripts/generate-hillshade-parity-fixture.py`.
final class HillshadeParityTests: XCTestCase {

    private struct Case: Decodable {
        let azimuth: Double
        let altitude: Double
        let cellMetres: Double
        let exaggeration: Double
        /// Null where the source grid had no elevation.
        let shade: [Double?]

        enum CodingKeys: String, CodingKey {
            case azimuth, altitude, exaggeration, shade
            case cellMetres = "cell_metres"
        }
    }

    private struct Subject: Decodable {
        let rows: Int
        let columns: Int
        let cases: [Case]
    }

    // MARK: - The same grids the reference script builds

    private static let rows = 11
    private static let columns = 13

    private static func field(_ sample: (Double, Double) -> Double) -> Field2D {
        Field2D(rows: rows, columns: columns) { row, column in
            sample(Double(row), Double(column))
        }
    }

    private static let centreRow = Double(rows - 1) / 2.0
    private static let centreColumn = Double(columns - 1) / 2.0

    private static func ridgeHeight(_ row: Double, _ column: Double) -> Double {
        let across = (column - centreColumn) / 3.0
        return 600.0 * exp(-(across * across)) + 25.0 * sin(row * 1.7) * cos(column * 2.3)
    }

    private static func subjects() -> [String: Field2D] {
        [
            "plane": field { row, column in 12.0 * column + 5.0 * row },
            "cone": field { row, column in
                900.0 - 70.0 * (
                    (row - centreRow) * (row - centreRow) + (column - centreColumn) * (column - centreColumn)
                ).squareRoot()
            },
            "saddle": field { row, column in
                40.0 * (
                    (column - centreColumn) * (column - centreColumn)
                        - (row - centreRow) * (row - centreRow)
                )
            },
            "ridge": field(ridgeHeight),
            "flat": field { _, _ in 250.0 },
            "holed": field { row, column in
                if row == 0, column == 0 { return .nan }
                if (3.0..<6.0).contains(row), (4.0..<8.0).contains(column) { return .nan }
                return ridgeHeight(row, column)
            },
        ]
    }

    // MARK: -

    func testShadeMatchesThePublishedSlopeAspectFormulation() throws {
        let fixture = try loadFixture()
        let subjects = Self.subjects()
        XCTAssertEqual(Set(fixture.keys), Set(subjects.keys), "fixture and test build different subjects")

        for (name, reference) in fixture {
            let field = try XCTUnwrap(subjects[name], "no Swift subject named \(name)")
            XCTAssertEqual(field.rows, reference.rows, "\(name): rows")
            XCTAssertEqual(field.columns, reference.columns, "\(name): columns")

            for entry in reference.cases {
                let label = "\(name) az \(entry.azimuth) alt \(entry.altitude) "
                    + "cell \(entry.cellMetres) ×\(entry.exaggeration)"
                let shaded = hillshade(
                    field,
                    sun: SunPosition(azimuthDegrees: entry.azimuth, altitudeDegrees: entry.altitude),
                    cellSizeMetres: entry.cellMetres,
                    exaggeration: entry.exaggeration
                )
                XCTAssertEqual(shaded.count, entry.shade.count, "\(label): cell count")
                guard shaded.count == entry.shade.count else { continue }

                for (index, expected) in entry.shade.enumerated() {
                    guard let expected else {
                        XCTAssertTrue(
                            shaded.values[index].isNaN,
                            "\(label) cell \(index): a hole was shaded, so ground was invented"
                        )
                        continue
                    }
                    XCTAssertEqual(shaded.values[index], expected, accuracy: 1e-12, "\(label) cell \(index)")
                }
            }
        }
    }

    private func loadFixture() throws -> [String: Subject] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "hillshade-parity", withExtension: "json"),
            "hillshade-parity.json is missing from the test bundle"
        )
        return try JSONDecoder().decode([String: Subject].self, from: try Data(contentsOf: url))
    }
}

import Foundation
