import XCTest
@testable import HipparchusGeometry

/// Turning whatever a person actually has copied into an area.
///
/// Nobody has four numbers ready to type into four separate boxes. They have a
/// bounding box copied from this app's own `--bbox` output, two corners copied
/// from a spreadsheet, a single point copied off a map, or a map link with the
/// coordinates buried in its address bar. This reads whichever of those it can
/// find, rather than insisting on one — but it does not guess at prose: a
/// sentence that happens to contain numbers is not an area.
final class CoordinateImportTests: XCTestCase {

    private func bbox(_ text: String) -> BoundingBox? { CoordinateImport.parse(text) }

    // MARK: - Four numbers: this app's own convention

    /// west, south, east, north — the same order as `--bbox` and every saved
    /// session, so a value copied from one part of this app is understood by
    /// another without translation.
    func testFourNumbersAreReadAsWestSouthEastNorth() throws {
        let box = try XCTUnwrap(bbox("23.575,37.816,23.895,38.136"))
        XCTAssertEqual(box.minLon, 23.575, accuracy: 1e-9)
        XCTAssertEqual(box.minLat, 37.816, accuracy: 1e-9)
        XCTAssertEqual(box.maxLon, 23.895, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 38.136, accuracy: 1e-9)
    }

    func testSurroundingWhitespaceAndLabelsDoNotMatter() throws {
        let box = try XCTUnwrap(bbox("  west 23.575, south 37.816, east 23.895, north 38.136  "))
        XCTAssertEqual(box.minLon, 23.575, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 38.136, accuracy: 1e-9)
    }

    func testBracketsAndNewlinesDoNotMatter() throws {
        let box = try XCTUnwrap(bbox("[23.575,\n 37.816,\n 23.895,\n 38.136]"))
        XCTAssertEqual(box.minLon, 23.575, accuracy: 1e-9)
    }

    /// A pasted west,south,east,north where west sits east of east is exactly
    /// what this app already rejects rather than silently correcting elsewhere
    /// — `Session.Area.bbox` does the same. Falling back to reading the four
    /// numbers as two lat,lon corners instead recovers a real area rather than
    /// refusing outright.
    func testFourNumbersThatFailAsAnAreaFallBackToTwoCorners() throws {
        // The north-west corner of Athens, then the south-east one, each
        // written lat, lon. Read the native way that is west(38.136) sitting
        // east of east(37.816) — structurally not an area — so this can only
        // have been two corners.
        let box = try XCTUnwrap(bbox("38.136,23.575,37.816,23.895"))
        XCTAssertEqual(box.minLon, 23.575, accuracy: 1e-9)
        XCTAssertEqual(box.minLat, 37.816, accuracy: 1e-9)
        XCTAssertEqual(box.maxLon, 23.895, accuracy: 1e-9)
        XCTAssertEqual(box.maxLat, 38.136, accuracy: 1e-9)
    }

    /// When four numbers could genuinely be read either way — both produce a
    /// real, valid area, just in different places — this app's own convention
    /// wins, because that is what four bare numbers already mean everywhere
    /// else here: `--bbox`, the saved session, the CLI's own printed output.
    /// A person pasting from this app gets back what they copied; a person
    /// pasting two lat,lon corners that happen to also read as a valid
    /// west,south,east,north box is the rarer case, and the one that must
    /// give way.
    func testGenuinelyAmbiguousFourNumbersPreferThisAppsOwnConvention() throws {
        let box = try XCTUnwrap(bbox("37.816,23.575,38.136,23.895"))
        XCTAssertEqual(box.minLon, 37.816, accuracy: 1e-9)
        XCTAssertEqual(box.minLat, 23.575, accuracy: 1e-9)
    }

    /// A longitude beyond ±90 cannot be a latitude, whichever position it sits
    /// in — this is what tells two corners-as-lat/lon apart from this app's own
    /// convention when the numbers alone would otherwise fit either reading.
    func testAnOutOfRangeLatitudePositionForcesTheCornersReading() throws {
        // 145° cannot be a latitude, so position 1 must hold a longitude —
        // these are two corners near Sydney, each written lat, lon.
        let box = try XCTUnwrap(bbox("-33.90,151.20,-33.85,151.25"))
        XCTAssertEqual(box.minLon, 151.20, accuracy: 1e-9)
        XCTAssertEqual(box.minLat, -33.90, accuracy: 1e-9)
    }

    // MARK: - Two numbers: a point

    /// The overwhelmingly common convention for a single copied point —
    /// Google Maps, Apple Maps and every GPS device all give latitude first.
    func testTwoNumbersAreReadAsLatitudeThenLongitude() throws {
        let box = try XCTUnwrap(bbox("37.9838, 23.7275"))
        let centreLat = (box.minLat + box.maxLat) / 2
        let centreLon = (box.minLon + box.maxLon) / 2
        XCTAssertEqual(centreLat, 37.9838, accuracy: 1e-6)
        XCTAssertEqual(centreLon, 23.7275, accuracy: 1e-6)
        XCTAssertGreaterThan(box.maxLon - box.minLon, 0, "a bare point must still be a drawable area")
    }

    func testAPointOutOfOrderIsStillReadCorrectly() throws {
        // 151° cannot be a latitude, so it must be the longitude regardless of
        // which position it was typed in.
        let box = try XCTUnwrap(bbox("151.20, -33.90"))
        let centreLat = (box.minLat + box.maxLat) / 2
        XCTAssertEqual(centreLat, -33.90, accuracy: 1e-6)
    }

    // MARK: - A map link

    func testAGoogleMapsLinkYieldsItsPoint() throws {
        let box = try XCTUnwrap(bbox("https://www.google.com/maps/@37.9838,23.7275,15z"))
        let centreLat = (box.minLat + box.maxLat) / 2
        let centreLon = (box.minLon + box.maxLon) / 2
        XCTAssertEqual(centreLat, 37.9838, accuracy: 1e-6)
        XCTAssertEqual(centreLon, 23.7275, accuracy: 1e-6)
    }

    func testAGoogleMapsQueryParameterYieldsItsPoint() throws {
        let box = try XCTUnwrap(bbox("https://maps.google.com/?q=37.9838,23.7275"))
        XCTAssertEqual((box.minLat + box.maxLat) / 2, 37.9838, accuracy: 1e-6)
    }

    func testAnAppleMapsLinkYieldsItsPoint() throws {
        let box = try XCTUnwrap(bbox("https://maps.apple.com/?ll=37.9838,23.7275"))
        XCTAssertEqual((box.minLat + box.maxLat) / 2, 37.9838, accuracy: 1e-6)
    }

    // MARK: - What must not be read as an area

    func testEmptyOrWhitespaceTextIsNotAnArea() {
        XCTAssertNil(bbox(""))
        XCTAssertNil(bbox("   "))
    }

    func testProseIsNotAnArea() {
        XCTAssertNil(bbox("meet me at the usual place around 3"))
    }

    /// One or three bare numbers name neither a point nor an area.
    func testAnUnusableCountOfNumbersIsNotAnArea() {
        XCTAssertNil(bbox("23.575"))
        XCTAssertNil(bbox("23.575, 37.816, 23.895"))
    }

    func testOutOfWorldValuesAreNotAnArea() {
        XCTAssertNil(bbox("200, 37.816, 210, 38.136"))
    }

    /// A degenerate box — the same point twice — is not a frame anything can
    /// be drawn inside.
    func testAZeroSizedBoxIsNotAnArea() {
        XCTAssertNil(bbox("23.575,37.816,23.575,37.816"))
    }
}
