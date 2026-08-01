import XCTest
@testable import HipparchusGeometry

/// An area shaped like the window that will draw it.
///
/// A square area drawn in a wide window is fitted to the shorter side and
/// marooned in the middle with dead margins either side — which is what the
/// map actually looked like. Widening the *request* to the window's own
/// proportions is what makes the drawn map fill it.
final class AreaShapingTests: XCTestCase {

    /// Athens, near enough square: 0.32° by 0.32°.
    private let square = BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136)

    // MARK: - The shape it produces

    func testAWideWindowWidensTheArea() {
        let shaped = AreaShaping.shaped(square, toAspect: 16.0 / 9.0)
        XCTAssertGreaterThan(shaped.lonSpan, square.lonSpan)
    }

    func testATallWindowHeightensTheArea() {
        let shaped = AreaShaping.shaped(square, toAspect: 9.0 / 16.0)
        XCTAssertGreaterThan(shaped.latSpan, square.latSpan)
    }

    func testTheShapedAreaMatchesTheWindowInProjectedSpace() {
        // The check that matters, and the one a naive degrees-only version
        // fails: latitude is stretched by Mercator, so an area that looks
        // square in degrees is not square on screen.
        for aspect in [4.0 / 3.0, 16.0 / 9.0, 1.0, 3.0 / 4.0, 0.5] {
            let shaped = AreaShaping.shaped(square, toAspect: aspect)
            XCTAssertEqual(
                AreaShaping.projectedAspect(of: shaped), aspect, accuracy: 1e-6,
                "asked for \(aspect)"
            )
        }
    }

    func testShapingNeverLosesGround() {
        // Only ever widened, never cropped: pressing Update map must not
        // quietly drop part of the area that was asked for.
        for aspect in [4.0 / 3.0, 16.0 / 9.0, 1.0, 3.0 / 4.0, 0.5, 2.5] {
            let shaped = AreaShaping.shaped(square, toAspect: aspect)
            XCTAssertLessThanOrEqual(shaped.minLon, square.minLon + 1e-9, "at \(aspect)")
            XCTAssertGreaterThanOrEqual(shaped.maxLon, square.maxLon - 1e-9, "at \(aspect)")
            XCTAssertLessThanOrEqual(shaped.minLat, square.minLat + 1e-9, "at \(aspect)")
            XCTAssertGreaterThanOrEqual(shaped.maxLat, square.maxLat - 1e-9, "at \(aspect)")
        }
    }

    func testShapingHoldsTheCentre() {
        let shaped = AreaShaping.shaped(square, toAspect: 16.0 / 9.0)
        XCTAssertEqual(
            (shaped.minLon + shaped.maxLon) / 2, (square.minLon + square.maxLon) / 2, accuracy: 1e-9
        )
        XCTAssertEqual(
            (shaped.minLat + shaped.maxLat) / 2, (square.minLat + square.maxLat) / 2, accuracy: 1e-9
        )
    }

    func testShapingAnAreaThatAlreadyFitsChangesNothing() {
        let once = AreaShaping.shaped(square, toAspect: 4.0 / 3.0)
        let twice = AreaShaping.shaped(once, toAspect: 4.0 / 3.0)
        // Idempotent, because Update map is pressed more than once and the
        // area must not creep outwards a little every time.
        XCTAssertEqual(twice.minLon, once.minLon, accuracy: 1e-9)
        XCTAssertEqual(twice.maxLon, once.maxLon, accuracy: 1e-9)
        XCTAssertEqual(twice.minLat, once.minLat, accuracy: 1e-9)
        XCTAssertEqual(twice.maxLat, once.maxLat, accuracy: 1e-9)
    }

    // MARK: - Places where the arithmetic could give up

    func testShapingStaysInsideTheWorld() {
        let nearThePole = BoundingBox(minLon: 179, minLat: 84, maxLon: 179.9, maxLat: 84.9)
        let shaped = AreaShaping.shaped(nearThePole, toAspect: 8)
        XCTAssertGreaterThanOrEqual(shaped.minLon, -180)
        XCTAssertLessThanOrEqual(shaped.maxLon, 180)
        XCTAssertGreaterThanOrEqual(shaped.minLat, -90)
        XCTAssertLessThanOrEqual(shaped.maxLat, 90)
        XCTAssertLessThan(shaped.minLon, shaped.maxLon)
        XCTAssertLessThan(shaped.minLat, shaped.maxLat)
    }

    func testANonsenseAspectIsRefusedRatherThanApplied() {
        XCTAssertEqual(AreaShaping.shaped(square, toAspect: 0), square)
        XCTAssertEqual(AreaShaping.shaped(square, toAspect: -2), square)
        XCTAssertEqual(AreaShaping.shaped(square, toAspect: .nan), square)
    }

    func testADegenerateAreaIsLeftAlone() {
        let flat = BoundingBox(minLon: 10, minLat: 5, maxLon: 10, maxLat: 5)
        XCTAssertEqual(AreaShaping.shaped(flat, toAspect: 1.5), flat)
    }

    func testEquatorialAreaIsUnaffectedByTheMercatorCorrection() {
        // At the equator projected and degree aspect agree, so this is the one
        // case where the answer can be checked by hand.
        let equator = BoundingBox(minLon: -0.5, minLat: -0.5, maxLon: 0.5, maxLat: 0.5)
        let shaped = AreaShaping.shaped(equator, toAspect: 2)
        XCTAssertEqual(shaped.lonSpan, 2.0, accuracy: 1e-3)
        XCTAssertEqual(shaped.latSpan, 1.0, accuracy: 1e-3)
    }
}
