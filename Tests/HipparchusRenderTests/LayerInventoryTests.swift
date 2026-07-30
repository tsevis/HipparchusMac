import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Ported from `tests/test_layer_inventory.py`.
///
/// The point of the whole module: the panel is derived from the scene that was
/// actually built, so an empty map explains itself instead of showing a fixed
/// checklist of layers that may or may not hold anything.
final class LayerInventoryTests: XCTestCase {

    func testEveryLayerInTheSceneBecomesARow() throws {
        let scene = try Sample.scene()
        let entries = LayerInventory.entries(for: scene)
        XCTAssertEqual(Set(entries.map(\.layerID)), Set(scene.layers.map(\.name)))
    }

    /// A layer with nothing in it says so rather than sitting there ticked and blank.
    func testAnEmptyLayerSaysNoneHere() throws {
        var collection = Sample.collection()
        collection.featuresByLayer[TerrainLayer.bathymetry] = []
        let scene = try SceneBuilder().build(from: collection)

        let bathymetry = try XCTUnwrap(
            LayerInventory.entries(for: scene).first { $0.layerID == TerrainLayer.bathymetry }
        )
        XCTAssertFalse(bathymetry.hasData)
        XCTAssertEqual(bathymetry.countText, "none here")
    }

    /// A summit is text, not linework, so its count has to come from the labels.
    func testALabelLayerCountsItsLabels() throws {
        let scene = try Sample.scene()
        let summits = try XCTUnwrap(
            LayerInventory.entries(for: scene).first { $0.layerID == TerrainLayer.summits }
        )
        XCTAssertTrue(summits.isLabels)
        XCTAssertEqual(summits.count, 1)
        XCTAssertEqual(summits.label, "Summit heights")
    }

    /// An empty row is information, but it should not push the map's actual
    /// contents down the panel.
    func testPopulatedLayersComeFirstInsideAGroup() throws {
        var collection = Sample.collection()
        collection.featuresByLayer[TerrainLayer.bathymetry] = []
        let scene = try SceneBuilder().build(from: collection)

        let terrain = LayerInventory.entries(for: scene).filter { $0.group == "Terrain" }
        let firstEmpty = terrain.firstIndex { !$0.hasData } ?? terrain.count
        let lastPopulated = terrain.lastIndex { $0.hasData } ?? -1
        XCTAssertLessThan(lastPopulated, firstEmpty, "an empty layer was listed above a populated one")
    }

    /// The road hierarchy is eight layers to the renderer and one idea to a reader.
    func testTheWholeRoadFamilyLandsInOneGroup() {
        for layer in [
            "roads", "roads_motorway", "roads_trunk", "roads_primary",
            "roads_secondary", "roads_tertiary", "roads_residential",
            "roads_service", "roads_other",
        ] {
            XCTAssertEqual(LayerInventory.group(for: layer), "Movement", layer)
        }
    }

    func testGroupsComeOutInReadingOrder() throws {
        let scene = try Sample.scene()
        let names = LayerInventory.grouped(for: scene).map(\.group)
        XCTAssertEqual(names, ["Terrain"], "the terrain slice is all one group")

        // And the declared order is the panel's order.
        let order = LayerInventory.groupOrder
        XCTAssertEqual(order.first, "Terrain")
        XCTAssertEqual(order.last, "Derived")
    }

    /// A ferry route is transport, and reads beside the railways rather than in
    /// with the lakes.
    func testFerryRoutesReadAsMovementRatherThanWater() {
        XCTAssertEqual(LayerInventory.label(for: "ferry_routes"), "Ferry routes")
        XCTAssertEqual(LayerInventory.group(for: "ferry_routes"), "Movement")
        XCTAssertEqual(LayerInventory.group(for: "water"), "Water & land")
    }

    /// No preset styles the layer, so it takes the fallback hairline — which is the
    /// designed behaviour for a layer a preset says nothing about, and is why a new
    /// layer shows up as *something* the first time it appears.
    func testAnUnstyledLayerIsAHairlineAndNotFilled() {
        let style = Presets.preset("Hypsometric Relief").styleProfile.style(for: "ferry_routes")
        XCTAssertFalse(style.fillEnabled, "a route must never be filled")
        XCTAssertGreaterThan(style.strokeWidth, 0, "a route nobody styled must still be visible")
    }

    func testAnUnknownLayerStillGetsAReadableName() {
        XCTAssertEqual(LayerInventory.label(for: "zebra_crossings"), "Zebra crossings")
        XCTAssertEqual(LayerInventory.group(for: "zebra_crossings"), "Derived")
    }

    /// `100 000` reads faster than `100000`.
    func testLargeCountsAreSpaced() throws {
        var layer = RenderLayer(name: "terrain_contours")
        for index in 0..<12_345 {
            layer.append(.point(Coordinate(x: Double(index), y: 0)))
        }
        let scene = RenderScene(layers: [layer])
        let entry = try XCTUnwrap(LayerInventory.entries(for: scene).first)
        XCTAssertEqual(entry.countText, "12 345")
    }

    func testTheSummaryCountsOnlyWhatIsThere() throws {
        XCTAssertEqual(LayerInventory.summary(for: try Sample.scene()), "5 layers · 6 features")
        XCTAssertEqual(LayerInventory.summary(for: RenderScene()), "Nothing to draw")
    }
}
