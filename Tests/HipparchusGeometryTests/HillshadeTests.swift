import Foundation
import XCTest
@testable import HipparchusGeometry

/// What the hillshade has to be true of, beyond matching a formula.
///
/// `HillshadeParityTests` pins the arithmetic against the published algorithm.
/// This pins the things a reader would notice on the page: that a slope facing
/// the light is brighter than one turned away, that the relief does not invert,
/// that the same mountain shades the same whatever zoom the grid came from, and
/// that a missing tile stays missing.
final class HillshadeTests: XCTestCase {

    /// Ground tilted so it falls towards `bearing` (degrees clockwise from
    /// north) — the direction the slope faces, and so the direction it is lit
    /// from.
    private func slope(facing bearing: Double, rise: Double = 100.0) -> Field2D {
        let radians = bearing * .pi / 180.0
        // Row grows southward and column eastward, so a face towards the north
        // has to climb as the row grows.
        let perColumn = -rise * sin(radians)
        let perRow = rise * cos(radians)
        return Field2D(rows: 9, columns: 9) { row, column in
            1000.0 + perColumn * Double(column) + perRow * Double(row)
        }
    }

    private func centreValue(_ field: Field2D) -> Double { field[4, 4] }

    // MARK: -

    func testFlatGroundTakesTheSunsAltitudeWhateverElseChanges() {
        let flat = Field2D(rows: 6, columns: 7, repeating: 300.0)
        for altitude in [0.0, 12.0, 45.0, 78.0, 90.0] {
            for azimuth in [0.0, 90.0, 217.5, 315.0] {
                for cell in [1.0, 30.0, 500.0] {
                    let shaded = hillshade(
                        flat,
                        sun: SunPosition(azimuthDegrees: azimuth, altitudeDegrees: altitude),
                        cellSizeMetres: cell,
                        exaggeration: 2.0
                    )
                    let expected = sin(altitude * .pi / 180.0)
                    for value in shaded.values {
                        XCTAssertEqual(
                            value, expected, accuracy: 1e-12,
                            "flat ground under az \(azimuth) alt \(altitude): tone should be sin(altitude)"
                        )
                    }
                }
            }
        }
    }

    /// The one that matters: light a north-west sun onto ground facing every
    /// direction in turn, and the brightest must be the slope facing north-west.
    ///
    /// Get this wrong by a sign and the map still renders, still looks like
    /// relief, and reads inside out.
    func testTheBrightestSlopeIsTheOneFacingTheSun() throws {
        let sun = SunPosition(azimuthDegrees: 315.0, altitudeDegrees: 45.0)
        var tones: [(bearing: Double, lit: Double)] = []
        for bearing in stride(from: 0.0, to: 360.0, by: 15.0) {
            // Gentle ground on purpose. A steep slope pushes every face turned
            // away from the sun hard against the shadow clamp, and then
            // "darkest" is a tie between a dozen bearings rather than a fact
            // about the light.
            let shaded = hillshade(slope(facing: bearing, rise: 5.0), sun: sun, cellSizeMetres: 30.0)
            tones.append((bearing, centreValue(shaded)))
        }
        XCTAssertTrue(tones.allSatisfy { $0.lit > 0.0 }, "the sweep clamped, so the ordering below means nothing")

        let brightest = try XCTUnwrap(tones.max { $0.lit < $1.lit })
        XCTAssertEqual(brightest.bearing, 315.0, "the sun is in the north-west; that slope should be brightest")

        let darkest = try XCTUnwrap(tones.min { $0.lit < $1.lit })
        XCTAssertEqual(darkest.bearing, 135.0, "the slope turned away from the sun should be darkest")
    }

    func testASlopeTurnedAwayFromTheSunIsInShadow() {
        let sun = SunPosition(azimuthDegrees: 315.0, altitudeDegrees: 20.0)
        // Steep enough that the far face falls below the horizon entirely.
        let away = hillshade(slope(facing: 135.0, rise: 400.0), sun: sun, cellSizeMetres: 30.0)
        XCTAssertEqual(centreValue(away), 0.0, accuracy: 1e-12, "a face past the terminator is shadow, not negative light")

        let towards = hillshade(slope(facing: 315.0, rise: 400.0), sun: sun, cellSizeMetres: 30.0)
        XCTAssertGreaterThan(centreValue(towards), 0.9, "a face square to a low sun is close to fully lit")
    }

    /// The same mountain sampled at a coarser grid is the same mountain. Without
    /// a real cell size the gradient is metres-per-pixel, and the relief would
    /// harden every time the zoom went up.
    func testGroundResolutionKeepsTheSameSlopeAtTheSameTone() {
        let sun = SunPosition()
        // Twice the cell size, twice the rise per cell: an identical gradient on
        // the ground.
        let fine = hillshade(slope(facing: 315.0, rise: 50.0), sun: sun, cellSizeMetres: 30.0)
        let coarse = hillshade(slope(facing: 315.0, rise: 100.0), sun: sun, cellSizeMetres: 60.0)
        XCTAssertEqual(centreValue(fine), centreValue(coarse), accuracy: 1e-12)
    }

    func testExaggerationDeepensTheShadowAndSharpensTheLight() {
        let sun = SunPosition()
        let gentle = slope(facing: 135.0, rise: 8.0)
        let plain = centreValue(hillshade(gentle, sun: sun, cellSizeMetres: 30.0))
        let stretched = centreValue(hillshade(gentle, sun: sun, cellSizeMetres: 30.0, exaggeration: 6.0))
        XCTAssertLessThan(stretched, plain, "a shadowed face should darken as the relief is stretched")

        // Nothing to exaggerate means nothing changes: exaggeration is a
        // multiplier on the gradient, and flat ground has none.
        let flat = Field2D(rows: 5, columns: 5, repeating: 10.0)
        XCTAssertEqual(
            centreValue(hillshade(flat, sun: sun, cellSizeMetres: 30.0, exaggeration: 9.0)),
            centreValue(hillshade(flat, sun: sun, cellSizeMetres: 30.0)),
            accuracy: 1e-12
        )
    }

    func testEveryToneLiesBetweenShadowAndFullLight() {
        let rough = Field2D(rows: 24, columns: 31) { row, column in
            400.0 * sin(Double(row) * 0.9) * cos(Double(column) * 0.7)
                + 60.0 * sin(Double(column) * 3.1)
        }
        for altitude in [5.0, 45.0, 85.0] {
            let shaded = hillshade(
                rough,
                sun: SunPosition(altitudeDegrees: altitude),
                cellSizeMetres: 10.0,
                exaggeration: 4.0
            )
            for value in shaded.values {
                XCTAssertTrue(value >= 0.0 && value <= 1.0, "tone \(value) is outside 0...1")
            }
        }
    }

    func testAHoleStaysAHoleAndDoesNotCliffAtItsRim() {
        var values = ContiguousArray<Double>(repeating: 500.0, count: 7 * 7)
        values[3 * 7 + 3] = .nan
        let holed = Field2D(rows: 7, columns: 7, values: values)
        let shaded = hillshade(holed, cellSizeMetres: 30.0)

        XCTAssertTrue(shaded[3, 3].isNaN, "a missing sample must not be shaded")

        // The ground around it is flat, so the rim must read as flat too rather
        // than picking up an edge from the gap.
        let expected = sin(defaultSunAltitude * .pi / 180.0)
        for (row, column) in [(2, 3), (3, 2), (3, 4), (4, 3), (2, 2)] {
            XCTAssertEqual(
                shaded[row, column], expected, accuracy: 1e-12,
                "the rim of a hole picked up a slope that is not in the ground"
            )
        }
    }

    func testAnUnusableCellSizeShadesNothingRatherThanFlatteningEverything() {
        let field = Field2D(rows: 4, columns: 4) { row, column in Double(row * 4 + column) }
        for cell in [0.0, -30.0, Double.nan, Double.infinity] {
            let shaded = hillshade(field, cellSizeMetres: cell)
            XCTAssertEqual(shaded.rows, field.rows)
            XCTAssertEqual(shaded.columns, field.columns)
            XCTAssertTrue(
                shaded.values.allSatisfy(\.isNaN),
                "cell size \(cell) should refuse rather than shade the sheet one flat tone"
            )
        }
    }

    func testAnEmptyFieldComesBackEmpty() {
        XCTAssertTrue(hillshade(.empty, cellSizeMetres: 30.0).isEmpty)
    }

    // MARK: - Ground resolution

    func testGroundResolutionShrinksWithLatitudeAndZoom() {
        // The familiar figure: ~156.5 km per pixel at zoom 0 on the equator,
        // halving with every zoom level.
        let equator = WebMercator.groundResolution(latitude: 0, zoom: 0)
        XCTAssertEqual(equator, 156_543.03, accuracy: 0.01)
        XCTAssertEqual(WebMercator.groundResolution(latitude: 0, zoom: 1), equator / 2.0, accuracy: 1e-9)

        // cos(60°) is a half, exactly.
        XCTAssertEqual(
            WebMercator.groundResolution(latitude: 60.0, zoom: 12),
            WebMercator.groundResolution(latitude: 0, zoom: 12) / 2.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            WebMercator.groundResolution(latitude: -47.5, zoom: 9),
            WebMercator.groundResolution(latitude: 47.5, zoom: 9),
            accuracy: 1e-12
        )
    }
}
