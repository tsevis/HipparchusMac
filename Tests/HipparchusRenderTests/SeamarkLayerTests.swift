import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry
@testable import HipparchusRender

/// Where sea marks sit — in the panel, and in the order they are drawn.
///
/// Both are decisions about reading rather than about data, so both are stated
/// here rather than left to whatever the dictionary happened to do.
final class SeamarkLayerTests: XCTestCase {

    private func index(of layer: String) -> Int? {
        SceneBuilder.preferredLayerOrder.firstIndex(of: layer)
    }

    // MARK: - The draw order

    /// A buoy under a building has failed at the one thing it is for.
    func testTheMarksThemselvesDrawAboveTheBuiltEnvironment() throws {
        let buildings = try XCTUnwrap(index(of: "buildings"))
        for mark in ["seamark_hazards", "seamark_beacons", "seamark_buoys", "seamark_lights"] {
            let rank = try XCTUnwrap(index(of: mark), "\(mark) is not in the draw order")
            XCTAssertGreaterThan(rank, buildings, "\(mark) draws under the buildings")
        }
    }

    /// Lights are what a reader looks for first, so nothing else covers them.
    func testLightsDrawAboveTheOtherMarks() throws {
        let lights = try XCTUnwrap(index(of: "seamark_lights"))
        for other in ["seamark_hazards", "seamark_beacons", "seamark_buoys"] {
            XCTAssertGreaterThan(lights, try XCTUnwrap(index(of: other)))
        }
    }

    /// The lesson the inferred sea taught: a hypsometric band fill is opaque, so
    /// anything drawn under it is painted out.
    func testAreasDrawAboveTheReliefThatWouldPaintThemOut() throws {
        let bands = try XCTUnwrap(index(of: "elevation_bands"))
        let hillshade = try XCTUnwrap(index(of: "terrain_hillshade"))
        for area in ["seamark_areas", "seamark_harbours"] {
            let rank = try XCTUnwrap(index(of: area))
            XCTAssertGreaterThan(rank, bands, "\(area) would be painted out by the bands")
            XCTAssertGreaterThan(rank, hillshade, "\(area) would be painted out by the shading")
        }
    }

    /// Rules are ground, and ground goes under the marks that sit on it.
    func testAreasDrawUnderTheMarks() throws {
        let areas = try XCTUnwrap(index(of: "seamark_areas"))
        XCTAssertLessThan(areas, try XCTUnwrap(index(of: "seamark_buoys")))
    }

    /// Every label still draws last, sea marks included.
    func testLabelsStayOnTop() throws {
        let lights = try XCTUnwrap(index(of: "seamark_lights"))
        for label in ["places", "street_names", "summits"] {
            XCTAssertGreaterThan(try XCTUnwrap(index(of: label)), lights, "\(label) fell under the marks")
        }
    }

    func testEverySeamarkLayerIsRanked() {
        for layer in Seamarks.allLayers {
            XCTAssertNotNil(
                index(of: layer),
                "\(layer) is unranked and would sort alphabetically after everything"
            )
        }
    }

    // MARK: - The panel

    func testTheMarksAreTheirOwnGroup() {
        for layer in Seamarks.allLayers {
            XCTAssertEqual(LayerInventory.group(for: layer), "Sea marks", layer)
        }
        XCTAssertTrue(LayerInventory.groupOrder.contains("Sea marks"))
    }

    /// A group nobody ordered sorts to the end with the derived layers, which is
    /// where a reader would never look for a buoy.
    func testTheGroupIsOrderedBeforeTheBuiltEnvironment() throws {
        let marks = try XCTUnwrap(LayerInventory.groupOrder.firstIndex(of: "Sea marks"))
        let built = try XCTUnwrap(LayerInventory.groupOrder.firstIndex(of: "Built"))
        let water = try XCTUnwrap(LayerInventory.groupOrder.firstIndex(of: "Water & land"))
        XCTAssertGreaterThan(marks, water)
        XCTAssertLessThan(marks, built)
    }

    func testEverySeamarkLayerReadsAsSomethingOtherThanItsIdentifier() {
        for layer in Seamarks.allLayers {
            let label = LayerInventory.label(for: layer)
            XCTAssertFalse(label.contains("_"), "\(layer) has no display name: \(label)")
            XCTAssertFalse(label.lowercased().hasPrefix("seamark"), "\(layer) reads as jargon: \(label)")
        }
    }

    // MARK: - A mark is a mark, not a label anchor

    private func collection(_ features: [Feature]) -> FeatureCollection {
        FeatureCollection(
            featuresByLayer: Dictionary(grouping: features, by: \.layer),
            metadata: ["source": .string("overpass")],
            bbox: BoundingBox(minLon: 8.6, minLat: 53.85, maxLon: 8.75, maxLat: 53.92),
            provenance: .measured
        )
    }

    private func mark(_ layer: String, _ id: String, lon: Double, lat: Double,
                      named name: String? = nil) -> Feature {
        Feature(
            id: id, layer: layer, source: "overpass",
            geometry: .point(Coordinate(lon: lon, lat: lat)),
            provenance: .measured,
            properties: name.map { ["name": PropertyValue.string($0)] } ?? [:]
        )
    }

    /// The bug this feature nearly shipped with.
    ///
    /// The scene builder turned every point into a label and dropped the
    /// geometry — a rule that is right for a town and wrong for a buoy, which
    /// has no name at all. Twenty-one buoys came back from Overpass in the first
    /// real render and not one reached the sheet, from a fetch that reported
    /// success. The layer was styled, budgeted and permanently empty, which is
    /// the same failure the earthquakes and the satellite tracks already taught
    /// this loop once.
    func testABuoyWithNoNameStillReachesTheSheet() throws {
        let scene = try SceneBuilder().build(from: collection([
            mark(Seamarks.buoys, "node/1", lon: 8.70, lat: 53.88),
            mark(Seamarks.buoys, "node/2", lon: 8.71, lat: 53.89),
        ]))
        let buoys = try XCTUnwrap(scene.layers.first { $0.name == Seamarks.buoys })
        XCTAssertEqual(buoys.geometries.count, 2, "the marks were dropped on the floor")
    }

    /// A named mark is still a mark. "No. 3" on a buoy is not worth a label on a
    /// printed sheet, and it must not cost the mark itself.
    func testANamedMarkIsDrawnRatherThanTurnedIntoText() throws {
        let scene = try SceneBuilder().build(from: collection([
            mark(Seamarks.lights, "node/3", lon: 8.70, lat: 53.88, named: "Cuxhaven Light"),
        ]))
        let lights = try XCTUnwrap(scene.layers.first { $0.name == Seamarks.lights })
        XCTAssertEqual(lights.geometries.count, 1, "a name should not cost the mark")
    }

    /// The other side of the rule: a town is still a label, not a dot.
    func testANamedPlaceIsStillALabelAndNotGeometry() throws {
        let scene = try SceneBuilder().build(from: collection([
            Feature(
                id: "node/4", layer: "places", source: "overpass",
                geometry: .point(Coordinate(lon: 8.70, lat: 53.88)),
                provenance: .measured,
                properties: ["name": .string("Cuxhaven"), "place": .string("town")]
            ),
        ]))
        let places = try XCTUnwrap(scene.layers.first { $0.name == "places" })
        XCTAssertEqual(places.geometries.count, 0, "a town should not draw as a dot")
        XCTAssertEqual(places.labels.count, 1)
    }

    /// Every point layer, so a later refactor cannot quietly drop one of them
    /// back into the label path.
    func testEveryMarkLayerDrawsItsPoints() throws {
        for layer in Seamarks.allLayers {
            let scene = try SceneBuilder().build(from: collection([
                mark(layer, "node/9", lon: 8.70, lat: 53.88),
            ]))
            let built = try XCTUnwrap(scene.layers.first { $0.name == layer })
            XCTAssertEqual(built.geometries.count, 1, "\(layer) dropped its point")
        }
    }

    /// The panel is built from the scene, so a sheet with no marks on it says
    /// "none here" rather than pretending the layer was never asked for.
    func testAnEmptyMarkLayerStillExplainsItself() {
        let scene = RenderScene(
            layers: Seamarks.allLayers.map { RenderLayer(name: $0) },
            bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)
        )
        let rows = LayerInventory.entries(for: scene)
        XCTAssertEqual(rows.count, Seamarks.allLayers.count)
        for row in rows {
            XCTAssertEqual(row.countText, "none here")
            XCTAssertEqual(row.group, "Sea marks")
        }
    }
}
