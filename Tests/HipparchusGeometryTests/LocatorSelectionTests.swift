import XCTest
@testable import HipparchusGeometry

/// What a click and a zoom button on the locator come to mean, in degrees.
///
/// The map they act on is an `MKMapView` in a floating window that no test can
/// click, which is exactly why the arithmetic lives apart from it: everything
/// below has a right answer, and none of it needs a mouse.
final class LocatorSelectionTests: XCTestCase {

    private let athens = BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136)

    // MARK: - Clicking a place

    func testAClickBecomesABoxAroundThePoint() {
        let area = LocatorSelection.area(around: 37.9760, lon: 23.7350)
        XCTAssertLessThan(area.minLat, 37.9760)
        XCTAssertGreaterThan(area.maxLat, 37.9760)
        XCTAssertLessThan(area.minLon, 23.7350)
        XCTAssertGreaterThan(area.maxLon, 23.7350)
    }

    func testAClickIsCentredOnWhatWasClicked() {
        let area = LocatorSelection.area(around: 37.9760, lon: 23.7350)
        XCTAssertEqual((area.minLat + area.maxLat) / 2, 37.9760, accuracy: 1e-9)
        XCTAssertEqual((area.minLon + area.maxLon) / 2, 23.7350, accuracy: 1e-9)
    }

    func testAClickPadsByTheSameRuleAPastedPointDoes() {
        // One pad rule for the app, not two: a point clicked on the locator and
        // the same point pasted off the clipboard must frame the same area, or
        // the two quietly come to disagree about where Athens is.
        let clicked = LocatorSelection.area(around: 37.9760, lon: 23.7350)
        XCTAssertEqual(CoordinateImport.parse("37.9760, 23.7350"), clicked)
    }

    func testAClickNearThePoleStaysARealArea() {
        let area = LocatorSelection.area(around: 89.99, lon: 12)
        XCTAssertLessThanOrEqual(area.maxLat, 90)
        XCTAssertLessThan(area.minLat, area.maxLat)
        XCTAssertLessThan(area.minLon, area.maxLon)
    }

    func testAClickedAreaIsATownNotACountry() {
        // The whole point of clicking a place is that Update map can then fetch
        // it. `FetchCost` — which does the refusing, and lives a module away —
        // turns down whole degrees; this stays an order of magnitude under that.
        let area = LocatorSelection.area(around: 37.9760, lon: 23.7350)
        XCTAssertLessThan(area.latSpan, 0.5)
        XCTAssertLessThan(area.lonSpan, 0.5)
    }

    // MARK: - The zoom buttons

    func testZoomingInShowsLess() {
        let closer = LocatorSelection.zoomed(athens, by: 2)
        XCTAssertEqual(closer.lonSpan, athens.lonSpan / 2, accuracy: 1e-9)
        XCTAssertEqual(closer.latSpan, athens.latSpan / 2, accuracy: 1e-9)
    }

    func testZoomingOutShowsMore() {
        let wider = LocatorSelection.zoomed(athens, by: 0.5)
        XCTAssertEqual(wider.lonSpan, athens.lonSpan * 2, accuracy: 1e-9)
        XCTAssertEqual(wider.latSpan, athens.latSpan * 2, accuracy: 1e-9)
    }

    func testZoomingHoldsTheCentreStill() {
        for factor in [0.25, 0.5, 1.6, 4.0] {
            let zoomed = LocatorSelection.zoomed(athens, by: factor)
            XCTAssertEqual((zoomed.minLat + zoomed.maxLat) / 2, 37.976, accuracy: 1e-9, "at \(factor)×")
            XCTAssertEqual((zoomed.minLon + zoomed.maxLon) / 2, 23.735, accuracy: 1e-9, "at \(factor)×")
        }
    }

    func testZoomingInAndBackOutReturnsToWhereItStarted() {
        let there = LocatorSelection.zoomed(athens, by: 1.6)
        let back = LocatorSelection.zoomed(there, by: 1 / 1.6)
        XCTAssertEqual(back.minLon, athens.minLon, accuracy: 1e-9)
        XCTAssertEqual(back.maxLat, athens.maxLat, accuracy: 1e-9)
    }

    func testZoomingOutStopsAtTheWorldRatherThanPastIt() {
        var box = athens
        for _ in 0..<40 { box = LocatorSelection.zoomed(box, by: 0.5) }
        XCTAssertLessThanOrEqual(box.latSpan, 170.000001)
        XCTAssertLessThanOrEqual(box.lonSpan, 360.000001)
        XCTAssertGreaterThanOrEqual(box.minLat, -90)
        XCTAssertLessThanOrEqual(box.maxLat, 90)
        XCTAssertGreaterThanOrEqual(box.minLon, -180)
        XCTAssertLessThanOrEqual(box.maxLon, 180)
    }

    func testZoomingInStopsBeforeTheBoxStopsBeingAnArea() {
        var box = athens
        for _ in 0..<60 { box = LocatorSelection.zoomed(box, by: 2) }
        // Still a real area — west strictly less than east, south than north —
        // which is what `MapModel.bbox` insists on before anything can be
        // fetched at all. A held-down zoom button must not quietly disable
        // Update map.
        XCTAssertLessThan(box.minLon, box.maxLon)
        XCTAssertLessThan(box.minLat, box.maxLat)
        XCTAssertGreaterThanOrEqual(box.latSpan, 0.001)
    }

    func testZoomingKeepsTheShapeOfTheBoxEvenAtTheLimits() {
        // A box twice as wide as it is tall must stay twice as wide, or the
        // rectangle the locator draws stops describing the area it claims to.
        let wide = BoundingBox(minLon: 0, minLat: 0, maxLon: 2, maxLat: 1)
        var box = wide
        for _ in 0..<40 { box = LocatorSelection.zoomed(box, by: 0.5) }
        XCTAssertEqual(box.lonSpan / box.latSpan, 2, accuracy: 1e-6)
    }

    func testZoomingByNothingChangesNothing() {
        let same = LocatorSelection.zoomed(athens, by: 1)
        XCTAssertEqual(same.minLon, athens.minLon, accuracy: 1e-12)
        XCTAssertEqual(same.maxLat, athens.maxLat, accuracy: 1e-12)
    }

    func testADegenerateBoxIsLeftAloneRatherThanDividedByZero() {
        let flat = BoundingBox(minLon: 10, minLat: 5, maxLon: 10, maxLat: 5)
        XCTAssertEqual(LocatorSelection.zoomed(flat, by: 2), flat)
    }

    func testANonsenseZoomFactorIsRefusedRatherThanApplied() {
        XCTAssertEqual(LocatorSelection.zoomed(athens, by: 0), athens)
        XCTAssertEqual(LocatorSelection.zoomed(athens, by: -2), athens)
    }
}
