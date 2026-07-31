import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Combining two geocoders into one list of candidates.
///
/// Neither source alone is enough: Nominatim knows real boundaries but not every
/// landmark or business; MapKit knows landmarks and businesses but conflates a
/// place with anything sharing its name. Merged, a real place should read first
/// and a decoy should not be allowed to bury it — but two genuinely different
/// places that happen to share a name must both survive.
final class PlaceSearchMergeTests: XCTestCase {

    private func place(
        _ name: String, _ detail: String = "", lon: Double, lat: Double, span: Double = 0.1,
        isBoundary: Bool
    ) -> GeocodedPlace {
        GeocodedPlace(
            name: name, detail: detail,
            bbox: BoundingBox(
                minLon: lon - span / 2, minLat: lat - span / 2,
                maxLon: lon + span / 2, maxLat: lat + span / 2
            ),
            isBoundary: isBoundary
        )
    }

    // MARK: - Ordering

    /// A real boundary answers "a map of this place" reliably; a point of
    /// interest with the same name does not. The boundary reads first whatever
    /// order the two sources returned their own results in.
    func testBoundaryMatchesOutrankPointsOfInterest() {
        let poi = place("Limnos", lon: 25.91, lat: 38.47, isBoundary: false)
        let island = place("Lemnos", lon: 25.25, lat: 39.90, isBoundary: true)

        // Nominatim itself, and MapKit, in whatever order each returned them.
        let merged = PlaceSearchMerge.merge(nominatim: [poi, island], mapKit: [])
        XCTAssertEqual(merged.map(\.name), ["Lemnos", "Limnos"])
    }

    func testNominatimBoundariesOutrankMapKitResultsEntirely() {
        let mapKitHit = place("Lemnos", lon: 25.20, lat: 39.85, isBoundary: false)
        let nominatimBoundary = place("Lemnos", lon: 25.25, lat: 39.90, isBoundary: true)

        let merged = PlaceSearchMerge.merge(nominatim: [nominatimBoundary], mapKit: [mapKitHit])
        // The two refer to the same place (same name, close together), so only
        // the boundary survives — see the dedup tests below for why.
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isBoundary)
    }

    // MARK: - Deduplication

    /// The same place, found by both engines and named the same, must not
    /// appear twice.
    func testTheSamePlaceFromBothEnginesAppearsOnce() {
        let fromNominatim = place("Santorini", lon: 25.43, lat: 36.40, isBoundary: true)
        let fromMapKit = place("Santorini", lon: 25.40, lat: 36.42, isBoundary: false)

        let merged = PlaceSearchMerge.merge(nominatim: [fromNominatim], mapKit: [fromMapKit])
        XCTAssertEqual(merged.count, 1)
    }

    /// Two places that merely share a name, on opposite sides of the map, are
    /// two different answers and both belong in the list.
    func testTwoDifferentPlacesWithTheSameNameBothSurvive() {
        let island = place("Limnos", lon: 25.25, lat: 39.90, isBoundary: true)
        let hamlet = place("Limnos", lon: 25.91, lat: 38.47, isBoundary: false)

        let merged = PlaceSearchMerge.merge(nominatim: [island, hamlet], mapKit: [])
        XCTAssertEqual(merged.count, 2)
    }

    /// Different names, close together — a shop on the island the query also
    /// matched — are two different answers, not a duplicate.
    func testDifferentNamesNearEachOtherBothSurvive() {
        let island = place("Santorini", lon: 25.43, lat: 36.40, isBoundary: true)
        let taverna = place("Santorini Taverna", lon: 25.43, lat: 36.41, isBoundary: false)

        let merged = PlaceSearchMerge.merge(nominatim: [island], mapKit: [taverna])
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Bounds and edge cases

    func testTheListIsCappedAtTheGivenLimit() {
        let many = (0..<20).map { place("Place \($0)", lon: Double($0) * 5, lat: 0, isBoundary: false) }
        XCTAssertEqual(PlaceSearchMerge.merge(nominatim: [], mapKit: many, limit: 6).count, 6)
    }

    func testEmptyInputsProduceAnEmptyList() {
        XCTAssertEqual(PlaceSearchMerge.merge(nominatim: [], mapKit: []), [])
    }

    /// Case and accents must not defeat deduplication: "Lesvos" and "lésvos" are
    /// the same word to a person typing.
    func testDeduplicationIgnoresCaseAndAccents() {
        let plain = place("Lesvos", lon: 26.0, lat: 39.2, isBoundary: true)
        let accented = place("Lésvos", lon: 26.01, lat: 39.19, isBoundary: false)
        XCTAssertEqual(PlaceSearchMerge.merge(nominatim: [plain], mapKit: [accented]).count, 1)
    }
}
