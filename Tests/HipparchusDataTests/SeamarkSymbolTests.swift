import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry

/// The shapes that make one mark tell itself apart from another.
///
/// The first version of this drew everything as a dot, which put the marks in
/// the right places and left a cardinal buoy and a wreck looking identical. What
/// is checked here is that the shapes differ in the ways a reader depends on,
/// and that they are the right size and the right shape *on the map* — a symbol
/// stated in degrees leans and flattens as the map moves north.
final class SeamarkSymbolTests: XCTestCase {

    private let frame = BoundingBox(minLon: 8.55, minLat: 53.85, maxLon: 8.75, maxLat: 53.92)

    private func tags(_ type: String, _ category: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["seamark:type": type]
        if let category { out["seamark:\(type):category"] = category }
        return out
    }

    private func geometry(_ type: String, _ category: String? = nil) -> [Geometry] {
        SeamarkSymbols.geometry(
            for: tags(type, category),
            at: Coordinate(lon: 8.65, lat: 53.88),
            in: frame
        ) ?? []
    }

    // MARK: - Telling one mark from another

    /// The distinction the whole lateral system rests on, and the reason cans
    /// and cones exist at all: it survives flat light and colour-blindness.
    func testAPortMarkAndAStarboardMarkAreDifferentShapes() {
        let port = SeamarkSymbols.parts(for: tags("buoy_lateral", "port"))
        let starboard = SeamarkSymbols.parts(for: tags("buoy_lateral", "starboard"))
        XCTAssertNotNil(port)
        XCTAssertNotNil(starboard)
        XCTAssertNotEqual(port, starboard, "a can and a cone must not draw alike")
        // A can has four corners; a cone has three.
        XCTAssertEqual(port?.first?.points.count, 4)
        XCTAssertEqual(starboard?.first?.points.count, 3)
    }

    /// Two cones, and their arrangement names the quadrant of safe water. All
    /// four must differ, or the mark says nothing at all.
    func testTheFourCardinalsAreFourDifferentShapes() throws {
        let quadrants = ["north", "east", "south", "west"]
        var seen: [[SeamarkSymbols.Part]] = []
        for quadrant in quadrants {
            let parts = try XCTUnwrap(
                SeamarkSymbols.parts(for: tags("buoy_cardinal", "\(quadrant)_cardinal"))
            )
            XCTAssertEqual(parts.count, 2, "\(quadrant): a cardinal topmark is two cones")
            for other in seen {
                XCTAssertNotEqual(parts, other, "\(quadrant) draws like another quadrant")
            }
            seen.append(parts)
        }
    }

    /// North points up and south points down, which is the half of the mnemonic
    /// that is not a picture of an egg or a wine glass.
    func testNorthPointsUpAndSouthPointsDown() throws {
        let north = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_cardinal", "north")))
        let south = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_cardinal", "south")))

        // The apex of a cone is its lone vertex on the axis; for a cone pointing
        // up it is the highest point of the part.
        func apexIsAtTop(_ part: SeamarkSymbols.Part) -> Bool {
            let apex = part.points.max { $0.y < $1.y }!
            return abs(apex.x) < 1e-9
        }
        XCTAssertTrue(north.allSatisfy(apexIsAtTop), "north's cones should point up")
        XCTAssertTrue(south.allSatisfy { !apexIsAtTop($0) }, "south's cones should point down")
    }

    /// East is base to base — the egg — and west is point to point — the wine
    /// glass. They are mirror images, and confusing them puts a vessel on the
    /// wrong side of a hazard.
    func testEastAndWestAreMirrorsOfEachOther() throws {
        let east = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_cardinal", "east")))
        let west = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_cardinal", "west")))
        XCTAssertNotEqual(east, west)

        // The egg is widest in the middle; the wine glass is narrowest there.
        func widthNearMiddle(_ parts: [SeamarkSymbols.Part]) -> Double {
            let near = parts.flatMap(\.points).filter { abs($0.y) < 0.2 }
            guard let low = near.map(\.x).min(), let high = near.map(\.x).max() else { return 0 }
            return high - low
        }
        XCTAssertGreaterThan(
            widthNearMiddle(east), widthNearMiddle(west),
            "east should be widest at its waist and west narrowest"
        )
    }

    func testAWreckIsNotAnythingElse() throws {
        let wreck = try XCTUnwrap(SeamarkSymbols.parts(for: tags("wreck")))
        XCTAssertEqual(wreck.count, 4, "a hull and three masts")
        XCTAssertTrue(wreck.allSatisfy { !$0.closed }, "a wreck is drawn in strokes")
    }

    /// The one symbol everybody recognises, and it has to carry an exact
    /// position as well as a flare.
    func testALightIsAFlareAndAPosition() throws {
        let light = try XCTUnwrap(SeamarkSymbols.parts(for: tags("light_major")))
        XCTAssertEqual(light.count, 2)
        XCTAssertTrue(light.allSatisfy(\.closed))
    }

    /// A beacon is a topmark that does not float, and the stem is the whole
    /// difference. It is also the difference a reader most needs.
    func testABeaconStandsOnSomethingAndABuoyDoesNot() throws {
        let buoy = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_lateral", "port")))
        let beacon = try XCTUnwrap(SeamarkSymbols.parts(for: tags("beacon_lateral", "port")))
        XCTAssertEqual(beacon.count, buoy.count + 1, "a beacon keeps its topmark and gains a stem")
        XCTAssertNotEqual(buoy, beacon)
    }

    /// Most seamarks in OSM carry no category at all. Knowing only that it
    /// floats is worth drawing, and worth drawing differently from a beacon.
    func testAMarkWithNoCategoryStillSaysWhetherItFloats() throws {
        let buoy = try XCTUnwrap(SeamarkSymbols.parts(for: tags("buoy_lateral")))
        let beacon = try XCTUnwrap(SeamarkSymbols.parts(for: tags("beacon_lateral")))
        XCTAssertNotEqual(buoy, beacon)
    }

    func testSomethingWithNoSymbolAsksForNone() {
        XCTAssertNil(SeamarkSymbols.parts(for: ["highway": "primary"]))
        XCTAssertNil(SeamarkSymbols.parts(for: [:]))
        // An area is not a point symbol; the caller keeps the surveyed shape.
        XCTAssertNil(SeamarkSymbols.parts(for: tags("restricted_area")))
    }

    // MARK: - On the map

    func testASymbolIsRoundOnTheMapRatherThanInDegrees() throws {
        let parts = try XCTUnwrap(
            SeamarkSymbols.geometry(
                for: tags("buoy_lateral", "safe_water"),
                at: Coordinate(lon: 8.65, lat: 53.88), in: frame
            )
        )
        let points = parts.flatMap(\.coordinateList)
        let lonSpan = (points.map(\.lon).max()! - points.map(\.lon).min()!)
        let latSpan = (points.map(\.lat).max()! - points.map(\.lat).min()!)
        // At 54° north a degree of longitude is about 0.59 of a degree of
        // latitude, so an uncorrected circle would come out that much too
        // narrow. Corrected, the two spans differ by the cosine and no more.
        let cosLat = cos(53.88 * .pi / 180)
        XCTAssertEqual(lonSpan * cosLat, latSpan, accuracy: latSpan * 0.02)
    }

    /// The lesson `USGSProvider` learned first: a symbol measured in degrees is
    /// a speck across a sea and a monster across a harbour.
    func testASymbolIsSizedAgainstTheFrameAndNotTheGround() throws {
        let harbour = BoundingBox(minLon: 8.68, minLat: 53.86, maxLon: 8.74, maxLat: 53.89)
        let sea = BoundingBox(minLon: 6.0, minLat: 53.0, maxLon: 10.0, maxLat: 55.0)
        let position = Coordinate(lon: 8.70, lat: 53.87)

        func extent(_ bbox: BoundingBox) throws -> Double {
            let parts = try XCTUnwrap(
                SeamarkSymbols.geometry(for: tags("wreck"), at: position, in: bbox)
            )
            let lats = parts.flatMap(\.coordinateList).map(\.lat)
            return lats.max()! - lats.min()!
        }

        let small = try extent(harbour)
        let large = try extent(sea)
        XCTAssertGreaterThan(large, small, "the symbol should grow with the frame")
        // And in both cases it is the same fraction of the frame, which is the
        // property that makes it legible at either scale.
        let harbourFraction = small / (harbour.maxLat - harbour.minLat)
        let seaFraction = large / (sea.maxLat - sea.minLat)
        XCTAssertEqual(harbourFraction, seaFraction, accuracy: harbourFraction * 0.35)
    }

    func testAClosedPartIsAPolygonAndAnOpenOneIsALine() throws {
        let wreck = try XCTUnwrap(
            SeamarkSymbols.geometry(for: tags("wreck"), at: Coordinate(lon: 8.65, lat: 53.88), in: frame)
        )
        for part in wreck {
            guard case .lineString = part else {
                return XCTFail("a wreck's strokes should stay lines")
            }
        }

        let can = try XCTUnwrap(
            SeamarkSymbols.geometry(
                for: tags("buoy_lateral", "port"),
                at: Coordinate(lon: 8.65, lat: 53.88), in: frame
            )
        )
        guard case .polygon = try XCTUnwrap(can.first) else {
            return XCTFail("a can is a body, not a stroke")
        }
    }

    // MARK: - Through the decoder

    func testTheDecoderTurnsAMarkIntoItsSymbol() {
        let payload: [String: Any] = ["elements": [[
            "type": "node", "id": 1, "lat": 53.88, "lon": 8.65,
            "tags": ["seamark:type": "buoy_cardinal", "seamark:buoy_cardinal:category": "north"],
        ]]]
        let collection = OverpassDecode.featureCollection(from: payload, bbox: frame)
        let buoys = collection.features(in: Seamarks.buoys)
        XCTAssertEqual(buoys.count, 2, "a north cardinal is two cones, so two features")
        for feature in buoys {
            guard case .polygon = feature.geometry else {
                return XCTFail("a cone is a polygon")
            }
        }
    }

    /// A surveyed outline is geography and must not be replaced by a pictogram
    /// of itself.
    func testAnAreaKeepsItsOwnShape() {
        let payload: [String: Any] = ["elements": [[
            "type": "way", "id": 2,
            "tags": ["seamark:type": "harbour", "area": "yes"],
            "geometry": [
                ["lat": 53.87, "lon": 8.69], ["lat": 53.87, "lon": 8.70],
                ["lat": 53.88, "lon": 8.70], ["lat": 53.87, "lon": 8.69],
            ],
        ]]]
        let collection = OverpassDecode.featureCollection(from: payload, bbox: frame)
        XCTAssertEqual(collection.features(in: Seamarks.harbours).count, 1)
    }
}

private extension Geometry {
    /// Every coordinate in this geometry, whatever shape it is.
    var coordinateList: [Coordinate] {
        switch self {
        case .point(let point): [point]
        case .lineString(let line): line.coordinates
        case .polygon(let polygon): polygon.exterior.coordinates
        default: []
        }
    }
}
