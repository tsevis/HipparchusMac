import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Records what was asked for and answers from memory, so no test touches the
/// network. The same seam the Python uses with its injectable `http_post`.
private final class StubHTTP: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(url: URL, body: [String: String])] = []
    private var _responses: [Result<Data, any Error>]

    init(responses: [Result<Data, any Error>]) {
        self._responses = responses
    }

    convenience init(json: String) {
        self.init(responses: [.success(Data(json.utf8))])
    }

    var requests: [(url: URL, body: [String: String])] {
        lock.withLock { _requests }
    }

    func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        try await post([:], to: url, timeout: timeout)
    }

    func post(_ body: [String: String], to url: URL, timeout: TimeInterval) async throws -> Data {
        try lock.withLock {
            _requests.append((url, body))
            guard !_responses.isEmpty else { throw HTTPError(url: url, statusCode: 504) }
            return try _responses.removeFirst().get()
        }
    }
}

private struct StubError: Error {}

final class OverpassQueryTests: XCTestCase {

    private let query = BBoxQuery(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136)

    /// Overpass bbox filters are `south,west,north,east` — latitude first. This is
    /// the same trap as WMS 1.3.0 with EPSG:4326, and getting it backwards returns a
    /// valid map of somewhere else rather than an error.
    func testTheBoundingBoxIsLatitudeFirst() {
        let text = OverpassQuery.build(query)
        XCTAssertTrue(
            text.contains("(37.816,23.575,38.136,23.895)"),
            "the bbox must read south,west,north,east"
        )
        XCTAssertFalse(text.contains("(23.575,37.816"), "longitude came first")
    }

    func testAskingForOneLayerDoesNotFetchTheOthers() {
        let text = OverpassQuery.build(BBoxQuery(bbox: query.bbox, layers: ["roads"]))
        XCTAssertTrue(text.contains(#"way["highway"]"#))
        XCTAssertFalse(text.contains(#"way["building"]"#), "buildings were never asked for")
    }

    /// The expensive path, and the one an unfiltered request takes.
    func testAskingForNothingAsksForEverything() {
        let text = OverpassQuery.build(query)
        for fragment in [#"way["highway"]"#, #"way["building"]"#, #"node["place"]"#] {
            XCTAssertTrue(text.contains(fragment), "\(fragment) is missing")
        }
    }

    func testAnUnknownLayerIsIgnoredRatherThanSentAsGibberish() {
        let text = OverpassQuery.build(BBoxQuery(bbox: query.bbox, layers: ["roads", "unicorns"]))
        XCTAssertFalse(text.contains("unicorn"))
        XCTAssertTrue(text.contains(#"way["highway"]"#))
    }

    func testTheQueryAsksForJSONAndResolvedGeometry() {
        let text = OverpassQuery.build(query)
        XCTAssertTrue(text.hasPrefix("[out:json]"))
        // Without `geom` a way is a list of node ids and nothing can draw it.
        XCTAssertTrue(text.contains("out body geom;"))
    }
}

final class OverpassDecodeTests: XCTestCase {

    private func payload(_ elements: String) -> [String: Any] {
        // swiftlint:disable:next force_try
        try! JSONSerialization.jsonObject(
            with: Data(#"{"elements": [\#(elements)]}"#.utf8)
        ) as! [String: Any]
    }

    private let ringNodes = """
        {"lat": 0.0, "lon": 0.0}, {"lat": 0.0, "lon": 1.0},
        {"lat": 1.0, "lon": 1.0}, {"lat": 1.0, "lon": 0.0}, {"lat": 0.0, "lon": 0.0}
        """

    func testANodeBecomesAPointInTheRightLayer() throws {
        let collection = OverpassDecode.featureCollection(from: payload("""
            {"type": "node", "id": 1, "lat": 37.98, "lon": 23.73,
             "tags": {"place": "city", "name": "Athens"}}
            """))
        let places = collection.features(in: "places")
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.first?.property("name")?.stringValue, "Athens")
        guard case .point(let point) = places.first?.geometry else { return XCTFail("not a point") }
        XCTAssertEqual(point.lon, 23.73, accuracy: 1e-9)
        XCTAssertEqual(point.lat, 37.98, accuracy: 1e-9)
    }

    func testAWayBecomesALineWithEveryVertex() throws {
        let collection = OverpassDecode.featureCollection(from: payload("""
            {"type": "way", "id": 7, "tags": {"highway": "primary"},
             "geometry": [{"lat": 1.0, "lon": 2.0}, {"lat": 1.5, "lon": 2.5}, {"lat": 2.0, "lon": 3.0}]}
            """))
        let roads = collection.features(in: "roads")
        XCTAssertEqual(roads.count, 1)
        guard case .lineString(let line) = roads.first?.geometry else { return XCTFail("not a line") }
        XCTAssertEqual(line.coordinates.count, 3)
    }

    /// A roundabout is a closed way and is emphatically not a polygon. Only tags
    /// that say the way encloses something make it an area.
    func testAClosedRoadStaysALineWhileAClosedBuildingBecomesAnArea() throws {
        let collection = OverpassDecode.featureCollection(from: payload("""
            {"type": "way", "id": 1, "tags": {"highway": "residential", "junction": "roundabout"},
             "geometry": [\(ringNodes)]},
            {"type": "way", "id": 2, "tags": {"building": "yes"}, "geometry": [\(ringNodes)]}
            """))

        guard case .lineString = collection.features(in: "roads").first?.geometry else {
            return XCTFail("a roundabout became a polygon")
        }
        guard case .polygon = collection.features(in: "buildings").first?.geometry else {
            return XCTFail("a building did not become a polygon")
        }
    }

    /// Classification order is load-bearing: a park tagged `landuse` must be a park.
    func testTheMoreSpecificTagWins() {
        func layer(_ tags: String) -> String? {
            let object = try? JSONSerialization.jsonObject(with: Data(tags.utf8)) as? [String: Any]
            return OverpassDecode.classify(tags: object ?? [:])
        }
        XCTAssertEqual(layer(#"{"leisure": "park", "landuse": "grass"}"#), "parks")
        XCTAssertEqual(layer(#"{"railway": "rail", "highway": "crossing"}"#), "railways")
        XCTAssertEqual(layer(#"{"natural": "coastline"}"#), "coastline")
        XCTAssertEqual(layer(#"{"landuse": "reservoir"}"#), "water")
        XCTAssertEqual(layer(#"{"landuse": "industrial"}"#), "landuse")
        XCTAssertNil(layer(#"{"note": "nothing we draw"}"#))
    }

    func testAWayWithNoResolvedGeometryIsSkippedRatherThanDrawnWrong() {
        let collection = OverpassDecode.featureCollection(from: payload("""
            {"type": "way", "id": 3, "tags": {"highway": "service"}, "nodes": [1, 2, 3]}
            """))
        XCTAssertTrue(collection.features(in: "roads").isEmpty)
    }

    /// An empty map should explain itself, so every layer stays listed.
    func testEveryLayerIsPresentEvenWhenEmpty() {
        let collection = OverpassDecode.featureCollection(from: payload(""))
        XCTAssertEqual(Set(collection.layerNames), Set(OverpassQuery.supportedLayers))
        XCTAssertEqual(collection.featureCount, 0)
    }

    func testOSMDataClaimsToBeMeasured() {
        let collection = OverpassDecode.featureCollection(from: payload("""
            {"type": "node", "id": 1, "lat": 1.0, "lon": 1.0, "tags": {"place": "town", "name": "X"}}
            """))
        XCTAssertEqual(collection.provenance, .measured)
        XCTAssertEqual(collection.features(in: "places").first?.provenance, .measured)
    }
}

final class OverpassProviderTests: XCTestCase {

    private let query = BBoxQuery(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)
    private let oneRoad = """
        {"elements": [{"type": "way", "id": 1, "tags": {"highway": "primary"},
         "geometry": [{"lat": 36.4, "lon": 25.4}, {"lat": 36.41, "lon": 25.41}]}]}
        """

    /// The real pacing is one request a second, which is right against a shared
    /// public instance and wrong in a suite that should finish in about a second.
    private var unpaced: OverpassSettings {
        var settings = OverpassSettings()
        settings.requestsPerSecond = 10_000
        settings.baseRetryDelay = .milliseconds(1)
        return settings
    }

    func testTheQueryTravelsInThePostBodyNotTheURL() async throws {
        let http = StubHTTP(json: oneRoad)
        let collection = try await OverpassProvider(settings: unpaced, http: http).fetch(query)

        XCTAssertEqual(collection.features(in: "roads").count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://overpass-api.de/api/interpreter")
        // A city query with every layer is thousands of characters; it cannot be a URL.
        XCTAssertTrue(request.body["data"]?.contains("out body geom;") == true)
    }

    /// The second fetch of an area must not cost another five minutes.
    func testTheSameAreaIsNeverPaidForTwice() async throws {
        let http = StubHTTP(json: oneRoad)
        let provider = OverpassProvider(settings: unpaced, http: http, cache: MemoryCacheStore())

        let first = try await provider.fetch(query)
        let second = try await provider.fetch(query)

        XCTAssertEqual(http.requests.count, 1, "the second fetch went to the network")
        XCTAssertEqual(first.metadata["cache"]?.stringValue, "miss")
        XCTAssertEqual(second.metadata["cache"]?.stringValue, "hit")
        XCTAssertEqual(second.features(in: "roads").count, 1)
    }

    func testADifferentAreaIsADifferentCacheEntry() async throws {
        let http = StubHTTP(responses: [.success(Data(oneRoad.utf8)), .success(Data(oneRoad.utf8))])
        let provider = OverpassProvider(settings: unpaced, http: http, cache: MemoryCacheStore())

        _ = try await provider.fetch(query)
        _ = try await provider.fetch(BBoxQuery(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1))
        XCTAssertEqual(http.requests.count, 2)
    }

    /// A busy public instance answers a retry far more often than a repeat.
    func testAFailingEndpointFallsThroughToAMirror() async throws {
        let http = StubHTTP(responses: [
            .failure(StubError()),
            .success(Data(oneRoad.utf8)),
        ])
        let collection = try await OverpassProvider(settings: unpaced, http: http).fetch(query)
        XCTAssertEqual(collection.features(in: "roads").count, 1)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertNotEqual(http.requests[0].url, http.requests[1].url, "it retried the same host")
    }

    func testAFetchThatNeverSucceedsSaysHowHardItTried() async throws {
        let http = StubHTTP(responses: [])
        var settings = unpaced
        settings.maxRetries = 2

        do {
            _ = try await OverpassProvider(settings: settings, http: http).fetch(query)
            XCTFail("a fetch that never succeeded must not return a map")
        } catch let error as OverpassRequestError {
            XCTAssertEqual(error.attempts, 2)
            XCTAssertEqual(error.endpoints, 4)
        }
    }

    func testEndpointsAreDeduplicatedAndBlanksDropped() {
        var settings = OverpassSettings()
        settings.endpoint = "https://a.example/api"
        settings.fallbackEndpoints = ["  ", "https://a.example/api", "https://b.example/api"]
        XCTAssertEqual(settings.candidateEndpoints, ["https://a.example/api", "https://b.example/api"])
    }

    // MARK: - Warning before an expensive fetch

    /// Kickoff detail 13: 325 s of a 331 s fetch was this one source.
    func testALargeFullLayerAreaWarnsBeforeTheWait() {
        let large = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)
        XCTAssertTrue(FetchCost.shouldWarn(bbox: large, layers: []))
        XCTAssertTrue(FetchCost.warning(bbox: large).contains("minute"))
    }

    func testASmallAreaOrANarrowRequestDoesNotWarn() {
        let small = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)
        XCTAssertFalse(FetchCost.shouldWarn(bbox: small, layers: []))

        let large = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)
        XCTAssertFalse(
            FetchCost.shouldWarn(bbox: large, layers: ["roads"]),
            "most of that measured wait was layers nobody asked for"
        )
    }
}

final class CacheStoreTests: XCTestCase {

    func testAStoredValueComesBack() async {
        let cache = MemoryCacheStore()
        await cache.store(Data("hello".utf8), for: "k")
        let stored = await cache.data(for: "k")
        let missing = await cache.data(for: "other")
        XCTAssertEqual(stored, Data("hello".utf8))
        XCTAssertNil(missing)
    }

    func testTheOldestEntryIsEvictedFirst() async {
        let cache = MemoryCacheStore(limit: 2)
        await cache.store(Data("1".utf8), for: "a")
        await cache.store(Data("2".utf8), for: "b")
        // Touching "a" makes "b" the least recently used.
        _ = await cache.data(for: "a")
        await cache.store(Data("3".utf8), for: "c")

        let a = await cache.data(for: "a")
        let b = await cache.data(for: "b")
        let c = await cache.data(for: "c")
        XCTAssertNotNil(a)
        XCTAssertNil(b, "the least recently used entry should have gone")
        XCTAssertNotNil(c)
    }

    func testDiskCacheRoundTripsAndExpires() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hipparchus-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = DiskCacheStore(directory: directory)
        // A key with commas, colons and a signed longitude — none of which belong in
        // a path, which is why keys are hashed.
        let key = "overpass:bbox:-122.530000,37.700000:layers:roads"
        await cache.store(Data("payload".utf8), for: key)
        let roundTripped = await cache.data(for: key)
        let bytes = await cache.totalBytes()
        XCTAssertEqual(roundTripped, Data("payload".utf8))
        XCTAssertGreaterThan(bytes, 0)

        let expired = DiskCacheStore(directory: directory, maximumAge: -1)
        let stale = await expired.data(for: key)
        XCTAssertNil(stale, "a stale entry must read as absent")
    }
}
