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

    // MARK: - Refused outright, not merely warned about

    /// A locator that can be panned to the whole world makes it an easy
    /// accident to ask Overpass for the entire planet. Above this size there
    /// is no legitimate single query, and the shared public service should
    /// not be asked to try — a warning that can be clicked through is not
    /// enough here.
    func testAnAbsurdlyLargeAreaIsRefusedOutright() {
        let planet = BoundingBox(minLon: -180, minLat: -85, maxLon: 180, maxLat: 85)
        XCTAssertTrue(FetchCost.isTooLargeToFetch(bbox: planet))
        XCTAssertTrue(FetchCost.refusalMessage(bbox: planet).lowercased().contains("too large"))
    }

    func testACountrySizedAreaIsNotRefusedOnlyWarned() {
        // Roughly metropolitan France — large, and a legitimate (if slow)
        // single query, not something to refuse outright.
        let france = BoundingBox(minLon: -5.0, minLat: 42.3, maxLon: 8.3, maxLat: 51.1)
        XCTAssertFalse(FetchCost.isTooLargeToFetch(bbox: france))
        XCTAssertTrue(FetchCost.shouldWarn(bbox: france, layers: []), "still large enough to warn about")
    }

    func testTheRefusalThresholdIsWellAboveTheWarningThreshold() {
        XCTAssertGreaterThan(FetchCost.refuseAboveSquareDegrees, FetchCost.warnAboveSquareDegrees * 100)
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

// MARK: - The rate limiter

/// The public Overpass instances are shared and unmetered, so this port has to
/// be a good citizen of them without being told.
final class RateLimiterTests: XCTestCase {

    /// The first caller goes straight through — a limiter that made everyone wait
    /// would add its interval to every fetch for nothing.
    func testTheFirstTurnIsNotDelayed() async {
        let limiter = RateLimiter(requestsPerSecond: 2)
        let started = ContinuousClock.now
        await limiter.waitTurn()
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(50))
    }

    /// The second is spaced by the configured interval.
    func testCallsAreSpacedByTheConfiguredRate() async {
        let limiter = RateLimiter(requestsPerSecond: 20)
        let started = ContinuousClock.now
        await limiter.waitTurn()
        await limiter.waitTurn()

        // Twenty a second is one every fifty milliseconds; the margin is for a
        // sleep that may wake slightly early.
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(45))
    }

    /// Concurrent callers queue behind one another rather than all going at once
    /// — the point of the limiter being an actor rather than a per-caller wait.
    func testConcurrentCallersAreSpacedToo() async {
        let limiter = RateLimiter(requestsPerSecond: 20)
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { await limiter.waitTurn() }
            }
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(90))
    }

    /// A nonsensical rate must not divide by zero and hang for ever.
    func testAnImpossibleRateIsClampedRatherThanHanging() async {
        let limiter = RateLimiter(requestsPerSecond: 0)
        let started = ContinuousClock.now
        await limiter.waitTurn()
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(50))
    }
}

/// Relations are 1 097 of the elements in an Athens fetch — mostly buildings with
/// courtyards, plus the Aegean Sea. They used to be dropped outright, because
/// `out geom` resolves each member way's vertices without joining any of them up.
final class OverpassRelationTests: XCTestCase {

    private func payload(_ elements: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"elements": [\#(elements)]}"#.utf8))
                as? [String: Any]
        )
    }

    private func node(_ lon: Double, _ lat: Double) -> String {
        #"{"lat": \#(lat), "lon": \#(lon)}"#
    }

    /// One outer way, already closed — 838 of the 1 097 arrive this way.
    func testARelationWithOneClosedOuterWayBecomesAPolygon() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 1, "tags": {"building": "yes", "type": "multipolygon"},
             "members": [{"type": "way", "ref": 10, "role": "outer", "geometry": [
               \(node(0, 0)), \(node(4, 0)), \(node(4, 4)), \(node(0, 4)), \(node(0, 0))]}]}
            """))

        let buildings = collection.features(in: "buildings")
        XCTAssertEqual(buildings.count, 1, "the relation was dropped")
        guard case .polygon(let polygon) = buildings.first?.geometry else {
            return XCTFail("a multipolygon relation must be an area")
        }
        XCTAssertTrue(polygon.holes.isEmpty)
    }

    /// The courtyard case, which is most of what these relations are for.
    func testInnerMembersBecomeHoles() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 2, "tags": {"building": "museum", "type": "multipolygon"},
             "members": [
               {"type": "way", "ref": 10, "role": "outer", "geometry": [
                 \(node(0, 0)), \(node(10, 0)), \(node(10, 10)), \(node(0, 10)), \(node(0, 0))]},
               {"type": "way", "ref": 11, "role": "inner", "geometry": [
                 \(node(2, 2)), \(node(4, 2)), \(node(4, 4)), \(node(2, 4)), \(node(2, 2))]}
             ]}
            """))

        guard case .polygon(let polygon) = collection.features(in: "buildings").first?.geometry else {
            return XCTFail("not a polygon")
        }
        XCTAssertEqual(polygon.holes.count, 1, "the courtyard was filled in")
    }

    /// 259 of the 1 097 arrive as fragments that have to be stitched.
    func testFragmentedOuterWaysAreStitchedIntoOneRing() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 3, "tags": {"natural": "water", "type": "multipolygon"},
             "members": [
               {"type": "way", "ref": 10, "role": "outer", "geometry": [\(node(0, 0)), \(node(4, 0))]},
               {"type": "way", "ref": 11, "role": "outer", "geometry": [\(node(4, 4)), \(node(4, 0))]},
               {"type": "way", "ref": 12, "role": "outer", "geometry": [\(node(4, 4)), \(node(0, 4))]},
               {"type": "way", "ref": 13, "role": "outer", "geometry": [\(node(0, 4)), \(node(0, 0))]}
             ]}
            """))

        guard case .polygon(let polygon) = collection.features(in: "water").first?.geometry else {
            return XCTFail("the fragments were never joined")
        }
        XCTAssertEqual(abs(polygon.exterior.signedDoubleArea) / 2, 16, accuracy: 1e-9)
    }

    /// A relation may enclose more than one shape — an archipelago, or the Aegean.
    func testSeveralOuterRingsBecomeAMultiPolygon() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 4, "tags": {"place": "sea", "type": "multipolygon"},
             "members": [
               {"type": "way", "ref": 10, "role": "outer", "geometry": [
                 \(node(0, 0)), \(node(1, 0)), \(node(1, 1)), \(node(0, 1)), \(node(0, 0))]},
               {"type": "way", "ref": 11, "role": "outer", "geometry": [
                 \(node(5, 5)), \(node(6, 5)), \(node(6, 6)), \(node(5, 6)), \(node(5, 5))]}
             ]}
            """))

        guard case .multiPolygon(let polygons) = collection.features(in: "coastline").first?.geometry else {
            return XCTFail("two rings must be a multipolygon")
        }
        XCTAssertEqual(polygons.count, 2)
    }

    /// The OSM data model says a member with no role is outer, and relations with
    /// the role left blank are common enough to matter.
    func testAMemberWithNoRoleCountsAsOuter() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 5, "tags": {"landuse": "forest", "type": "multipolygon"},
             "members": [{"type": "way", "ref": 10, "role": "", "geometry": [
               \(node(0, 0)), \(node(2, 0)), \(node(2, 2)), \(node(0, 2)), \(node(0, 0))]}]}
            """))
        XCTAssertEqual(collection.features(in: "forests").count, 1)
    }

    /// Broken relations exist. Losing the edges as well as the area is worse.
    func testARelationThatNeverClosesStillDrawsItsEdges() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 6, "tags": {"natural": "water", "type": "multipolygon"},
             "members": [
               {"type": "way", "ref": 10, "role": "outer", "geometry": [\(node(0, 0)), \(node(4, 0))]},
               {"type": "way", "ref": 11, "role": "outer", "geometry": [\(node(4, 0)), \(node(4, 4))]}
             ]}
            """))

        let water = collection.features(in: "water")
        XCTAssertEqual(water.count, 1, "a broken relation should not vanish")
        guard case .lineString = water.first?.geometry else {
            return XCTFail("an unclosed relation must not claim to be an area")
        }
    }

    func testARelationWithNoUsableMembersIsSkipped() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 7, "tags": {"building": "yes"}, "members": [
              {"type": "node", "ref": 99, "role": "label"}]}
            """))
        XCTAssertTrue(collection.features(in: "buildings").isEmpty)
    }

    /// Node members carry no geometry and must not be mistaken for a ring.
    func testNodeMembersAreIgnoredRatherThanBreakingTheRing() throws {
        let collection = OverpassDecode.featureCollection(from: try payload("""
            {"type": "relation", "id": 8, "tags": {"building": "yes", "type": "multipolygon"},
             "members": [
               {"type": "node", "ref": 99, "role": "label"},
               {"type": "way", "ref": 10, "role": "outer", "geometry": [
                 \(node(0, 0)), \(node(4, 0)), \(node(4, 4)), \(node(0, 4)), \(node(0, 0))]}
             ]}
            """))
        guard case .polygon = collection.features(in: "buildings").first?.geometry else {
            return XCTFail("a label node broke the assembly")
        }
    }
}

/// A shipping lane is not a body of water.
///
/// OSM tags the Piraeus–Serifos ferry `waterway=seaway`, so any rule keyed on the
/// presence of a `waterway` tag drew an 80-kilometre crossing of the Saronic Gulf
/// as if it were a river. A deliberate divergence from the Python, which reads the
/// same tag the same way.
final class FerryRouteClassificationTests: XCTestCase {

    private func layer(_ tags: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(tags.utf8)) as? [String: Any]
        return OverpassDecode.classify(tags: object ?? [:])
    }

    /// The real way from an Athens fetch, tagged as OSM tags it.
    func testTheFerryRouteLeavesTheWaterLayer() {
        XCTAssertEqual(
            layer(#"{"route": "ferry", "waterway": "seaway", "name": "Πειραιάς - Σέριφος"}"#),
            "ferry_routes"
        )
    }

    func testEitherTagOnItsOwnIsEnough() {
        XCTAssertEqual(layer(#"{"route": "ferry"}"#), "ferry_routes")
        XCTAssertEqual(layer(#"{"waterway": "seaway"}"#), "ferry_routes")
        XCTAssertEqual(layer(#"{"waterway": "fairway"}"#), "ferry_routes")
    }

    /// Narrow on purpose. An Athens fetch holds 852 streams, 121 canals, 54 rivers,
    /// 43 ditches and 39 drains, and every one of them is water.
    func testWatercoursesStayInTheWaterLayer() {
        for waterway in ["stream", "canal", "river", "ditch", "drain", "dam", "weir", "dock"] {
            XCTAssertEqual(layer(#"{"waterway": "\#(waterway)"}"#), "water", waterway)
        }
        XCTAssertEqual(layer(#"{"natural": "water"}"#), "water")
        XCTAssertEqual(layer(#"{"landuse": "reservoir"}"#), "water")
    }

    /// A road that happens to carry a ferry is still a road.
    func testAMoreSpecificTagStillWins() {
        XCTAssertEqual(layer(#"{"highway": "unclassified", "route": "ferry"}"#), "roads")
        XCTAssertEqual(layer(#"{"railway": "rail", "route": "ferry"}"#), "railways")
    }

    /// A route tagged only `route=ferry` has no `waterway` at all, so the water
    /// query would never have returned it.
    func testTheLayerIsAskedForInItsOwnRight() {
        let text = OverpassQuery.build(BBoxQuery(
            bbox: BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 23.9, maxLat: 38.1),
            layers: ["ferry_routes"]
        ))
        XCTAssertTrue(text.contains(#"way["route"="ferry"]"#))
        XCTAssertFalse(text.contains(#"way["highway"]"#), "only the layer asked for")
    }

    func testTheLayerIsListedSoItCanSayNoneHere() {
        let collection = OverpassDecode.featureCollection(from: ["elements": []])
        XCTAssertTrue(collection.layerNames.contains("ferry_routes"))
        XCTAssertTrue(collection.features(in: "ferry_routes").isEmpty)
    }

    /// End to end: the ferry lands in its own layer and the stream stays put.
    func testAFerryAndAStreamPartCompany() throws {
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"""
            {"elements": [
              {"type": "way", "id": 1, "tags": {"route": "ferry", "waterway": "seaway"},
               "geometry": [{"lat": 37.94, "lon": 23.64}, {"lat": 37.14, "lon": 24.52}]},
              {"type": "way", "id": 2, "tags": {"waterway": "stream"},
               "geometry": [{"lat": 38.0, "lon": 23.7}, {"lat": 38.01, "lon": 23.71}]}
            ]}
            """#.utf8)) as? [String: Any]
        )
        let collection = OverpassDecode.featureCollection(from: payload)

        XCTAssertEqual(collection.features(in: "ferry_routes").count, 1)
        XCTAssertEqual(collection.features(in: "water").count, 1)
        XCTAssertEqual(collection.features(in: "water").first?.property("waterway")?.stringValue, "stream")
    }
}
