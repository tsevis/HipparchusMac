import XCTest
@testable import HipparchusGeometry

/// A relation is a list of ways in arbitrary order and arbitrary direction. These
/// are the shapes that arbitrariness actually takes in OSM data.
final class RingAssemblyTests: XCTestCase {

    private func point(_ x: Double, _ y: Double) -> Coordinate {
        Coordinate(x: x, y: y)
    }

    /// The common case: 838 of the 1 097 relations in an Athens fetch arrive with
    /// every outer way already closed.
    func testAnAlreadyClosedFragmentIsTakenAsItIs() {
        let square = [point(0, 0), point(4, 0), point(4, 4), point(0, 4), point(0, 0)]
        let result = RingAssembly.rings(from: [square])

        XCTAssertEqual(result.rings.count, 1)
        XCTAssertTrue(result.unclosed.isEmpty)
        XCTAssertEqual(result.rings.first?.coordinates.count, 5)
    }

    func testFragmentsAreStitchedEndToEnd() throws {
        let result = RingAssembly.rings(from: [
            [point(0, 0), point(4, 0)],
            [point(4, 0), point(4, 4)],
            [point(4, 4), point(0, 4)],
            [point(0, 4), point(0, 0)],
        ])

        XCTAssertEqual(result.rings.count, 1)
        XCTAssertTrue(result.unclosed.isEmpty)
        let ring = try XCTUnwrap(result.rings.first)
        // Four corners, plus the repeated first point that closes it.
        XCTAssertEqual(ring.coordinates.count, 5)
        XCTAssertEqual(abs(ring.signedDoubleArea) / 2, 16, accuracy: 1e-9)
    }

    /// Ways in a relation have no agreed direction, so half of them arrive reversed.
    func testAFragmentJoiningBackwardsIsTurnedRound() throws {
        let result = RingAssembly.rings(from: [
            [point(0, 0), point(4, 0)],
            // Both of these run the "wrong" way.
            [point(4, 4), point(4, 0)],
            [point(0, 4), point(4, 4)],
            [point(0, 0), point(0, 4)],
        ])

        XCTAssertEqual(result.rings.count, 1)
        let ring = try XCTUnwrap(result.rings.first)
        XCTAssertEqual(abs(ring.signedDoubleArea) / 2, 16, accuracy: 1e-9)
    }

    /// Members arrive in whatever order the relation lists them.
    func testFragmentsInAnyOrderMakeTheSameRing() throws {
        let pieces = [
            [point(4, 4), point(0, 4)],
            [point(0, 0), point(4, 0)],
            [point(0, 4), point(0, 0)],
            [point(4, 0), point(4, 4)],
        ]
        let result = RingAssembly.rings(from: pieces)
        XCTAssertEqual(result.rings.count, 1)
        XCTAssertEqual(abs(try XCTUnwrap(result.rings.first).signedDoubleArea) / 2, 16, accuracy: 1e-9)
    }

    func testTwoSeparateRingsComeOutSeparately() {
        let result = RingAssembly.rings(from: [
            [point(0, 0), point(1, 0)], [point(1, 0), point(1, 1)],
            [point(1, 1), point(0, 1)], [point(0, 1), point(0, 0)],
            [point(5, 5), point(6, 5)], [point(6, 5), point(6, 6)],
            [point(6, 6), point(5, 6)], [point(5, 6), point(5, 5)],
        ])
        XCTAssertEqual(result.rings.count, 2)
        XCTAssertTrue(result.unclosed.isEmpty)
    }

    /// Broken relations exist. Losing the rest of the map to one is not acceptable,
    /// and neither is pretending the gap closed.
    func testAChainThatNeverClosesIsReportedRatherThanFaked() {
        let result = RingAssembly.rings(from: [
            [point(0, 0), point(4, 0)],
            [point(4, 0), point(4, 4)],
            // The way home is missing.
        ])
        XCTAssertTrue(result.rings.isEmpty)
        XCTAssertEqual(result.unclosed.count, 1)
        XCTAssertEqual(result.unclosed.first?.count, 3)
    }

    func testAGoodRingSurvivesABrokenOneBesideIt() {
        let result = RingAssembly.rings(from: [
            [point(0, 0), point(1, 0)], [point(1, 0), point(1, 1)],
            [point(1, 1), point(0, 1)], [point(0, 1), point(0, 0)],
            [point(9, 9), point(9, 10)],
        ])
        XCTAssertEqual(result.rings.count, 1)
        XCTAssertEqual(result.unclosed.count, 1)
    }

    func testNothingUsableIsNoRingsRatherThanACrash() {
        XCTAssertTrue(RingAssembly.rings(from: []).rings.isEmpty)
        XCTAssertTrue(RingAssembly.rings(from: [[point(0, 0)]]).rings.isEmpty)
        XCTAssertTrue(RingAssembly.rings(from: [[]]).rings.isEmpty)
    }

    // MARK: - Holes

    private func square(_ minimum: Double, _ maximum: Double) -> Ring {
        Ring([
            point(minimum, minimum), point(maximum, minimum),
            point(maximum, maximum), point(minimum, maximum),
        ])
    }

    func testAHoleGoesInsideTheRingThatContainsIt() throws {
        let polygons = RingAssembly.polygons(
            outer: [square(0, 10), square(100, 110)],
            inner: [square(2, 4)]
        )
        XCTAssertEqual(polygons.count, 2)
        XCTAssertEqual(polygons[0].holes.count, 1, "the hole belongs to the ring it sits in")
        XCTAssertEqual(polygons[1].holes.count, 0, "the far ring must not collect it")
    }

    /// Rings nest. An island in a lake in an island must not hand its lake to the
    /// outermost coastline.
    func testAHoleGoesToTheSmallestRingContainingIt() {
        let polygons = RingAssembly.polygons(
            outer: [square(0, 100), square(10, 40)],
            inner: [square(20, 30)]
        )
        XCTAssertEqual(polygons.count, 2)
        XCTAssertTrue(polygons[0].holes.isEmpty, "the outermost ring took a hole that is not its own")
        XCTAssertEqual(polygons[1].holes.count, 1)
    }

    func testARingWithNoHolesIsStillAPolygon() {
        let polygons = RingAssembly.polygons(outer: [square(0, 10)], inner: [])
        XCTAssertEqual(polygons.count, 1)
        XCTAssertTrue(polygons[0].holes.isEmpty)
    }

    /// A hole nobody claims is dropped rather than attached to the wrong shape.
    func testAStrayHoleIsNotForcedOntoARing() {
        let polygons = RingAssembly.polygons(outer: [square(0, 10)], inner: [square(50, 60)])
        XCTAssertEqual(polygons.count, 1)
        XCTAssertTrue(polygons[0].holes.isEmpty)
    }

    func testNoOuterRingIsNoPolygons() {
        XCTAssertTrue(RingAssembly.polygons(outer: [], inner: [square(0, 1)]).isEmpty)
    }

    // MARK: - Containment

    func testRingContainmentHandlesTheAwkwardCases() {
        let ring = square(0, 10)
        XCTAssertTrue(ring.contains(point(5, 5)))
        XCTAssertFalse(ring.contains(point(15, 5)))
        XCTAssertFalse(ring.contains(point(5, 15)))
        XCTAssertFalse(ring.contains(point(-5, 5)))

        // A concave shape: the notch is outside even though it is within the bounds.
        let horseshoe = Ring([
            point(0, 0), point(10, 0), point(10, 10), point(7, 10),
            point(7, 3), point(3, 3), point(3, 10), point(0, 10),
        ])
        XCTAssertTrue(horseshoe.contains(point(1, 5)))
        XCTAssertTrue(horseshoe.contains(point(5, 1)))
        XCTAssertFalse(horseshoe.contains(point(5, 8)), "the notch is outside the shape")
    }

    // MARK: - Scale

    /// The Aegean Sea relation in an Athens fetch is 2 055 outer ways and 1 768
    /// inner ones. Stitching that by comparing every fragment with every other is
    /// four million comparisons for a single feature.
    func testAThousandFragmentsAssembleQuickly() {
        let steps = 2000
        // Built from one shared list of vertices, not from trig evaluated twice.
        // Two ways joined in OSM share a *node*, so their endpoints are the same
        // number to the last bit — and the assembler relies on that rather than on
        // a tolerance, which would risk joining ways that merely pass close.
        let vertices = (0..<steps).map { step -> Coordinate in
            let angle = Double(step) / Double(steps) * 2 * .pi
            return point(cos(angle) * 100, sin(angle) * 100)
        }
        var fragments = (0..<steps).map { step in
            [vertices[step], vertices[(step + 1) % steps]]
        }
        fragments.shuffle()

        let started = ContinuousClock.now
        let result = RingAssembly.rings(from: fragments)
        let elapsed = ContinuousClock.now - started

        XCTAssertEqual(result.rings.count, 1)
        XCTAssertTrue(result.unclosed.isEmpty)
        XCTAssertLessThan(elapsed, .seconds(1), "assembly is not linear in the fragment count")
    }
}
