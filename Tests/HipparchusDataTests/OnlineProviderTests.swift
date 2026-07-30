import CoreGraphics
import Foundation
import ImageIO
import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Answers GET requests from memory and records the URLs asked for.
private final class StubGET: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private var _responses: [Result<Data, any Error>]

    init(responses: [Result<Data, any Error>]) {
        self._responses = responses
    }

    convenience init(_ text: String) {
        self.init(responses: [.success(Data(text.utf8))])
    }

    convenience init(data: Data) {
        self.init(responses: [.success(data)])
    }

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

private func queryItems(_ url: URL) -> [String: String] {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    return Dictionary(
        (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first }
    )
}

// MARK: - USGS

final class USGSProviderTests: XCTestCase {

    private let query = BBoxQuery(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)

    /// Two events at different depths and magnitudes, plus one that cannot be read.
    private let catalogue = """
        {"features": [
          {"id": "us1", "geometry": {"type": "Point", "coordinates": [23.5, 36.7, 12.0]},
           "properties": {"mag": 5.4, "place": "Aegean Sea", "time": 1750000000000,
                          "url": "https://example.invalid/us1"}},
          {"id": "us2", "geometry": {"type": "Point", "coordinates": [23.9, 36.9, 150.0]},
           "properties": {"mag": 3.1, "place": "Peloponnese", "time": 1750000001000}},
          {"id": "us3", "geometry": {"type": "Point", "coordinates": [23.7, 36.5, 420.0]},
           "properties": {"mag": 4.8, "place": "Deep", "time": 1750000002000}},
          {"id": "broken", "geometry": {"type": "Point", "coordinates": [23.7]},
           "properties": {"mag": 9.9}}
        ]}
        """

    private func provider(_ http: StubGET) -> USGSEarthquakeProvider {
        USGSEarthquakeProvider(http: http, now: { Date(timeIntervalSince1970: 1_780_000_000) })
    }

    /// Depth reads through styling, so it has to be a layer rather than a property
    /// nobody sees.
    func testEventsAreSplitIntoTheStandardDepthClasses() async throws {
        let collection = try await provider(StubGET(catalogue)).fetch(query)

        XCTAssertEqual(collection.features(in: EarthquakeLayer.shallow).count, 1)
        XCTAssertEqual(collection.features(in: EarthquakeLayer.intermediate).count, 1)
        XCTAssertEqual(collection.features(in: EarthquakeLayer.deep).count, 1)
        XCTAssertEqual(collection.metadata["event_count"]?.doubleValue, 3, "the unreadable event was counted")
    }

    /// Nothing in the renderer can draw a point, so an epicentre becomes a circle.
    func testAnEventBecomesACircleScaledByMagnitude() async throws {
        let collection = try await provider(StubGET(catalogue)).fetch(query)
        let strong = try XCTUnwrap(collection.features(in: EarthquakeLayer.shallow).first)

        guard case .polygon(let polygon) = strong.geometry else {
            return XCTFail("an epicentre must be editable vector artwork, not a point")
        }
        XCTAssertGreaterThan(polygon.exterior.coordinates.count, 24)

        // A stronger event draws a bigger circle.
        let deep = try XCTUnwrap(collection.features(in: EarthquakeLayer.deep).first)
        guard case .polygon(let smaller) = deep.geometry else { return XCTFail("not a polygon") }
        let strongWidth = try XCTUnwrap(polygon.bounds).width
        let weakWidth = try XCTUnwrap(smaller.bounds).width
        XCTAssertGreaterThan(strongWidth, weakWidth, "M5.4 must draw larger than M4.8")
    }

    /// A degree of longitude is shorter than a degree of latitude everywhere but the
    /// equator, so an uncorrected buffer draws every epicentre as a flattened ellipse.
    func testCirclesAreRoundOnTheMapNotRoundInDegrees() throws {
        let provider = USGSEarthquakeProvider()
        let ring = provider.circleRing(lon: 0, lat: 60, radiusDegrees: 1.0)
        let bounds = try XCTUnwrap(Bounds(ring))

        // At 60° north a degree of longitude is half a degree of latitude, so the
        // ring must be about twice as wide in degrees to come out round on the map.
        XCTAssertEqual(bounds.width / bounds.height, 2.0, accuracy: 0.1)
    }

    /// A swarm of small events would otherwise bury the map in text.
    func testOnlyEventsWorthNamingCarryALabel() async throws {
        let collection = try await provider(StubGET(catalogue)).fetch(query)
        let named = EarthquakeLayer.all
            .flatMap { collection.features(in: $0) }
            .compactMap { $0.property("name")?.stringValue }
            .filter { !$0.isEmpty }
        // M5.4 and M4.8 clear the 4.0 floor; M3.1 does not.
        XCTAssertEqual(Set(named), ["M 5.4", "M 4.8"])
    }

    func testTheRequestAsksForTheRightWindowAndArea() async throws {
        let http = StubGET(catalogue)
        _ = try await provider(http).fetch(query)

        let items = queryItems(try XCTUnwrap(http.urls.first))
        XCTAssertEqual(items["format"], "geojson")
        XCTAssertEqual(items["minlongitude"], "23.200000")
        XCTAssertEqual(items["maxlatitude"], "37.100000")
        XCTAssertEqual(items["minmagnitude"], "2.5")
        // Strongest first, so a truncated answer keeps the events that matter.
        XCTAssertEqual(items["orderby"], "magnitude")
    }

    func testAnUnreachableServiceIsAnErrorRatherThanAnEmptyMap() async {
        let http = StubGET(responses: [.failure(StubError())])
        do {
            _ = try await provider(http).fetch(query)
            XCTFail("a failed request must not look like a quiet area")
        } catch is SeismicityRequestError {
            // Correct: the map should say the source failed.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Satellites

final class SatelliteProviderTests: XCTestCase {

    private let query = BBoxQuery(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)
    private let listing = """
        ISS (ZARYA)
        1 25544U 98067A   26209.15252568  .00010831  00000+0  20282-3 0  9992
        2 25544  51.6320  97.3682 0007093 345.6120  14.4666 15.49220842578109
        """

    private func provider(_ http: StubGET, cache: any CacheStoring = MemoryCacheStore())
        -> SatelliteTrackProvider {
        SatelliteTrackProvider(
            http: http, cache: cache, now: { Date(timeIntervalSince1970: 1_785_000_000) }
        )
    }

    func testATrackAndItsFootprintAreBothDrawn() async throws {
        let collection = try await provider(StubGET(listing)).fetch(query)

        XCTAssertGreaterThanOrEqual(collection.features(in: SatelliteLayer.tracks).count, 1)
        XCTAssertEqual(collection.features(in: SatelliteLayer.footprints).count, 1)

        let track = try XCTUnwrap(collection.features(in: SatelliteLayer.tracks).first)
        guard case .lineString(let line) = track.geometry else { return XCTFail("not a line") }
        XCTAssertGreaterThan(line.coordinates.count, 10)

        guard case .polygon = collection.features(in: SatelliteLayer.footprints).first?.geometry else {
            return XCTFail("a footprint is the circle of ground that can see the satellite")
        }
    }

    /// This is not SGP4, and a map that implies otherwise is a lie.
    func testTracksDeclareThemselvesApproximate() async throws {
        let collection = try await provider(StubGET(listing)).fetch(query)
        XCTAssertEqual(collection.provenance, .approximate)
        XCTAssertEqual(collection.metadata["propagator"]?.stringValue, "keplerian_j2_secular")
        XCTAssertTrue(
            collection.features(in: SatelliteLayer.tracks).allSatisfy { $0.provenance == .approximate }
        )
    }

    /// A track split at the antimeridian must not be labelled twice.
    func testOnlyTheFirstRunOfASatelliteIsNamed() async throws {
        let collection = try await provider(StubGET(listing)).fetch(query)
        let named = collection.features(in: SatelliteLayer.tracks)
            .compactMap { $0.property("name")?.stringValue }
            .filter { !$0.isEmpty }
        XCTAssertEqual(named, ["ISS (ZARYA)"])
    }

    /// Celestrak asks that clients cache.
    func testElementSetsAreFetchedOnceAndReused() async throws {
        let http = StubGET(responses: [.success(Data(listing.utf8))])
        let cache = MemoryCacheStore()

        _ = try await provider(http, cache: cache).fetch(query)
        _ = try await provider(http, cache: cache).fetch(query)
        XCTAssertEqual(http.urls.count, 1, "the second fetch went back to Celestrak")
    }

    func testAListingWithNoReadableElementsIsAnError() async {
        do {
            _ = try await provider(StubGET("nothing useful here")).fetch(query)
            XCTFail("an unreadable listing must not draw an empty sky silently")
        } catch is SatelliteTrackError {
            // Correct.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAFootprintNearThePoleDoesNotFoldOverTheTop() {
        let provider = SatelliteTrackProvider()
        let circle = provider.smallCircle(
            centre: Coordinate(lon: 10, lat: 88), radiusDegrees: 20, segments: 36
        )
        XCTAssertTrue(circle.allSatisfy { $0.lat <= 90 && $0.lat >= -90 })
        XCTAssertTrue(circle.allSatisfy { $0.lon >= -180 && $0.lon <= 180 })
    }
}

// MARK: - GIBS

final class GIBSProviderTests: XCTestCase {

    private let query = BBoxQuery(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)

    /// A PNG with a bright blob in the middle, so there is a real gradient to trace.
    private func imageData(width: Int = 64, height: Int = 64) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let dx = Double(column - width / 2) / Double(width / 2)
                let dy = Double(row - height / 2) / Double(height / 2)
                let brightness = Swift.max(0, 1 - (dx * dx + dy * dy).squareRoot())
                let value = UInt8(brightness * 255)
                let offset = (row * width + column) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }

        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// **Kickoff detail 1.** WMS 1.3.0 with EPSG:4326 orders BBOX `lat,lon`.
    /// Reversing it silently returns imagery of somewhere else.
    func testTheWMSBoundingBoxIsLatitudeFirst() throws {
        let url = try XCTUnwrap(
            GIBSImageryProvider().requestURL(bbox: query.bbox, width: 100, height: 80)
        )
        let items = queryItems(url)

        XCTAssertEqual(items["VERSION"], "1.3.0")
        XCTAssertEqual(items["CRS"], "EPSG:4326")
        XCTAssertEqual(
            items["BBOX"], "36.3,23.2,37.1,24.2",
            "BBOX must read minLat,minLon,maxLat,maxLon — reversing it fetches the wrong place"
        )
    }

    func testTheImageMatchesTheAreaAspect() {
        // A wide area asks for a wide image.
        let wide = GIBSImageryProvider.imageSize(
            bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 4, maxLat: 1), maxPixels: 1000
        )
        XCTAssertEqual(wide.width, 1000)
        XCTAssertEqual(wide.height, 250)

        let tall = GIBSImageryProvider.imageSize(
            bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 4), maxPixels: 1000
        )
        XCTAssertEqual(tall.width, 250)
        XCTAssertEqual(tall.height, 1000)
    }

    func testBrightnessIsContouredIntoEditableIsoLines() async throws {
        let collection = try await GIBSImageryProvider(http: StubGET(data: try imageData()))
            .fetch(query)

        let contours = collection.features(in: NightLightsLayer.name)
        XCTAssertGreaterThan(contours.count, 3, "a blob with a gradient must yield iso-lines")
        for feature in contours {
            guard case .lineString(let line) = feature.geometry else {
                return XCTFail("night lights are lines, not fills")
            }
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
        }
    }

    /// The whole reason this source declares `uncalibrated`.
    func testTheOutputSaysItIsBrightnessRatherThanRadiance() async throws {
        let collection = try await GIBSImageryProvider(http: StubGET(data: try imageData()))
            .fetch(query)
        XCTAssertEqual(collection.provenance, .uncalibrated)
        XCTAssertTrue(collection.metadata["calibration"]?.stringValue?.contains("not radiance") == true)
    }

    /// GIBS returns transient 500s; one failure must not end the fetch.
    func testATransientFailureIsRetried() async throws {
        let http = StubGET(responses: [
            .failure(HTTPError(url: URL(string: "https://example.invalid")!, statusCode: 500)),
            .success(try imageData()),
        ])
        var settings = SatelliteImagerySettings()
        settings.retryDelay = .milliseconds(1)

        let collection = try await GIBSImageryProvider(settings: settings, http: http).fetch(query)
        XCTAssertEqual(http.urls.count, 2)
        XCTAssertFalse(collection.features(in: NightLightsLayer.name).isEmpty)
    }

    func testAResponseThatIsNotAnImageIsReported() async {
        var settings = SatelliteImagerySettings()
        settings.retryDelay = .milliseconds(1)
        settings.maxAttempts = 1

        do {
            _ = try await GIBSImageryProvider(settings: settings, http: StubGET("<html>error</html>"))
                .fetch(query)
            XCTFail("a text error page must not be contoured as imagery")
        } catch is SatelliteImageryError {
            // Correct.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// GIBS uses transparency for "no data". Treating it as black ground would draw
    /// a bright coastline around every gap in the mosaic.
    func testTransparentPixelsAreNoDataRatherThanBlackGround() throws {
        var pixels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for index in 0..<16 {
            let offset = index * 4
            pixels[offset] = 200
            pixels[offset + 1] = 200
            pixels[offset + 2] = 200
            // Only the first row is opaque.
            pixels[offset + 3] = index < 4 ? 255 : 0
        }

        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let grid = try GIBSImageryProvider.luminanceGrid(output as Data)
        XCTAssertEqual(grid.values.filter(\.isNaN).count, 12, "transparent pixels must read as no data")
        XCTAssertEqual(grid.values.filter(\.isFinite).count, 4)
    }

    /// A level at the exact minimum or maximum traces the frame edge, not the picture.
    func testLevelsSitStrictlyInsideTheRange() {
        let levels = GIBSImageryProvider.levels(between: 0, and: 100, count: 3)
        XCTAssertEqual(levels, [25, 50, 75])
        XCTAssertTrue(GIBSImageryProvider.levels(between: 5, and: 5, count: 4).isEmpty)
    }
}
