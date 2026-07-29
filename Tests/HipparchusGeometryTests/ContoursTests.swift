import XCTest
@testable import HipparchusGeometry

/// Ported from `tests/test_contours.py`. The Python builds its grids with
/// `meshgrid`; `Field2D(rows:columns:_:)` says the same thing directly.
final class ContourLevelTests: XCTestCase {

    func testLevelsLandOnIntervalMultiples() {
        let levels = contourLevels(minimum: 3.0, maximum: 47.0, interval: 10.0, indexEvery: 5)
        XCTAssertEqual(levels.allLevels, [10.0, 20.0, 30.0, 40.0])
    }

    func testIndexLevelsAreEveryNthInterval() {
        let levels = contourLevels(minimum: 0.0, maximum: 260.0, interval: 25.0, indexEvery: 4)
        // index spacing is interval * indexEvery = 100
        XCTAssertEqual(levels.index, [100.0, 200.0])
        XCTAssertFalse(levels.minor.contains(100.0))
        XCTAssertEqual(levels.minor.count + levels.index.count, levels.allLevels.count)
    }

    func testMinorAndIndexAreDisjointAndSorted() {
        let levels = contourLevels(minimum: -120.0, maximum: 340.0, interval: 20.0, indexEvery: 5)
        XCTAssertEqual(levels.allLevels, levels.allLevels.sorted())
        XCTAssertTrue(Set(levels.minor).intersection(Set(levels.index)).isEmpty)
    }

    func testNoIndexLinesWhenAccentingIsSwitchedOff() {
        // A dense sheet reads depth from line density; an accent interrupts it.
        let levels = contourLevels(minimum: 0.0, maximum: 100.0, interval: 10.0, indexEvery: 0)
        XCTAssertEqual(levels.index, [])
        XCTAssertEqual(levels.minor.count, 9)
        XCTAssertEqual(levels.allLevels.count, 9)
    }

    func testNegativeAccentSpacingIsTreatedAsOff() {
        XCTAssertEqual(contourLevels(minimum: 0.0, maximum: 100.0, interval: 10.0, indexEvery: -3).index, [])
    }

    func testEmptyWhenRangeIsDegenerate() {
        XCTAssertEqual(contourLevels(minimum: 10.0, maximum: 10.0, interval: 5.0).allLevels, [])
        XCTAssertEqual(contourLevels(minimum: 50.0, maximum: 10.0, interval: 5.0).allLevels, [])
    }

    func testNonPositiveIntervalYieldsNothingRatherThanThrowing() {
        // The Python raises ValueError here. Swift makes the same mistake
        // impossible to ignore differently: an interval that cannot produce lines
        // produces none, and the caller that computed it is where the fault is.
        XCTAssertEqual(contourLevels(minimum: 0.0, maximum: 100.0, interval: 0.0).allLevels, [])
        XCTAssertEqual(contourLevels(minimum: 0.0, maximum: 100.0, interval: -5.0).allLevels, [])
    }

    func testLevelCountIsCapped() {
        let levels = contourLevels(minimum: 0.0, maximum: 1_000_000.0, interval: 1.0, maxLevels: 64)
        XCTAssertLessThanOrEqual(levels.allLevels.count, 64)
    }

    func testIntervalAndAccentAreCarriedOnTheResult() {
        let levels = contourLevels(minimum: 0.0, maximum: 10.0, interval: 2.0, indexEvery: 3)
        XCTAssertEqual(levels.interval, 2.0)
        XCTAssertEqual(levels.indexEvery, 3)
    }
}

final class ContourPolylineTests: XCTestCase {

    func testPlanarRampYieldsOneStraightLine() {
        // f(row, col) = col, so the level 3.5 contour is the vertical line col = 3.5
        let grid = Field2D(rows: 6, columns: 8) { _, column in Double(column) }
        let lines = contourPolylines(grid, level: 3.5)
        XCTAssertEqual(lines.count, 1)
        for point in lines[0] {
            XCTAssertEqual(point.column, 3.5, accuracy: 1e-9)
        }
        // spans the full grid height
        let rows = lines[0].map(\.row).sorted()
        XCTAssertEqual(rows.first!, 0.0, accuracy: 1e-12)
        XCTAssertEqual(rows.last!, 5.0, accuracy: 1e-12)
    }

    func testConeYieldsAClosedRing() {
        let size = 41
        let axis = linspace(-10.0, 10.0, size)
        let grid = Field2D(rows: size, columns: size) { row, column in
            10.0 - (axis[column] * axis[column] + axis[row] * axis[row]).squareRoot()
        }
        let lines = contourPolylines(grid, level: 5.0)
        XCTAssertEqual(lines.count, 1)
        let ring = lines[0]
        XCTAssertGreaterThan(ring.count, 8)
        XCTAssertEqual(ring.first, ring.last, "a closed contour must repeat its first point")

        // every point sits on the radius-5 circle, in grid index units
        let centre = Double(size - 1) / 2.0
        let scale = 20.0 / Double(size - 1)
        for point in ring {
            let dx = (point.column - centre) * scale
            let dy = (point.row - centre) * scale
            XCTAssertEqual((dx * dx + dy * dy).squareRoot(), 5.0, accuracy: 0.15)
        }
    }

    func testPolylinePointsAreConnected() {
        let axis = linspace(-3.0, 3.0, 30)
        let grid = Field2D(rows: 30, columns: 30) { row, column in
            Foundation.sin(axis[column]) * Foundation.cos(axis[row])
        }
        for line in contourPolylines(grid, level: 0.25) {
            for index in 0..<(line.count - 1) {
                let a = line[index]
                let b = line[index + 1]
                let step = ((b.row - a.row) * (b.row - a.row) + (b.column - a.column) * (b.column - a.column)).squareRoot()
                // consecutive crossings always sit on edges of one shared cell
                XCTAssertLessThanOrEqual(step, 2.0.squareRoot() + 1e-9)
            }
        }
    }

    func testLevelAboveAndBelowDataYieldsNothing() {
        let grid = Field2D(rows: 6, columns: 8) { _, column in Double(column) }
        XCTAssertTrue(contourPolylines(grid, level: -5.0).isEmpty)
        XCTAssertTrue(contourPolylines(grid, level: 99.0).isEmpty)
    }

    func testFlatFieldAtExactlyTheLevelYieldsNothing() {
        let grid = Field2D(rows: 6, columns: 6, repeating: 3.0)
        XCTAssertTrue(contourPolylines(grid, level: 3.0).isEmpty)
    }

    func testTwoSeparatePeaksYieldTwoRings() {
        let axis = linspace(-1.0, 1.0, 60)
        func gaussian(_ x: Double, _ y: Double, centeredAt centre: Double) -> Double {
            let dx: Double = (x - centre) * 6.0
            let dy: Double = y * 6.0
            return Foundation.exp(-(dx * dx + dy * dy))
        }
        let grid = Field2D(rows: 60, columns: 60) { row, column in
            gaussian(axis[column], axis[row], centeredAt: -0.5)
                + gaussian(axis[column], axis[row], centeredAt: 0.5)
        }
        let lines = contourPolylines(grid, level: 0.5)
        XCTAssertEqual(lines.count, 2)
        for ring in lines {
            XCTAssertEqual(ring.first, ring.last)
        }
    }

    func testSaddleCellIsResolvedWithoutDanglingEdges() {
        // classic saddle: opposite corners high, the other two low
        let grid = Field2D(rows: 3, columns: 3, values: [
            2.0, 0.0, 2.0,
            0.0, 1.0, 0.0,
            2.0, 0.0, 2.0,
        ])
        let lines = contourPolylines(grid, level: 1.0)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertGreaterThanOrEqual(line.count, 2)
        }
    }

    func testDegenerateGridsAreSafe() {
        XCTAssertTrue(contourPolylines(Field2D(rows: 1, columns: 5, repeating: 0), level: 0.5).isEmpty)
        XCTAssertTrue(contourPolylines(Field2D(rows: 5, columns: 1, repeating: 0), level: 0.5).isEmpty)
        XCTAssertTrue(contourPolylines(.empty, level: 0.5).isEmpty)
    }

    func testNaNHolesDoNotProduceNonFinitePoints() {
        var values = ContiguousArray<Double>()
        for _ in 0..<6 { for column in 0..<8 { values.append(Double(column)) } }
        values[2 * 8 + 2] = .nan
        let grid = Field2D(rows: 6, columns: 8, values: values)
        for line in contourPolylines(grid, level: 3.5) {
            for point in line {
                XCTAssertTrue(point.row.isFinite && point.column.isFinite)
            }
        }
    }

    func testResultIsDeterministic() {
        let axis = linspace(-3.0, 3.0, 24)
        let grid = Field2D(rows: 24, columns: 24) { row, column in
            Foundation.sin(axis[column]) * Foundation.cos(axis[row])
        }
        // Not merely the same set of lines: the same lines in the same order,
        // with vertices in the same order. Exported SVG has to be reproducible,
        // and Swift's Dictionary iteration order is not, so the stitcher keeps
        // its own insertion order rather than walking a dictionary.
        XCTAssertEqual(contourPolylines(grid, level: 0.1), contourPolylines(grid, level: 0.1))
    }
}

final class ContourWindingTests: XCTestCase {

    /// Kickoff detail 5: winding order is the only channel that carries slope
    /// aspect through clipping, simplification and smoothing.
    func testPolylineIsWoundWithHigherGroundOnTheLeft() {
        // Ground rising to the north (+y). Travelling east (+x) puts the high
        // side on the left, so an east-bound line is already correct.
        let eastward = [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 2, y: 0)]
        let sample: (Coordinate) -> Double = { $0.y }
        let oriented = orientUphillLeft(eastward, sample: sample, level: 0.0, probe: 0.5)
        XCTAssertEqual(oriented, eastward)
    }

    func testAPolylineWoundTheWrongWayIsReversed() {
        let westward = [Coordinate(x: 2, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 0, y: 0)]
        let sample: (Coordinate) -> Double = { $0.y }
        let oriented = orientUphillLeft(westward, sample: sample, level: 0.0, probe: 0.5)
        XCTAssertEqual(oriented, westward.reversed())
    }

    func testShortOrZeroLengthPolylinesAreLeftAlone() {
        let single = [Coordinate(x: 1, y: 1)]
        XCTAssertEqual(orientUphillLeft(single, sample: { _ in 5 }, level: 0, probe: 1), single)

        let repeated = [Coordinate(x: 1, y: 1), Coordinate(x: 1, y: 1)]
        XCTAssertEqual(orientUphillLeft(repeated, sample: { _ in -5 }, level: 0, probe: 1), repeated)
    }

    func testANonFiniteSampleLeavesTheWindingUnchanged() {
        // A probe that lands in a hole must not flip the line on no evidence.
        let line = [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0)]
        XCTAssertEqual(orientUphillLeft(line, sample: { _ in .nan }, level: 0, probe: 1), line)
    }

    func testWindingSurvivesAContourTracedFromACone() {
        // A cone's contour, oriented uphill-left, must wind so that the interior
        // (the high ground) is on the left the whole way round.
        let size = 41
        let axis = linspace(-10.0, 10.0, size)
        let grid = Field2D(rows: size, columns: size) { row, column in
            10.0 - (axis[column] * axis[column] + axis[row] * axis[row]).squareRoot()
        }
        let ring = contourPolylines(grid, level: 5.0)[0]
        // Into a y-up frame so "left" means what the convention says.
        let coordinates = ring.map { Coordinate(x: $0.column, y: -$0.row) }
        let sample: (Coordinate) -> Double = { point in
            grid.clamped(row: Int((-point.y).rounded()), column: Int(point.x.rounded()))
        }
        let oriented = orientUphillLeft(coordinates, sample: sample, level: 5.0, probe: 1.0)
        // High ground inside on the left of travel means counter-clockwise.
        XCTAssertGreaterThan(Ring(oriented).signedDoubleArea, 0)
    }
}

final class PolylineProjectionTests: XCTestCase {

    func testIndexSpaceMapsOntoTheBBoxCorners() {
        let bounds = BoundingBox(minLon: 10.0, minLat: 40.0, maxLon: 12.0, maxLat: 41.0)
        let line = [GridPoint(row: 0.0, column: 0.0), GridPoint(row: 4.0, column: 8.0)]
        let projected = polylineToLonLat(line, bounds: bounds, rows: 5, columns: 9)
        // row 0 is the north edge, the last row the south edge
        XCTAssertEqual(projected[0].lon, 10.0, accuracy: 1e-12)
        XCTAssertEqual(projected[0].lat, 41.0, accuracy: 1e-12)
        XCTAssertEqual(projected[1].lon, 12.0, accuracy: 1e-12)
        XCTAssertEqual(projected[1].lat, 40.0, accuracy: 1e-12)
    }

    func testFractionalIndicesInterpolate() {
        let bounds = BoundingBox(minLon: 0.0, minLat: 0.0, maxLon: 4.0, maxLat: 2.0)
        let projected = polylineToLonLat([GridPoint(row: 1.0, column: 2.0)], bounds: bounds, rows: 3, columns: 5)
        XCTAssertEqual(projected[0].lon, 2.0, accuracy: 1e-12)
        XCTAssertEqual(projected[0].lat, 1.0, accuracy: 1e-12)
    }
}

// MARK: -

/// `np.linspace`, for the ported tests.
func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
    guard count > 1 else { return count == 1 ? [start] : [] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { start + Double($0) * step }
}

import Foundation
