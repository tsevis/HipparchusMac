import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// A real place, found by name, from OpenStreetMap's own geocoder.
///
/// MapKit's local search is a places-and-businesses index. Asked for "Lesvos" it
/// answers with a taverna in Athens called "Ouzeri Lesvos", because that is what
/// its index is actually full of; asked for "Limnos" it sometimes returns the
/// island and sometimes a same-named hamlet nowhere near it. Nominatim indexes
/// OSM's own boundary polygons, so the same queries come back as the island,
/// correctly sized — because it is a different kind of index, not a better copy
/// of the same one.
final class NominatimGeocoderTests: XCTestCase {

    /// Answers with canned responses and counts the calls, so the rate limit and
    /// the URL it built can both be checked.
    private final class StubGET: HTTPFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []
        private var _responses: [Result<Data, any Error>]

        init(_ responses: [Result<Data, any Error>]) { self._responses = responses }
        convenience init(_ text: String) { self.init([.success(Data(text.utf8))]) }

        var urls: [URL] { lock.withLock { _urls } }

        func data(from url: URL, timeout: TimeInterval) async throws -> Data {
            try lock.withLock {
                _urls.append(url)
                guard !_responses.isEmpty else { throw HTTPError(url: url, statusCode: 500) }
                return try _responses.removeFirst().get()
            }
        }
    }

    private struct StubError: Error {}

    /// The real response Nominatim gives for "Lesvos, Greece" with `accept-language=en`.
    private let lesvos = """
        [{"place_id":55079683,"osm_type":"relation","osm_id":6830778,
          "lat":"39.1758419","lon":"25.9989135","category":"place","type":"island",
          "addresstype":"island","name":"Lesbos","display_name":"Lesbos, Aegean, Greece",
          "boundingbox":["38.9615782","39.3901533","25.8316480","26.6159708"]}]
        """

    /// The real response for "Limnos, Greece": the island (as "Lemnos") and an
    /// unrelated hamlet the same query also happens to match.
    private let limnos = """
        [{"place_id":1,"osm_type":"relation","osm_id":2,
          "lat":"39.90","lon":"25.25","category":"place","type":"island",
          "addresstype":"island","name":"Lemnos",
          "display_name":"Lemnos, Lemnos Regional Unit, Northern Aegean, Aegean, Greece",
          "boundingbox":["39.70","40.10","24.95","25.50"]},
         {"place_id":3,"osm_type":"node","osm_id":4,
          "lat":"38.47","lon":"25.91","category":"place","type":"hamlet",
          "addresstype":"hamlet","name":"Limnos",
          "display_name":"Limnos, Chios Regional Unit, Northern Aegean, Aegean, Greece",
          "boundingbox":["38.4559","38.4918","25.8907","25.9366"]}]
        """

    private func geocoder(_ http: HTTPFetching) -> NominatimGeocoder {
        NominatimGeocoder(http: http)
    }

    // MARK: - The request

    func testTheRequestAsksForEnglishAndAHandfulOfCandidates() async throws {
        let stub = StubGET(lesvos)
        _ = try await geocoder(stub).search("Lesvos, Greece")

        let url = try XCTUnwrap(stub.urls.first)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(byName["q"], "Lesvos, Greece")
        XCTAssertEqual(byName["format"], "jsonv2")
        // English, or the result is a name in whatever script OSM tagged it in —
        // "Λέσβος" is correct and useless to someone who typed "Lesvos".
        XCTAssertEqual(byName["accept-language"], "en")
        XCTAssertNotNil(byName["limit"])
    }

    func testAShortQueryAsksNothing() async throws {
        let stub = StubGET(lesvos)
        let found = try await geocoder(stub).search("L")
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(stub.urls.isEmpty, "a one-letter query should never reach the network")
    }

    // MARK: - Parsing

    /// **Nominatim's own bounding-box order**: south, north, west, east — not the
    /// order this app's `BoundingBox` uses. Getting this swap wrong silently
    /// answers a query with a box for somewhere else.
    func testBoundingBoxOrderIsConvertedCorrectly() async throws {
        let found = try await geocoder(StubGET(lesvos)).search("Lesvos, Greece")
        let place = try XCTUnwrap(found.first)

        XCTAssertEqual(place.bbox.minLat, 38.9615782, accuracy: 1e-6)
        XCTAssertEqual(place.bbox.maxLat, 39.3901533, accuracy: 1e-6)
        XCTAssertEqual(place.bbox.minLon, 25.8316480, accuracy: 1e-6)
        XCTAssertEqual(place.bbox.maxLon, 26.6159708, accuracy: 1e-6)
    }

    func testTheNameAndDetailComeFromTheEnglishFields() async throws {
        let found = try await geocoder(StubGET(lesvos)).search("Lesvos, Greece")
        let place = try XCTUnwrap(found.first)
        XCTAssertEqual(place.name, "Lesbos")
        XCTAssertEqual(place.detail, "Aegean, Greece")
    }

    /// The signal MapKit's own results do not carry: a real geographic area,
    /// rather than a business or address that merely shares its name.
    func testPlaceAndBoundaryCategoriesAreMarkedAsBoundaries() async throws {
        let found = try await geocoder(StubGET(lesvos)).search("query")
        let island = try XCTUnwrap(found.first)
        XCTAssertTrue(island.isBoundary)
    }

    func testAShopOrRestaurantIsNotMarkedAsABoundary() async throws {
        let response = """
            [{"lat":"37.98","lon":"23.72","category":"amenity","type":"restaurant",
              "name":"Ouzeri Lesvos","display_name":"Ouzeri Lesvos, Athens, Attica, Greece",
              "boundingbox":["37.9665","38.0024","23.7102","23.7557"]}]
            """
        let found = try await geocoder(StubGET(response)).search("query")
        let place = try XCTUnwrap(found.first)
        XCTAssertFalse(place.isBoundary)
    }

    /// Two real, differently-named-but-similar places from one query, in
    /// Nominatim's own order — both are legitimate "place" matches (an island
    /// and a hamlet both are, in OSM's own terms), and nothing here should
    /// re-rank what Nominatim already ranked by importance.
    func testTwoCandidatesFromOneQueryPreserveNominatimsOwnOrder() async throws {
        let found = try await geocoder(StubGET(limnos)).search("Limnos, Greece")
        XCTAssertEqual(found.map(\.name), ["Lemnos", "Limnos"])
        XCTAssertTrue(found.allSatisfy(\.isBoundary), "a hamlet is still a real place, not a decoy business")
    }

    // MARK: - What must not happen

    func testAnEmptyResultListIsNotAnError() async throws {
        let found = try await geocoder(StubGET("[]")).search("query")
        XCTAssertEqual(found, [])
    }

    /// An outage page or a proxy notice must read as no results, not as a crash —
    /// the same tolerance every other provider in this app gives a bad response.
    func testAResponseThatIsNotJSONYieldsNoResults() async throws {
        let found = try await geocoder(StubGET("<html>rate limited</html>")).search("query")
        XCTAssertEqual(found, [])
    }

    /// An entry missing its bounding box is dropped rather than crashing the rest
    /// of the list.
    func testAnEntryWithNoUsableBoundingBoxIsSkipped() async throws {
        let response = """
            [{"lat":"1","lon":"1","category":"place","type":"island","name":"Ghost",
              "display_name":"Ghost"},
             {"lat":"2","lon":"2","category":"place","type":"island","name":"Real",
              "display_name":"Real, Somewhere","boundingbox":["1","2","1","2"]}]
            """
        let found = try await geocoder(StubGET(response)).search("query")
        XCTAssertEqual(found.map(\.name), ["Real"])
    }

    /// A degenerate box — a bare point with no span — must not become an area a
    /// caller cannot draw a frame around.
    func testADegenerateBoundingBoxIsPaddedRatherThanLeftEmpty() async throws {
        let response = """
            [{"lat":"1","lon":"1","category":"place","type":"islet","name":"Speck",
              "display_name":"Speck","boundingbox":["1","1","1","1"]}]
            """
        let found = try await geocoder(StubGET(response)).search("query")
        let place = try XCTUnwrap(found.first)
        XCTAssertGreaterThan(place.bbox.maxLat, place.bbox.minLat)
        XCTAssertGreaterThan(place.bbox.maxLon, place.bbox.minLon)
    }

    func testAFailedRequestThrowsRatherThanLookingLikeNoResults() async {
        let stub = StubGET([.failure(StubError())])
        do {
            _ = try await geocoder(stub).search("query")
            XCTFail("a failed request must not look like a place that does not exist")
        } catch is NominatimGeocodeError {
            // Correct.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Being a good citizen of a shared, free service

    /// Nominatim's usage policy caps automated use at one request a second. This
    /// geocoder must hold to that across calls on the same instance, not merely
    /// within one — the whole reason `RateLimiter` is an actor and not a value
    /// reset on every call.
    func testRepeatedSearchesAreSpacedByTheConfiguredRate() async throws {
        var settings = NominatimSettings()
        settings.requestsPerSecond = 20
        let geocoder = NominatimGeocoder(settings: settings, http: StubGET([
            .success(Data("[]".utf8)), .success(Data("[]".utf8)),
        ]))

        let started = ContinuousClock.now
        _ = try await geocoder.search("aa")
        _ = try await geocoder.search("bb")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(45))
    }
}
