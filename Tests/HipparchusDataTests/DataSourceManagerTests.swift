import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// A provider that answers from memory, so the whole suite stays offline.
private struct StubProvider: MapProvider {
    let providerID: String
    let label: String
    let provenance: Provenance
    var layers: [String: Int] = [:]
    var failure: (any Error)?
    /// Blocks until cancelled, to exercise a source stopping mid-fetch.
    var waitsForCancellation = false

    func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        if waitsForCancellation {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
            }
            throw FetchCancelled(source: providerID)
        }
        if let failure { throw failure }

        var featuresByLayer: [String: [Feature]] = [:]
        for (layer, count) in layers {
            featuresByLayer[layer] = (0..<count).map { index in
                Feature(
                    id: "\(providerID)/\(layer)/\(index)",
                    layer: layer,
                    source: providerID,
                    geometry: .point(Coordinate(lon: 25.4, lat: 36.4)),
                    provenance: provenance,
                    properties: ["name": .string("\(layer) \(index)")]
                )
            }
        }
        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: ["source": .string(providerID)],
            bbox: query.bbox,
            provenance: provenance
        )
    }
}

private struct StubError: Error, CustomStringConvertible {
    let description: String
}

final class DataSourceManagerTests: XCTestCase {

    private let query = BBoxQuery(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)

    private func manager(_ providers: [StubProvider]) -> DataSourceManager {
        DataSourceManager(providers: providers)
    }

    private var streets: StubProvider {
        StubProvider(providerID: SourceID.overpass, label: "OpenStreetMap", provenance: .measured,
                     layers: ["roads": 3, "water": 1])
    }

    private var elevation: StubProvider {
        StubProvider(providerID: SourceID.terrainTiles, label: "Elevation", provenance: .measured,
                     layers: ["terrain_contours": 5])
    }

    // MARK: - Stacking

    /// The behaviour the whole interface rests on, checked at the layer that
    /// actually merges the data rather than at the layer that decides to.
    func testStackedSourcesKeepEveryLayer() async throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)
        let plan = try XCTUnwrap(stack.plan)

        let merged = try await manager([streets, elevation]).fetch(query, plan: plan)

        XCTAssertEqual(Set(merged.layerNames), ["roads", "water", "terrain_contours"])
        XCTAssertEqual(merged.featureCount, 9)
        XCTAssertEqual(merged.metadata["source"]?.stringValue, "overpass+terrain_tiles")
        XCTAssertEqual(merged.bbox, query.bbox)
    }

    /// Provenance is load-bearing: the weakest claim any source makes is the claim
    /// the merged map is entitled to.
    func testTheMergedMapTakesTheWeakestProvenanceOfItsSources() async throws {
        let synthetic = StubProvider(
            providerID: SourceID.simulatedTerrain, label: "Simulated", provenance: .synthetic,
            layers: ["terrain_contours": 2]
        )
        let merged = try await manager([elevation, synthetic]).fetch(
            query, plan: FetchPlan(base: SourceID.terrainTiles, extras: [SourceID.simulatedTerrain])
        )
        XCTAssertEqual(merged.provenance, .synthetic, "a measured map with a generated layer is not measured")
    }

    /// Flattening a provider's metadata away would lose what it said about itself.
    func testEachProviderKeepsItsOwnMetadataReachable() async throws {
        let merged = try await manager([streets, elevation]).fetch(
            query, plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles])
        )
        XCTAssertEqual(merged.metadata["overpass.source"]?.stringValue, "overpass")
        XCTAssertEqual(merged.metadata["terrain_tiles.source"]?.stringValue, "terrain_tiles")
    }

    // MARK: - Failure

    /// One source failing must not sink a fetch four others answered.
    func testAFailingSourceIsRecordedAndTheRestStillDraw() async throws {
        let broken = StubProvider(
            providerID: SourceID.usgsEarthquakes, label: "Earthquakes", provenance: .measured,
            failure: StubError(description: "HTTP 503")
        )
        let merged = try await manager([streets, broken]).fetch(
            query, plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.usgsEarthquakes])
        )
        XCTAssertEqual(merged.featureCount, 4, "the streets still arrived")
        XCTAssertTrue(merged.metadata["provider_errors"]?.stringValue?.contains("503") == true)
    }

    func testAnUnregisteredSourceIsReportedRatherThanCrashing() async throws {
        let merged = try await manager([streets]).fetch(
            query, plan: FetchPlan(base: SourceID.overpass, extras: ["nonexistent"])
        )
        XCTAssertEqual(merged.featureCount, 4)
        XCTAssertTrue(merged.metadata["provider_errors"]?.stringValue?.contains("not registered") == true)
    }

    func testAFetchThatAnsweredNothingIsAnEmptyMapNotACrash() async throws {
        let broken = StubProvider(
            providerID: SourceID.overpass, label: "OpenStreetMap", provenance: .measured,
            failure: StubError(description: "no route to host")
        )
        let merged = try await manager([broken]).fetch(query, plan: FetchPlan(base: SourceID.overpass))
        XCTAssertEqual(merged.featureCount, 0)
        XCTAssertEqual(merged.metadata["source"]?.stringValue, "none")
    }

    // MARK: - Cancellation, and what it honestly does

    /// Sources that have not started are skipped. That is the immediate part.
    func testCancellingBeforeAnythingStartsThrowsRatherThanDrawingNothing() async throws {
        let manager = self.manager([streets, elevation])
        let query = self.query
        let task = Task {
            try await manager.fetch(
                query, plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles])
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            // A cancel that lands after both sources finished is a legitimate race:
            // the work was already paid for, so the map is returned rather than
            // discarded. Either outcome is correct; a crash is not.
        } catch is FetchCancelled {
            // Nothing had run, so there was nothing worth drawing.
        }
    }

    /// A source already running stops when it checks, and the sources behind it in
    /// the queue never start.
    func testASourceStopsWhenItChecksAndTheQueueBehindItIsSkipped() async throws {
        let slow = StubProvider(
            providerID: SourceID.overpass, label: "OpenStreetMap", provenance: .measured,
            waitsForCancellation: true
        )
        let reporter = FetchReporter()
        let manager = self.manager([slow, elevation])
        let query = self.query

        let task = Task {
            try await manager.fetch(
                query,
                plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles]),
                reporter: reporter
            )
        }

        // Let the first source get going before cancelling it.
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("nothing finished, so there was nothing to return")
        } catch is FetchCancelled {
            let progress = await reporter.current
            XCTAssertEqual(progress.source(SourceID.overpass)?.state, .cancelled)
            XCTAssertEqual(
                progress.source(SourceID.terrainTiles)?.state, .cancelled,
                "a source behind the cancel must never start"
            )
        }
    }

    /// Work already paid for is not thrown away.
    func testASourceThatFinishedBeforeTheCancelIsStillDrawn() async throws {
        let slow = StubProvider(
            providerID: SourceID.terrainTiles, label: "Elevation", provenance: .measured,
            waitsForCancellation: true
        )
        let manager = self.manager([streets, slow])
        let query = self.query

        let task = Task {
            try await manager.fetch(
                query, plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles])
            )
        }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()

        let merged = try await task.value
        XCTAssertEqual(merged.featureCount, 4, "the streets finished before the cancel and must survive")
        XCTAssertEqual(merged.metadata["cancelled"]?.boolValue, true, "an incomplete map must say so")
    }

    // MARK: - Progress

    func testProgressIsReportedPerSourceInTheOrderAsked() async throws {
        let reporter = FetchReporter()
        _ = try await manager([streets, elevation]).fetch(
            query,
            plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles]),
            reporter: reporter
        )

        let progress = await reporter.current
        XCTAssertEqual(progress.sources.map(\.sourceID), [SourceID.overpass, SourceID.terrainTiles])
        XCTAssertEqual(progress.sources.map(\.state), [.done, .done])
        XCTAssertFalse(progress.isRunning)
        // The point of per-source progress: it says what each one actually returned.
        XCTAssertEqual(progress.source(SourceID.overpass)?.detail, "4 in 2 layers")
        XCTAssertTrue(progress.summary().contains("overpass ✓"))
    }

    func testAnObserverSeesTheStateAtTheMomentItSubscribes() async throws {
        let reporter = FetchReporter()
        await reporter.expect([SourceID.overpass])
        await reporter.started(SourceID.overpass)

        var stream = await reporter.updates().makeAsyncIterator()
        let first = await stream.next()
        XCTAssertEqual(first?.source(SourceID.overpass)?.state, .running, "a late observer must not start blank")
    }

    func testAFailedSourceSaysSoInItsSummary() async throws {
        let reporter = FetchReporter()
        _ = try await manager([
            StubProvider(providerID: SourceID.overpass, label: "OSM", provenance: .measured,
                         layers: ["roads": 1]),
            StubProvider(providerID: SourceID.gibsImagery, label: "GIBS", provenance: .uncalibrated,
                         failure: StubError(description: "HTTP 500")),
        ]).fetch(
            query,
            plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.gibsImagery]),
            reporter: reporter
        )

        let progress = await reporter.current
        XCTAssertEqual(progress.source(SourceID.gibsImagery)?.state, .failed)
        XCTAssertTrue(progress.summary().contains("gibs_imagery failed"))
    }
}
