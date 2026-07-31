import XCTest
@testable import HipparchusGeometry

/// Turning a centre-and-span region — the shape a live locator map reports —
/// into the area this app fetches.
///
/// Expressed in plain numbers rather than against MapKit's own region type, so
/// the conversion is testable without importing MapKit into this package, and
/// so a locator is not the only thing that could ever produce one of these.
final class MapRegionTests: XCTestCase {

    // MARK: - The ordinary case

    func testACentreAndSpanBecomeTheExpectedCorners() {
        let box = BoundingBox(centerLat: 37.9838, centerLon: 23.7275, latSpan: 0.2, lonSpan: 0.3)
        XCTAssertEqual(box.minLat, 37.8838, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 38.0838, accuracy: 1e-9)
        XCTAssertEqual(box.minLon, 23.5775, accuracy: 1e-9)
        XCTAssertEqual(box.maxLon, 23.8775, accuracy: 1e-9)
    }

    // MARK: - The whole world

    /// A locator that starts at world scale must not produce a box outside
    /// what a latitude or longitude can actually be.
    func testAWholeWorldSpanStaysWithinRealCoordinates() {
        let box = BoundingBox(centerLat: 0, centerLon: 0, latSpan: 170, lonSpan: 360)
        XCTAssertGreaterThanOrEqual(box.minLat, -90)
        XCTAssertLessThanOrEqual(box.maxLat, 90)
        XCTAssertGreaterThanOrEqual(box.minLon, -180)
        XCTAssertLessThanOrEqual(box.maxLon, 180)
    }

    /// A span wider than the world itself — MapKit will hand back something
    /// like this at the most zoomed-out extreme — must clamp rather than
    /// produce a west east of east. The span is capped before it is applied,
    /// so this is centre-relative, not a promise to reach both poles from
    /// any centre: an off-centre point cannot own the whole globe evenly.
    func testAnOversizedSpanClampsRatherThanOverflowing() {
        let box = BoundingBox(centerLat: 10, centerLon: 170, latSpan: 400, lonSpan: 500)
        XCTAssertGreaterThanOrEqual(box.minLat, -90)
        XCTAssertEqual(box.maxLat, 90, "a 400° span centred at 10° reaches the north pole")
        XCTAssertGreaterThanOrEqual(box.minLon, -180)
        XCTAssertEqual(box.maxLon, 180, "a 500° span centred at 170° reaches the antimeridian")
        XCTAssertLessThan(box.minLat, box.maxLat)
        XCTAssertLessThan(box.minLon, box.maxLon)
    }

    // MARK: - Near the poles

    func testACentreNearThePoleClampsRatherThanExceedingNinety() {
        let box = BoundingBox(centerLat: 85, centerLon: 0, latSpan: 20, lonSpan: 20)
        XCTAssertEqual(box.maxLat, 90)
        XCTAssertEqual(box.minLat, 75, accuracy: 1e-9)
    }

    func testASouthernCentreClampsTheOtherWay() {
        let box = BoundingBox(centerLat: -85, centerLon: 0, latSpan: 20, lonSpan: 20)
        XCTAssertEqual(box.minLat, -90)
    }
}
