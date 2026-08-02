import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Ported from `ZoomChoiceTests`, `FetchTests` and `MercatorSanityTests` in
/// `tests/test_terrain_tiles.py`.
///
/// Every test here is offline. Tiles are synthesised in-process and handed to the
/// provider through an injected `HTTPFetching`, which is the same arrangement the
/// Python uses with its injectable `http_get`.

let athens = BBoxQuery(minLon: 23.57, minLat: 37.81, maxLon: 23.89, maxLat: 38.13)

/// A tile rising smoothly west to east, 0 m to 1000 m.
func rampTileData(from low: Double = 0.0, to high: Double = 1000.0) -> Data {
    let size = WebMercator.tilePixels
    let ramp = linspace(low, high, size)
    let field = Field2D(rows: size, columns: size) { _, column in ramp[column] }
    return encodeTerrariumPNG(field)!
}

/// Serves one payload for every request, and records what was asked for.
final class StubFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []
    private let respond: @Sendable (URL, Int) async throws -> Data

    init(respond: @escaping @Sendable (URL, Int) async throws -> Data) {
        self.respond = respond
    }

    convenience init(alwaysReturning data: @autoclosure @escaping @Sendable () -> Data) {
        self.init(respond: { _, _ in data() })
    }

    var urls: [URL] {
        lock.withLock { requested }
    }

    var callCount: Int {
        lock.withLock { requested.count }
    }

    func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        let index = lock.withLock {
            requested.append(url)
            return requested.count
        }
        return try await respond(url, index)
    }
}

/// Settings sized for plumbing, not for fidelity.
///
/// Most of these tests are about policy — which layer a feature lands in, what the
/// metadata claims, whether a missing tile is fatal — and none of that depends on
/// grid resolution. A small grid and a coarse interval keep the suite quick in a
/// debug build, where Swift's unoptimised numeric loops run roughly fifty times
/// slower than release.
///
/// Numerical fidelity is pinned elsewhere and at full resolution:
/// `ContourParityTests` and `BandParityTests` compare against the Python itself,
/// and `testTheProviderWorksAtRealisticResolution` runs this provider at the size
/// it will actually face so the fast defaults cannot hide a size-dependent bug.
private func testSettings(_ mutate: (inout TerrainTileSettings) -> Void = { _ in }) -> TerrainTileSettings {
    var settings = TerrainTileSettings()
    settings.maxTiles = 4
    settings.targetPixels = 160
    settings.targetLineCount = 12
    // Tests must not spend real seconds in retry backoff.
    settings.retryDelaySeconds = 0
    mutate(&settings)
    return settings
}

/// The resolution a real fetch of this area uses.
private func realisticSettings(_ mutate: (inout TerrainTileSettings) -> Void = { _ in }) -> TerrainTileSettings {
    var settings = TerrainTileSettings()
    settings.maxTiles = 8
    settings.targetPixels = 512
    settings.retryDelaySeconds = 0
    mutate(&settings)
    return settings
}

final class ZoomChoiceTests: XCTestCase {

    func testASmallAreaIsSampledMoreFinelyThanALargeOne() {
        let city = chooseZoom(
            bounds: BoundingBox(minLon: 23.70, minLat: 37.95, maxLon: 23.80, maxLat: 38.02),
            settings: TerrainTileSettings()
        )
        let region = chooseZoom(
            bounds: BoundingBox(minLon: 20.0, minLat: 34.0, maxLon: 29.0, maxLat: 41.0),
            settings: TerrainTileSettings()
        )
        XCTAssertGreaterThan(city, region)
    }

    func testTheTileBudgetIsRespected() {
        var settings = TerrainTileSettings()
        settings.maxTiles = 4
        let bounds = BoundingBox(minLon: 23.0, minLat: 37.0, maxLon: 24.0, maxLat: 38.0)
        let zoom = chooseZoom(bounds: bounds, settings: settings)
        let topLeft = WebMercator.tile(lon: bounds.minLon, lat: bounds.maxLat, zoom: zoom)
        let bottomRight = WebMercator.tile(lon: bounds.maxLon, lat: bounds.minLat, zoom: zoom)
        XCTAssertLessThanOrEqual((bottomRight.x - topLeft.x + 1) * (bottomRight.y - topLeft.y + 1), 4)
    }
}

final class TerrainFetchTests: XCTestCase {

    private func provider(
        _ settings: TerrainTileSettings? = nil,
        fetcher: StubFetcher? = nil
    ) -> (TerrainTileProvider, StubFetcher) {
        let stub = fetcher ?? StubFetcher(alwaysReturning: rampTileData())
        return (TerrainTileProvider(settings: settings ?? testSettings(), http: stub), stub)
    }

    func testContoursAreProducedFromRealMetres() async throws {
        let (provider, _) = provider()
        let result = try await provider.fetch(athens)
        let features = result.features(in: TerrainLayer.minorContours)
        XCTAssertFalse(features.isEmpty)
        for feature in features {
            XCTAssertEqual(feature.geometry.typeName, "LineString")
            XCTAssertEqual(feature.provenance, .measured)
        }
    }

    func testMetadataReportsMeasuredGround() async throws {
        let (provider, _) = provider()
        let metadata = try await provider.fetch(athens).metadata
        XCTAssertEqual(metadata["measured"]?.boolValue, true)
        XCTAssertEqual(metadata["source"]?.stringValue, "terrain_tiles")
        XCTAssertEqual(metadata["provenance"]?.stringValue, "measured")
        XCTAssertNotNil(metadata["zoom"])
        let low = try XCTUnwrap(metadata["elevation_min_metres"]?.doubleValue)
        let high = try XCTUnwrap(metadata["elevation_max_metres"]?.doubleValue)
        XCTAssertGreaterThan(high, low)
    }

    func testTheCollectionDeclaresItsProvenance() async throws {
        let (provider, _) = provider()
        let collection = try await provider.fetch(athens)
        XCTAssertEqual(collection.provenance, .measured)
    }

    /// A surface model, said out loud in the diagnostics, because a rooftop
    /// "summit" is otherwise a bug report.
    func testTheElevationModelIsDeclaredASurfaceModel() async throws {
        let (provider, _) = provider()
        let metadata = try await provider.fetch(athens).metadata
        XCTAssertEqual(metadata["elevation_model"]?.stringValue, "surface")
    }

    func testContoursStayInsideTheArea() async throws {
        let (provider, _) = provider()
        let result = try await provider.fetch(athens)
        for feature in result.features(in: TerrainLayer.minorContours).prefix(40) {
            for point in feature.geometry.lineStrings.flatMap(\.coordinates) {
                XCTAssertGreaterThanOrEqual(point.lon, athens.bbox.minLon - 0.01)
                XCTAssertLessThanOrEqual(point.lon, athens.bbox.maxLon + 0.01)
                XCTAssertGreaterThanOrEqual(point.lat, athens.bbox.minLat - 0.01)
                XCTAssertLessThanOrEqual(point.lat, athens.bbox.maxLat + 0.01)
            }
        }
    }

    func testElevationsSitOnTheContourInterval() async throws {
        let (provider, _) = provider()
        let result = try await provider.fetch(athens)
        let interval = try XCTUnwrap(result.metadata["contour_interval_metres"]?.doubleValue)
        for feature in result.features(in: TerrainLayer.minorContours) {
            let elevation = try XCTUnwrap(feature.property("elevation")?.doubleValue)
            XCTAssertEqual(elevation.truncatingRemainder(dividingBy: interval), 0.0, accuracy: 1e-6)
        }
    }

    func testTheURLTemplateIsFilledIn() async throws {
        let (provider, stub) = provider()
        _ = try await provider.fetch(athens)

        // Two kinds of request leave this provider now: the terrarium tiles, and
        // — inside European waters, which Athens is — one coverage request for
        // the finer sea floor. Only the first kind is filled in from a template.
        let tiles = stub.urls.filter { $0.absoluteString.contains("/terrarium/") }
        XCTAssertFalse(tiles.isEmpty)
        for url in tiles {
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(url.absoluteString.hasSuffix(".png"))
            XCTAssertFalse(url.absoluteString.contains("{z}"))
            XCTAssertFalse(url.absoluteString.contains("{x}"))
            XCTAssertFalse(url.absoluteString.contains("{y}"))
        }
    }

    /// The bathymetry request goes out for European water and not elsewhere.
    ///
    /// A frame outside the coverage must cost nothing — no round trip, and no
    /// error document to be mistaken for a coverage.
    func testTheCoverageIsAskedForOnlyWhereItExists() async throws {
        let (european, europeanStub) = provider()
        _ = try await european.fetch(athens)
        XCTAssertTrue(
            europeanStub.urls.contains { $0.absoluteString.contains("emodnet") },
            "Athens is in European waters and should have been asked about"
        )

        let (pacific, pacificStub) = provider()
        _ = try? await pacific.fetch(BBoxQuery(
            bbox: BoundingBox(minLon: -157.0, minLat: 19.5, maxLon: -156.8, maxLat: 19.7)
        ))
        XCTAssertFalse(
            pacificStub.urls.contains { $0.absoluteString.contains("emodnet") },
            "Hawaii is not in EMODnet's coverage and should not have been asked about"
        )
    }

    /// One unavailable tile must not lose the rest of the area.
    ///
    /// Needs the multi-tile settings to mean anything: with a single-tile area,
    /// one missing tile *is* every missing tile, which is the next test.
    func testAMissingTileLeavesAHoleRatherThanFailing() async throws {
        let stub = StubFetcher { _, index in
            if index == 1 { throw HTTPError(url: URL(string: "https://example.invalid")!, statusCode: 404) }
            return rampTileData()
        }
        let (provider, _) = provider(realisticSettings { $0.maxAttempts = 1 }, fetcher: stub)
        let result = try await provider.fetch(athens)
        XCTAssertGreaterThan(stub.callCount, 1, "the area must need several tiles for this to be a hole and not a total loss")
        XCTAssertFalse(result.features(in: TerrainLayer.minorContours).isEmpty)
    }

    func testEveryTileFailingIsReported() async throws {
        let stub = StubFetcher { _, _ in
            throw HTTPError(url: URL(string: "https://example.invalid")!, underlying: "no route to host")
        }
        let (provider, _) = provider(testSettings { $0.maxAttempts = 1 }, fetcher: stub)
        do {
            _ = try await provider.fetch(athens)
            XCTFail("a total failure must be reported, not returned as an empty map")
        } catch let error as TerrainTileError {
            guard case .noTilesReadable = error else {
                return XCTFail("expected .noTilesReadable, got \(error)")
            }
        }
    }

    func testAFailedTileIsRetriedUpToTheAttemptLimit() async throws {
        let stub = StubFetcher { _, index in
            // Fail the first two attempts at the first tile, then serve everything.
            if index <= 2 { throw HTTPError(url: URL(string: "https://example.invalid")!, statusCode: 500) }
            return rampTileData()
        }
        let (provider, _) = provider(testSettings { $0.maxAttempts = 3 }, fetcher: stub)
        let result = try await provider.fetch(athens)
        XCTAssertFalse(result.features(in: TerrainLayer.minorContours).isEmpty)
        XCTAssertGreaterThan(stub.callCount, 2, "the failing tile should have been retried")
    }

    func testAnOversizedAreaIsRefusedRatherThanHammeringTheService() async throws {
        var settings = testSettings()
        settings.maxTiles = 2
        settings.targetPixels = 4096
        settings.maxZoom = 14
        let provider = TerrainTileProvider(settings: settings, http: StubFetcher(alwaysReturning: rampTileData()))
        // Zoom selection already respects the budget, so this checks the guard
        // inside the mosaic builder using a zoom that cannot possibly fit.
        do {
            _ = try await provider.mosaic(
                bounds: BoundingBox(minLon: 0, minLat: 0, maxLon: 40, maxLat: 40),
                zoom: 8
            )
            XCTFail("the tile budget must be enforced")
        } catch let error as TerrainTileError {
            guard case .tileBudgetExceeded = error else {
                return XCTFail("expected .tileBudgetExceeded, got \(error)")
            }
        }
    }

    /// Kickoff detail 14: serial fetching spends the whole time waiting — the
    /// Python measured 23 s serial against 5 s pooled.
    ///
    /// The tile *fetch* is what is being timed, not the whole pipeline: contouring
    /// dominates the wall clock in a debug build and would swamp the signal. So the
    /// mosaic builder is timed directly.
    func testTilesAreFetchedConcurrently() async throws {
        let delay = Duration.milliseconds(120)
        let stub = StubFetcher { _, _ in
            try? await Task.sleep(for: delay)
            return rampTileData()
        }
        // Enough area to need several tiles, or the test proves nothing.
        let provider = TerrainTileProvider(settings: realisticSettings(), http: stub)

        let started = ContinuousClock.now
        _ = try await provider.mosaic(bounds: athens.bbox, zoom: 10)
        let elapsed = ContinuousClock.now - started

        XCTAssertGreaterThan(stub.callCount, 1, "this area needs more than one tile for the test to mean anything")
        XCTAssertLessThan(
            elapsed, delay * stub.callCount,
            "\(stub.callCount) tiles at \(delay) each took \(elapsed) — that is serial"
        )
    }

    /// The fast defaults must not hide a bug that only appears at a real grid size.
    func testTheProviderWorksAtRealisticResolution() async throws {
        let (provider, _) = provider(realisticSettings())
        let result = try await provider.fetch(athens)

        XCTAssertGreaterThan(result.features(in: TerrainLayer.minorContours).count, 50)
        XCTAssertFalse(result.features(in: TerrainLayer.elevationBands).isEmpty)
        let columns = try XCTUnwrap(result.metadata["grid_columns"]?.doubleValue)
        XCTAssertGreaterThan(columns, 200, "the realistic settings should give a grid worth contouring")

        // A long contour must arrive whole. Kickoff detail 9: thinning that
        // truncates a vertex list and jumps to the last vertex rules a chord
        // straight across the shape, and the ramp's contours run the full height.
        let longest = result.features(in: TerrainLayer.minorContours)
            .flatMap(\.geometry.lineStrings)
            .max { $0.coordinates.count < $1.coordinates.count }
        XCTAssertGreaterThan(try XCTUnwrap(longest).coordinates.count, 100)
    }

    func testCancellationStopsTheFetchBetweenTiles() async throws {
        let stub = StubFetcher { _, _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return rampTileData()
        }
        let (provider, _) = provider(fetcher: stub)
        let task = Task { try await provider.fetch(athens) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            // Not a failure in itself: a fetch that had already finished every
            // tile before the cancel landed is allowed to succeed. What must not
            // happen is hanging or crashing.
        } catch is FetchCancelled {
            // The documented outcome.
        } catch is CancellationError {
            // Structured concurrency may surface it this way; also fine.
        }
    }

    func testSummitsAreLabelledWithTheirMeasuredHeight() async throws {
        let (provider, _) = provider()
        for feature in try await provider.fetch(athens).features(in: TerrainLayer.summits) {
            XCTAssertEqual(feature.geometry.typeName, "Point")
            XCTAssertTrue(try XCTUnwrap(feature.property("name")?.stringValue).hasSuffix(" m"))
            XCTAssertEqual(feature.provenance, .measured)
        }
    }

    /// A high point on the sea floor is not a peak anyone can stand on.
    func testTheSeaFloorGrowsNoSummits() async throws {
        let stub = StubFetcher(alwaysReturning: rampTileData(from: -1200.0, to: -40.0))
        let (provider, _) = provider(fetcher: stub)
        let summits = try await provider.fetch(athens).features(in: TerrainLayer.summits)
        XCTAssertTrue(summits.isEmpty)
    }

    func testSubSeaContoursAreKeptApartFromLand() async throws {
        let stub = StubFetcher(alwaysReturning: rampTileData(from: -800.0, to: 400.0))
        let (provider, _) = provider(fetcher: stub)
        let result = try await provider.fetch(athens)

        XCTAssertFalse(result.features(in: TerrainLayer.bathymetry).isEmpty)
        XCTAssertFalse(result.features(in: TerrainLayer.minorContours).isEmpty)
        for feature in result.features(in: TerrainLayer.bathymetry) {
            XCTAssertLessThan(try XCTUnwrap(feature.property("elevation")?.doubleValue), 0.0)
        }
        for feature in result.features(in: TerrainLayer.minorContours) {
            XCTAssertGreaterThan(try XCTUnwrap(feature.property("elevation")?.doubleValue), 0.0)
        }
    }

    func testBathymetryCanBeFoldedBackIntoTheTerrainLayer() async throws {
        let stub = StubFetcher(alwaysReturning: rampTileData(from: -800.0, to: 400.0))
        let (provider, _) = provider(testSettings { $0.separateBathymetry = false }, fetcher: stub)
        let result = try await provider.fetch(athens)
        XCTAssertTrue(result.features(in: TerrainLayer.bathymetry).isEmpty)
        XCTAssertTrue(
            result.features(in: TerrainLayer.minorContours).contains {
                ($0.property("elevation")?.doubleValue ?? 0) < 0
            },
            "the sub-sea contours must still be there, in the land layer"
        )
    }

    /// A coastal strip with no sea floor yields no bathymetry, which is the other
    /// half of the same claim.
    func testGroundEntirelyAboveSeaLevelYieldsNoBathymetry() async throws {
        let stub = StubFetcher(alwaysReturning: rampTileData(from: 5.0, to: 900.0))
        let (provider, _) = provider(fetcher: stub)
        let bathymetry = try await provider.fetch(athens).features(in: TerrainLayer.bathymetry)
        XCTAssertTrue(bathymetry.isEmpty)
    }

    func testFilledElevationBandsAreProduced() async throws {
        let (provider, _) = provider()
        let bands = try await provider.fetch(athens).features(in: TerrainLayer.elevationBands)
        XCTAssertFalse(bands.isEmpty)
        for feature in bands {
            XCTAssertTrue(["Polygon", "MultiPolygon"].contains(feature.geometry.typeName))
            let low = try XCTUnwrap(feature.property("elevation_low")?.doubleValue)
            let high = try XCTUnwrap(feature.property("elevation_high")?.doubleValue)
            XCTAssertLessThan(low, high)
            XCTAssertEqual(feature.provenance, .measured)
        }
    }

    func testBandsAreOrderedAndIndexed() async throws {
        let (provider, _) = provider()
        let bands = try await provider.fetch(athens).features(in: TerrainLayer.elevationBands)
        let indices = bands.compactMap { $0.property("band_index")?.doubleValue }
        XCTAssertEqual(indices, indices.sorted())
        for feature in bands {
            XCTAssertEqual(feature.property("band_count")?.doubleValue, Double(bands.count))
        }
    }

    func testBandsCanBeSwitchedOff() async throws {
        let (provider, _) = provider(testSettings { $0.emitElevationBands = false })
        let bands = try await provider.fetch(athens).features(in: TerrainLayer.elevationBands)
        XCTAssertTrue(bands.isEmpty)
    }

    func testAnEmptyLayerIsPresentRatherThanMissing() async throws {
        // The layer panel is derived from what the fetch returned, and an empty
        // layer has to be able to say "none here" rather than vanish.
        let stub = StubFetcher(alwaysReturning: rampTileData(from: 5.0, to: 900.0))
        let (provider, _) = provider(fetcher: stub)
        let result = try await provider.fetch(athens)
        for layer in TerrainLayer.all {
            XCTAssertNotNil(result.featuresByLayer[layer], "\(layer) must be present even when empty")
        }
    }

    func testContoursCarryTheIndexFlagForAccentedLines() async throws {
        let (provider, _) = provider()
        let result = try await provider.fetch(athens)
        for feature in result.features(in: TerrainLayer.indexContours) {
            XCTAssertEqual(feature.property("index_contour")?.boolValue, true)
        }
        for feature in result.features(in: TerrainLayer.minorContours) {
            XCTAssertEqual(feature.property("index_contour")?.boolValue, false)
        }
    }
}

final class MercatorSanityTests: XCTestCase {

    /// A linear row-to-latitude map would place this out by a visible distance.
    func testAContourAtAthensLatitudeIsNotDisplaced() {
        let zoom = 12
        let pixel = WebMercator.pixel(lon: 23.75, lat: 38.00, zoom: zoom)
        // Half a pixel south should be a small, latitude-correct step.
        let step = WebMercator.lonLatForPixel(x: 0, y: pixel.y, zoom: zoom).lat
            - WebMercator.lonLatForPixel(x: 0, y: pixel.y + 0.5, zoom: zoom).lat
        let expected = 360.0 / WebMercator.worldPixels(zoom: zoom) * 0.5 * cos(38.0 * .pi / 180.0)
        XCTAssertEqual(step, expected, accuracy: 1e-6)
    }
}

// MARK: -

/// `np.linspace`, for the ported tests.
func linspace(_ start: Double, _ end: Double, _ count: Int) -> [Double] {
    guard count > 1 else { return count == 1 ? [start] : [] }
    let step = (end - start) / Double(count - 1)
    return (0..<count).map { start + Double($0) * step }
}
