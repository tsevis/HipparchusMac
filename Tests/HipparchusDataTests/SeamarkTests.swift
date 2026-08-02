import XCTest
@testable import HipparchusData

/// The marine layer of OSM, and the order it has to be read in.
///
/// The classifier's order is the whole risk here. A lighthouse is a node tagged
/// `seamark:type=light_major` *and* `man_made=lighthouse` *and* `name=...`, and
/// the existing rules claim a named node for `places` several tests before
/// anything would have looked at a seamark tag. Asked in the wrong order, every
/// light on the coast becomes a place name and the chart layer comes back empty
/// while the fetch looks like it worked.
final class SeamarkTests: XCTestCase {

    // MARK: - The vocabulary

    func testTheBuoyFamilyLandsWithTheBuoys() {
        for type in [
            "buoy_lateral", "buoy_cardinal", "buoy_safe_water",
            "buoy_special_purpose", "buoy_isolated_danger", "buoy_installation",
        ] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.buoys, type)
        }
    }

    func testTheBeaconFamilyLandsWithTheBeacons() {
        for type in ["beacon_lateral", "beacon_cardinal", "beacon_isolated_danger", "daymark", "pile"] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.beacons, type)
        }
    }

    func testEveryKindOfLightIsALight() {
        for type in ["light", "light_major", "light_minor", "light_float", "light_vessel", "landmark"] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.lights, type)
        }
    }

    func testThingsToAvoidAreHazards() {
        for type in ["wreck", "rock", "obstruction", "foul_ground"] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.hazards, type)
        }
    }

    func testWhereAVesselGoesIsAHarbour() {
        for type in ["harbour", "anchorage", "berth", "pilot_boarding_place"] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.harbours, type)
        }
    }

    func testRulesAreAreas() {
        for type in [
            "restricted_area", "military_area", "separation_zone",
            "separation_lane", "fairway", "deep_water_route",
        ] {
            XCTAssertEqual(Seamarks.layer(forType: type), Seamarks.areas, type)
        }
    }

    /// A mooring buoy floats and is picked up, which is what separates it from
    /// the fixed marks it would otherwise sit beside.
    func testAMooringIsABuoyAndAMooringAreaIsNot() {
        XCTAssertEqual(Seamarks.layer(forType: "mooring"), Seamarks.buoys)
        XCTAssertEqual(Seamarks.layer(forType: "mooring_area"), Seamarks.harbours)
    }

    /// The standard is open and OSM adds to it. A value no table has heard of is
    /// still a charted object, and dropping it would lose real ground because
    /// somebody added a word.
    func testAnUnknownSeamarkIsKeptRatherThanDropped() {
        XCTAssertEqual(Seamarks.layer(forType: "something_invented_next_year"), Seamarks.areas)
    }

    func testSomethingThatIsNotASeamarkIsNotOne() {
        XCTAssertNil(Seamarks.layer(forType: ""))
        XCTAssertNil(Seamarks.layer(forType: "   "))
        XCTAssertNil(Seamarks.layer(forTags: ["highway": "primary"]))
        XCTAssertNil(Seamarks.layer(forTags: [:]))
    }

    func testTheTagIsReadWhateverItsCase() {
        XCTAssertEqual(Seamarks.layer(forTags: ["seamark:type": "Buoy_Lateral"]), Seamarks.buoys)
        XCTAssertEqual(Seamarks.layer(forTags: ["seamark:type": " wreck "]), Seamarks.hazards)
    }

    // MARK: - The order it is asked in

    /// The trap this whole file exists for.
    func testALighthouseIsALightAndNotAPlaceName() {
        let lighthouse: [String: Any] = [
            "seamark:type": "light_major",
            "seamark:light:character": "Fl",
            "man_made": "lighthouse",
            "name": "Cape Greco Light",
        ]
        XCTAssertEqual(OverpassDecode.classify(tags: lighthouse), Seamarks.lights)
    }

    /// A marina carries both, and on a chart the seamark is the answer.
    func testAHarbourIsASeamarkAndNotALeisureFacility() {
        let marina: [String: Any] = [
            "seamark:type": "harbour",
            "leisure": "marina",
            "name": "Limassol Marina",
        ]
        XCTAssertEqual(OverpassDecode.classify(tags: marina), Seamarks.harbours)
    }

    /// A wreck is tagged `historic` often enough that the generic name test
    /// would have claimed it.
    func testAWreckIsAHazardAndNotAPlace() {
        let wreck: [String: Any] = [
            "seamark:type": "wreck",
            "historic": "wreck",
            "name": "Zenobia",
        ]
        XCTAssertEqual(OverpassDecode.classify(tags: wreck), Seamarks.hazards)
    }

    /// The other side of the same rule: the seamark test must not reach past its
    /// own namespace and claim things that merely float near one.
    func testTheCoastlineIsStillTheCoastline() {
        XCTAssertEqual(OverpassDecode.classify(tags: ["natural": "coastline"]), "coastline")
    }

    func testAFerryIsStillAFerryRoute() {
        XCTAssertEqual(OverpassDecode.classify(tags: ["route": "ferry"]), "ferry_routes")
    }

    /// A harbour wall is a structure, not a seamark, and stays where it was.
    func testAnUntaggedPierIsNotASeamark() {
        XCTAssertNotEqual(OverpassDecode.classify(tags: ["man_made": "pier"]), Seamarks.harbours)
    }

    // MARK: - What the decoder declares

    func testEverySeamarkLayerIsOneTheDecoderDeclares() {
        for layer in Seamarks.allLayers {
            XCTAssertTrue(
                OverpassDecode.layers.contains(layer),
                "\(layer) is produced but not declared, so the panel will never say 'none here' for it"
            )
        }
    }

    func testTheSixLayersAreDistinct() {
        XCTAssertEqual(Set(Seamarks.allLayers).count, Seamarks.allLayers.count)
    }
}
