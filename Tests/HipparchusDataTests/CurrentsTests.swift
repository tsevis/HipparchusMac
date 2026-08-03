import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry

private final class StubGET: HTTPFetching, @unchecked Sendable {
    let body: String
    private(set) var asked: [URL] = []

    init(body: String) { self.body = body }

    func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        asked.append(url)
        return Data(body.utf8)
    }
}

/// Surface currents, from one CSV to a drawing of the flow.
///
/// The brief for this assumed a prepared CMEMS file and a Python toolbox. NOAA
/// serves both velocity components through the same ERDDAP the sea surface
/// temperature already comes from, so the checks here are about a *vector*
/// request — one round trip, two columns, one lattice — and about what the
/// tracer's output becomes on the sheet.
final class CurrentsTests: XCTestCase {

    /// A grid griddap's own way round: south first, west first, units on line 2.
    /// The eastward component grows northward, so the speed bands have something
    /// to separate.
    private func sampleCSV(rows: Int = 12, columns: Int = 12) -> String {
        var lines = [
            "time,latitude,longitude,ugos,vgos",
            "UTC,degrees_north,degrees_east,m s-1,m s-1",
        ]
        for row in 0..<rows {
            let lat = 34.0 + Double(row) * 0.25
            for column in 0..<columns {
                let lon = 22.0 + Double(column) * 0.25
                let east = 0.2 + 0.08 * Double(row)
                lines.append("2026-08-01T12:00:00Z,\(lat),\(lon),\(east),0.0")
            }
        }
        return lines.joined(separator: "\n")
    }

    private var bbox: BoundingBox {
        BoundingBox(minLon: 22.0, minLat: 34.0, maxLon: 24.75, maxLat: 36.75)
    }

    // MARK: - Asking for both halves at once

    /// Both components in one request, with the *same* dimension selection.
    /// Fetched separately they could land on different time steps or, after a
    /// server-side snap, different lattices — and a vector assembled from two
    /// different fields is a flow that exists nowhere.
    func testOneRequestCarriesBothComponents() throws {
        let settings = CurrentsSettings()
        let client = ERDDAPClient(dataset: settings.dataset, targetSamples: 10_000)
        let url = try XCTUnwrap(client.vectorURL(for: bbox, second: settings.northwardVariable))
        let query = try XCTUnwrap(url.absoluteString.removingPercentEncoding)

        XCTAssertTrue(query.contains("ugos[(last)]"), query)
        XCTAssertTrue(query.contains("vgos[(last)]"), query)
        let selection = "[(last)][(34.0):1:(36.75)][(22.0):1:(24.75)]"
        XCTAssertTrue(query.hasSuffix("ugos\(selection),vgos\(selection)"), query)
    }

    /// One CSV, read twice — once per column.
    func testBothColumnsComeOutOfTheOneAnswer() throws {
        let east = try ERDDAPClient.parse(sampleCSV(), variable: "ugos")
        let north = try ERDDAPClient.parse(sampleCSV(), variable: "vgos")
        XCTAssertEqual(east.field.rows, north.field.rows)
        XCTAssertEqual(east.field.columns, north.field.columns)
        XCTAssertEqual(east.unit, "m s-1")
        // Row 0 is north, and the eastward component was built to grow
        // northward, so the first row holds the fastest water.
        XCTAssertGreaterThan(east.field[0, 0], east.field[east.field.rows - 1, 0])
        XCTAssertEqual(north.field[0, 0], 0, accuracy: 1e-9)
    }

    // MARK: - End to end

    func testItDrawsStreamlinesFromOneFetch() async throws {
        let http = StubGET(body: sampleCSV())
        let collection = try await CurrentsProvider(http: http).fetch(BBoxQuery(bbox: bbox))

        let features = try XCTUnwrap(collection.featuresByLayer[CurrentsProvider.layer])
        XCTAssertFalse(features.isEmpty, "a steady eastward flow should draw something")
        XCTAssertEqual(http.asked.count, 1, "a current should cost one round trip")

        for feature in features {
            guard case .lineString(let line) = feature.geometry else {
                return XCTFail("a streamline is a line")
            }
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
            for point in line.coordinates {
                XCTAssertTrue((22.0...24.75).contains(point.lon), "\(point.lon) left the frame")
                XCTAssertTrue((34.0...36.75).contains(point.lat), "\(point.lat) left the frame")
            }
        }
    }

    /// Geostrophic velocity is computed from measured sea surface height rather
    /// than measured directly. Calling that `measured` would launder a model into
    /// an observation, which is the one thing the provenance vocabulary exists to
    /// stop.
    func testTheFlowIsLabelledApproximateAndNotMeasured() async throws {
        let collection = try await CurrentsProvider(http: StubGET(body: sampleCSV()))
            .fetch(BBoxQuery(bbox: bbox))
        XCTAssertEqual(collection.provenance, .approximate)
        for feature in collection.featuresByLayer[CurrentsProvider.layer] ?? [] {
            XCTAssertEqual(feature.provenance, .approximate)
        }
    }

    /// The dataset, the time step and the units belong on the sheet: a current
    /// drawn without a date is a current for no particular day.
    func testItSaysWhatItDrewAndWhen() async throws {
        let collection = try await CurrentsProvider(http: StubGET(body: sampleCSV()))
            .fetch(BBoxQuery(bbox: bbox))
        XCTAssertEqual(collection.metadata["erddap_dataset"], .string("nesdisSSH1day"))
        XCTAssertEqual(collection.metadata["erddap_time"], .string("2026-08-01T12:00:00Z"))
        XCTAssertEqual(collection.metadata["current_unit"], .string("m s-1"))
        guard case .int(let count)? = collection.metadata["streamline_count"] else {
            return XCTFail("expected a streamline count")
        }
        XCTAssertGreaterThan(count, 0)
    }

    /// A grid too small to integrate should say so rather than return an empty
    /// sheet that looks like calm water.
    func testAGridTooSmallToIntegrateIsRefused() async throws {
        let thin = """
            time,latitude,longitude,ugos,vgos
            UTC,degrees_north,degrees_east,m s-1,m s-1
            2026-08-01T12:00:00Z,34.0,22.0,0.4,0.0
            2026-08-01T12:00:00Z,34.0,22.25,0.4,0.0
            """
        do {
            _ = try await CurrentsProvider(http: StubGET(body: thin)).fetch(BBoxQuery(bbox: bbox))
            XCTFail("expected a refusal")
        } catch {
            // Either the parse or the provider may catch it; both are honest.
            XCTAssertTrue(error is ERDDAPError, "got \(error)")
        }
    }

    // MARK: - Weight along the line

    private func line(speeds: [Double]) -> [StreamlinePoint] {
        speeds.enumerated().map {
            StreamlinePoint(row: 0, column: Double($0.offset), speed: $0.element)
        }
    }

    /// A streamline drawn at one width says where the water goes; one that
    /// thickens where the water runs says how fast. The split is by speed band,
    /// one feature per run, because a stroke width belongs to a feature.
    func testALineSplitsWhereItsSpeedChangesBand() {
        let runs = CurrentsProvider.runs(
            of: line(speeds: [0.1, 0.1, 0.1, 0.9, 0.9, 0.9]),
            bands: 2, slowest: 0.1, fastest: 0.9
        )
        XCTAssertEqual(runs.count, 2)
        XCTAssertLessThan(runs[0].speed, runs[1].speed)
    }

    /// The runs overlap by one vertex, so the joins are joins rather than
    /// hairlines of paper showing through a continuous current.
    func testTheRunsMeetRatherThanLeavingAGap() {
        let runs = CurrentsProvider.runs(
            of: line(speeds: [0.1, 0.1, 0.1, 0.9, 0.9, 0.9]),
            bands: 2, slowest: 0.1, fastest: 0.9
        )
        XCTAssertEqual(runs[0].points.last?.column, runs[1].points.first?.column)
    }

    /// Steady water is one run at one width, not six one-vertex fragments.
    func testASteadyLineStaysWhole() {
        let runs = CurrentsProvider.runs(
            of: line(speeds: [0.4, 0.4, 0.4, 0.4]), bands: 5, slowest: 0.4, fastest: 0.4
        )
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].points.count, 4)
    }

    /// The fraction spans 0…1 across the bands, which is what the stroke scale
    /// is interpolated over.
    func testTheSlowestAndFastestBandsSitAtTheEndsOfTheRange() throws {
        let runs = CurrentsProvider.runs(
            of: line(speeds: [0.0, 0.0, 1.0, 1.0]), bands: 4, slowest: 0.0, fastest: 1.0
        )
        XCTAssertEqual(try XCTUnwrap(runs.first).fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(runs.last).fraction, 1, accuracy: 1e-9)
    }

    /// The scale reaches the renderer as a property, which is how a streamline
    /// thickens without the scene builder learning anything about currents.
    func testEveryRunCarriesAStrokeScaleWithinItsSettings() async throws {
        let settings = CurrentsSettings()
        let collection = try await CurrentsProvider(settings: settings, http: StubGET(body: sampleCSV()))
            .fetch(BBoxQuery(bbox: bbox))
        let features = try XCTUnwrap(collection.featuresByLayer[CurrentsProvider.layer])

        var scales: [Double] = []
        for feature in features {
            guard case .double(let scale)? = feature.properties["stroke_scale"] else {
                return XCTFail("a run without a stroke scale would draw at one width")
            }
            XCTAssertGreaterThanOrEqual(scale, settings.minStrokeScale - 1e-9)
            XCTAssertLessThanOrEqual(scale, settings.maxStrokeScale + 1e-9)
            scales.append(scale)
        }
        // The field was built with a north-south speed gradient, so the sheet
        // should not come out all one weight.
        XCTAssertGreaterThan(scales.max()! - scales.min()!, 0)
    }
}
