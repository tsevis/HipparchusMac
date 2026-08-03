import XCTest
@testable import HipparchusGeometry

/// A flow field integrated into curves rather than animated into particles.
///
/// Every check here is against a field whose answer is known by hand — a uniform
/// drift is straight, a rotation closes, a coast stops a line — because a
/// streamline drawing is exactly the kind of picture that looks convincing while
/// being wrong.
final class StreamlineTests: XCTestCase {

    private func field(rows: Int, columns: Int, _ value: @escaping (Int, Int) -> Double) -> Field2D {
        Field2D(rows: rows, columns: columns, value)
    }

    /// An equatorial grid, so `cos(latitude)` is 1 and the arithmetic is plain.
    private func trace(
        u: Field2D, v: Field2D, settings: StreamlineSettings = StreamlineSettings()
    ) -> [[StreamlinePoint]] {
        streamlines(
            u: u, v: v, cellLonDegrees: 1, cellLatDegrees: 1,
            latitudeForRow: { _ in 0 }, settings: settings
        )
    }

    // MARK: - Shapes with known answers

    /// Due east everywhere. Every line should run along a row.
    func testAUniformDriftDrawsStraightLines() {
        let u = field(rows: 20, columns: 20) { _, _ in 1 }
        let v = field(rows: 20, columns: 20) { _, _ in 0 }
        let lines = trace(u: u, v: v)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            let rows = line.map(\.row)
            XCTAssertEqual(rows.max()! - rows.min()!, 0, accuracy: 1e-6, "an eastward drift wandered north")
        }
    }

    /// Row 0 is north, so a northward current has to walk *up* the grid — that
    /// is, towards row 0. Getting the sign wrong draws a plausible field flowing
    /// exactly backwards.
    func testNorthwardFlowWalksTowardsRowZero() throws {
        let u = field(rows: 20, columns: 20) { _, _ in 0 }
        let v = field(rows: 20, columns: 20) { _, _ in 1 }
        let lines = trace(u: u, v: v)
        let line = try XCTUnwrap(lines.max { $0.count < $1.count })
        XCTAssertLessThan(line.last!.row, line.first!.row, "northward flow should decrease the row")
    }

    /// Solid-body rotation about the centre. Streamlines are circles, so they
    /// come back to where they started and stop there rather than spiralling.
    func testARotationClosesRatherThanSpiralling() {
        let size = 31
        let centre = Double(size - 1) / 2
        let u = field(rows: size, columns: size) { row, _ in -(Double(row) - centre) }
        let v = field(rows: size, columns: size) { _, column in -(Double(column) - centre) }

        var settings = StreamlineSettings()
        settings.maxSteps = 4000
        let lines = trace(u: u, v: v, settings: settings)
        XCTAssertFalse(lines.isEmpty)

        // A closed line ends near where it began. A spiral does not, and would
        // run to the step limit instead.
        let longest = lines.max { length(of: $0) < length(of: $1) }!
        let dRow = longest.first!.row - longest.last!.row
        let dColumn = longest.first!.column - longest.last!.column
        let gap = (dRow * dRow + dColumn * dColumn).squareRoot()
        XCTAssertLessThan(gap, settings.separation * 2, "the loop did not close")
        XCTAssertLessThan(longest.count, settings.maxSteps, "it ran to the step limit, so it spiralled")
    }

    // MARK: - Where it stops

    /// A missing sample is a coast. A line has to stop at it rather than
    /// interpolate a current across the land.
    func testALineStopsAtMissingData() {
        let u = field(rows: 20, columns: 20) { _, column in column < 10 ? 1 : .nan }
        let v = field(rows: 20, columns: 20) { _, column in column < 10 ? 0 : .nan }
        let lines = trace(u: u, v: v)
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            // Bilinear sampling needs all four corners, so the last drawable
            // column is the one before the hole.
            XCTAssertLessThanOrEqual(line.map(\.column).max()!, 9.0)
        }
    }

    /// Still water has no direction, and integrating one produces a curl that is
    /// entirely the interpolator's invention.
    func testStillWaterDrawsNothing() {
        let u = field(rows: 20, columns: 20) { _, _ in 0 }
        let v = field(rows: 20, columns: 20) { _, _ in 0 }
        XCTAssertTrue(trace(u: u, v: v).isEmpty)
    }

    func testAFieldTooSmallToIntegrateDrawsNothing() {
        let u = field(rows: 1, columns: 1) { _, _ in 1 }
        XCTAssertTrue(trace(u: u, v: u).isEmpty)
    }

    // MARK: - Spacing

    /// The separation is what makes this read as a field rather than a tangle.
    /// It is measured, not inferred from a bucket — inferring rejected
    /// everything within three separations and left a dozen stray curves across
    /// a whole sea.
    func testLinesKeepTheirDistance() {
        let u = field(rows: 30, columns: 30) { _, _ in 1 }
        let v = field(rows: 30, columns: 30) { _, _ in 0 }
        var settings = StreamlineSettings()
        settings.separation = 3
        settings.seedSpacing = 1
        let lines = trace(u: u, v: v, settings: settings)

        // Every line is a row, so the gaps between them are the test.
        let rows = lines.map { $0.first!.row }.sorted()
        for (a, b) in zip(rows, rows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, settings.separation - 1e-6)
        }
    }

    /// A denser separation gives more lines. Obvious, and it is the knob a
    /// caller reaches for first, so it should behave.
    func testACloserSeparationDrawsMoreLines() {
        let u = field(rows: 30, columns: 30) { _, _ in 1 }
        let v = field(rows: 30, columns: 30) { _, _ in 0 }
        var sparse = StreamlineSettings(); sparse.separation = 5; sparse.seedSpacing = 1
        var dense = StreamlineSettings(); dense.separation = 2; dense.seedSpacing = 1
        XCTAssertGreaterThan(
            trace(u: u, v: v, settings: dense).count,
            trace(u: u, v: v, settings: sparse).count
        )
    }

    // MARK: - What rides along

    /// Speed is carried on the vertices rather than used as a step length: the
    /// shape is the direction field, and a fast current stepping further would
    /// make the drawing say more about the integrator than about the sea.
    func testSpeedIsCarriedAndNotSteppedBy() {
        let u = field(rows: 20, columns: 20) { row, _ in row < 10 ? 0.1 : 2.0 }
        let v = field(rows: 20, columns: 20) { _, _ in 0 }
        let lines = trace(u: u, v: v)

        let slow = lines.filter { $0.first!.row < 9 }.flatMap { $0.map(\.speed) }
        let fast = lines.filter { $0.first!.row > 10 }.flatMap { $0.map(\.speed) }
        XCTAssertFalse(slow.isEmpty)
        XCTAssertFalse(fast.isEmpty)
        XCTAssertEqual(slow.max()!, 0.1, accuracy: 1e-6)
        XCTAssertEqual(fast.max()!, 2.0, accuracy: 1e-6)

        // And the *steps* are the same length in both, which is the point.
        func meanStep(_ line: [StreamlinePoint]) -> Double {
            length(of: line) / Double(Swift.max(1, line.count - 1))
        }
        let slowLine = lines.first { $0.first!.row < 9 }!
        let fastLine = lines.first { $0.first!.row > 10 }!
        XCTAssertEqual(meanStep(slowLine), meanStep(fastLine), accuracy: 1e-6)
    }

    /// A degree of longitude is shorter than a degree of latitude everywhere but
    /// the equator. A field integrated without that correction leans.
    func testTheMeridiansConverge() {
        let u = field(rows: 20, columns: 20) { _, _ in 1 }
        let v = field(rows: 20, columns: 20) { _, _ in 1 }

        func heading(atLatitude latitude: Double) -> Double {
            let lines = streamlines(
                u: u, v: v, cellLonDegrees: 1, cellLatDegrees: 1,
                latitudeForRow: { _ in latitude }, settings: StreamlineSettings()
            )
            let line = lines.max { $0.count < $1.count }!
            return abs(line.last!.column - line.first!.column)
                / Swift.max(1e-9, abs(line.last!.row - line.first!.row))
        }

        // The same north-east velocity covers more *cells* of longitude at 60°
        // than at the equator, because a cell is narrower there.
        XCTAssertGreaterThan(heading(atLatitude: 60), heading(atLatitude: 0) * 1.5)
    }
}
