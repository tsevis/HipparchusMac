import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry

/// One client for a federated network of ocean data.
///
/// The parsing is checked against griddap's own CSV shape — a row of column
/// names, a row of units, then the data — because that is the contract, and a
/// server that changes it should fail loudly rather than draw a plausible map of
/// nothing.
final class ERDDAPTests: XCTestCase {

    /// Two rows of two, as griddap writes them: south to north, west to east.
    private let sample = """
        time,latitude,longitude,analysed_sst
        UTC,degrees_north,degrees_east,degree_C
        2026-08-01T09:00:00Z,36.3,23.2,25.793
        2026-08-01T09:00:00Z,36.3,23.3,25.778
        2026-08-01T09:00:00Z,36.4,23.2,25.401
        2026-08-01T09:00:00Z,36.4,23.3,25.522
        """

    // MARK: - Reading the answer

    func testItRebuildsTheGrid() throws {
        let grid = try ERDDAPClient.parse(sample, variable: "analysed_sst")
        XCTAssertEqual(grid.field.rows, 2)
        XCTAssertEqual(grid.field.columns, 2)
    }

    /// Row 0 is north, as everywhere else here. griddap sends south first, so a
    /// reader that trusts the order it arrives in draws the sea upside down —
    /// and a temperature field is smooth enough that it would look fine.
    func testRowZeroIsNorthWhateverOrderItArrivesIn() throws {
        let grid = try ERDDAPClient.parse(sample, variable: "analysed_sst")
        XCTAssertEqual(grid.field[0, 0], 25.401, accuracy: 1e-9, "the northern row should be first")
        XCTAssertEqual(grid.field[1, 0], 25.793, accuracy: 1e-9)
    }

    /// The bounds come from the coordinates that arrived, not from the request:
    /// a server is free to snap a range to its own cell edges, and a grid laid
    /// out by what was asked for is a map of somewhere slightly else.
    func testTheBoundsAreReadBackRatherThanAssumed() throws {
        let grid = try ERDDAPClient.parse(sample, variable: "analysed_sst")
        XCTAssertEqual(grid.bounds.minLon, 23.2, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.maxLon, 23.3, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.minLat, 36.3, accuracy: 1e-9)
        XCTAssertEqual(grid.bounds.maxLat, 36.4, accuracy: 1e-9)
    }

    /// The units are in the file. Reading them means a dataset that changes from
    /// Celsius to Kelvin says so instead of drawing a sea 273 degrees warm.
    func testTheUnitAndTheTimeComeFromTheFile() throws {
        let grid = try ERDDAPClient.parse(sample, variable: "analysed_sst")
        XCTAssertEqual(grid.unit, "degree_C")
        XCTAssertEqual(grid.time, "2026-08-01T09:00:00Z")
    }

    /// A missing sample has to stay missing: the tracer reads NaN as "nothing
    /// here", and a zero would be a real and very cold temperature.
    func testAMissingSampleStaysMissing() throws {
        let holed = sample.replacingOccurrences(of: "25.401", with: "NaN")
            .replacingOccurrences(of: "25.522", with: "")
        let grid = try ERDDAPClient.parse(holed, variable: "analysed_sst")
        XCTAssertTrue(grid.field[0, 0].isNaN)
        XCTAssertTrue(grid.field[0, 1].isNaN)
        XCTAssertFalse(grid.field[1, 0].isNaN, "the rest of the grid should survive")
    }

    // MARK: - Refusals

    /// ERDDAP reports failure as a plain-text `Error { … }` document, so the
    /// shape of the body is what decides rather than a status code.
    func testAnErrorDocumentIsRefusedRatherThanParsed() {
        let refusal = """
            Error {
                code=404;
                message="Not Found: datasetID=nope";
            }
            """
        XCTAssertThrowsError(try ERDDAPClient.parse(refusal, variable: "analysed_sst")) { error in
            guard case .refused? = error as? ERDDAPError else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
    }

    func testAResponseWithoutTheVariableSaysSo() {
        let wrong = """
            time,latitude,longitude,something_else
            UTC,degrees_north,degrees_east,1
            2026-08-01T09:00:00Z,36.3,23.2,1
            """
        XCTAssertThrowsError(try ERDDAPClient.parse(wrong, variable: "analysed_sst")) { error in
            guard case .notAGrid? = error as? ERDDAPError else {
                return XCTFail("expected notAGrid, got \(error)")
            }
        }
    }

    func testASingleRowIsNotAGrid() {
        let thin = """
            time,latitude,longitude,analysed_sst
            UTC,degrees_north,degrees_east,degree_C
            2026-08-01T09:00:00Z,36.3,23.2,25.8
            """
        XCTAssertThrowsError(try ERDDAPClient.parse(thin, variable: "analysed_sst"))
    }

    // MARK: - Asking

    /// Server-side subsetting is the thing ERDDAP is good at, and striding is
    /// how a frame the size of the Aegean does not come back as a million rows
    /// of text.
    func testTheStrideGrowsWithTheFrame() {
        let client = ERDDAPClient(targetSamples: 100)
        let small = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 23.3, maxLat: 36.4)
        let large = BoundingBox(minLon: 20.0, minLat: 34.0, maxLon: 30.0, maxLat: 40.0)
        XCTAssertEqual(client.stride(for: small), 1, "a small frame needs no striding")
        XCTAssertGreaterThan(client.stride(for: large), 5)
    }

    /// griddap's dimension order is the dataset's own — time, then latitude,
    /// then longitude — and latitude runs south to north. Swapping either
    /// returns a valid grid of the wrong place.
    func testTheRequestStatesTimeThenLatitudeThenLongitude() throws {
        let client = ERDDAPClient(targetSamples: 100)
        let url = try XCTUnwrap(
            client.url(for: BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 23.3, maxLat: 36.4))
        )
        let query = try XCTUnwrap(url.absoluteString.removingPercentEncoding)
        XCTAssertTrue(query.contains("analysed_sst[(last)]"), query)
        XCTAssertTrue(query.contains("[(36.3):1:(36.4)]"), "latitude runs south to north")
        XCTAssertTrue(query.contains("[(23.2):1:(23.3)]"), "longitude follows latitude")
        XCTAssertTrue(query.hasSuffix(".csv?analysed_sst[(last)][(36.3):1:(36.4)][(23.2):1:(23.3)]"))
    }

    func testTheRequestGoesToTheDatasetItNames() throws {
        let url = try XCTUnwrap(
            ERDDAPClient().url(for: BoundingBox(minLon: 23, minLat: 36, maxLon: 24, maxLat: 37))
        )
        XCTAssertTrue(url.absoluteString.contains("/griddap/jplMURSST41.csv?"))
    }

    // MARK: - Placing it on the map

    /// Cell *centres* span the bounds, so `n` rows have `n - 1` gaps between the
    /// first and the last. Dividing by `n` walks the map a cell short of where
    /// it should end.
    func testTheGridSpansItsBoundsCornerToCorner() {
        let bounds = BoundingBox(minLon: 10, minLat: 50, maxLon: 11, maxLat: 51)
        let map = ERDDAPProvider.mapper(bounds: bounds, rows: 3, columns: 3)

        let topLeft = map(GridPoint(row: 0, column: 0))
        XCTAssertEqual(topLeft.lon, 10, accuracy: 1e-9)
        XCTAssertEqual(topLeft.lat, 51, accuracy: 1e-9, "row 0 is north")

        let bottomRight = map(GridPoint(row: 2, column: 2))
        XCTAssertEqual(bottomRight.lon, 11, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.lat, 50, accuracy: 1e-9)
    }

    // MARK: - What it is called

    /// The whole promise of writing a client rather than a provider per product:
    /// the next ocean scalar is a dataset and two style entries.
    func testAnotherDatasetIsADescriptionAndNothingElse() {
        let salinity = ERDDAPDataset(
            server: "https://example.org/erddap", datasetID: "someSalinity",
            variable: "salinity", layerPrefix: "sss", unit: "PSU", nominalResolution: 0.25
        )
        XCTAssertEqual(salinity.contourLayer, "sss_contours")
        XCTAssertEqual(salinity.bandLayer, "sss_bands")

        let url = ERDDAPClient(dataset: salinity)
            .url(for: BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1))
        XCTAssertTrue(url?.absoluteString.contains("someSalinity.csv") ?? false)
    }
}
