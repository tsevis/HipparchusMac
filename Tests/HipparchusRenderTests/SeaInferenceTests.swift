import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// The sea, inferred from a coastline that only describes its edge.
///
/// Ported from `_derive_sea_polygons`. OSM gives a coastline as open ways, not as
/// a filled ocean, so a coastal sheet drawn from the linework alone has a line
/// where the water should be. The frame boundary and the coastline together cut
/// the page into faces; the face with the least evidence of land on it is the
/// sea.
///
/// Measured, never assumed — the same principle as elevation bands, which sample
/// the field at each face rather than reasoning about ring nesting.
final class SeaInferenceTests: XCTestCase {

    private let bbox = BoundingBox(minLon: 23.0, minLat: 37.0, maxLon: 23.1, maxLat: 37.1)

    /// A coast running north–south through the middle of the frame.
    private func coastline() -> Feature {
        Feature(
            id: "c/0", layer: "coastline", source: "test",
            geometry: .lineString(LineString([
                Coordinate(lon: 23.05, lat: 36.95), Coordinate(lon: 23.05, lat: 37.15),
            ])),
            provenance: .measured
        )
    }

    /// Buildings on the eastern half, which is therefore the land.
    private func buildings(count: Int = 6) -> [Feature] {
        (0..<count).map { index in
            let x = 23.06 + Double(index) * 0.005
            return Feature(
                id: "b/\(index)", layer: "buildings", source: "test",
                geometry: .polygon(Polygon(exterior: [
                    Coordinate(lon: x, lat: 37.04), Coordinate(lon: x + 0.002, lat: 37.04),
                    Coordinate(lon: x + 0.002, lat: 37.06), Coordinate(lon: x, lat: 37.06),
                ])),
                provenance: .measured
            )
        }
    }

    private func scene(_ featuresByLayer: [String: [Feature]]) throws -> RenderScene {
        try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [:], bbox: bbox, provenance: .measured
        ))
    }

    private func water(_ scene: RenderScene) -> RenderLayer? {
        scene.layers.first { $0.name == "water" }
    }

    // MARK: - The rule

    func testACoastlineWithLandOnOneSideFillsTheOtherWithSea() throws {
        let scene = try scene(["coastline": [coastline()], "buildings": buildings()])

        let water = try XCTUnwrap(water(scene), "no water layer was made for the sea")
        XCTAssertEqual(water.geometries.count, 1, "expected exactly one sea face")

        // The sea is the western half: its centre must be west of the coast.
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        let coast = projection.project(Coordinate(lon: 23.05, lat: 37.05)).x
        let bounds = try XCTUnwrap(water.geometries.first?.bounds)
        XCTAssertLessThan((bounds.minX + bounds.maxX) / 2, coast, "the sea was drawn over the land")
    }

    /// Provenance holds: the sea is inferred, and the scene says so.
    func testTheInferredSeaIsRecordedInTheDiagnostics() throws {
        let scene = try scene(["coastline": [coastline()], "buildings": buildings()])
        XCTAssertEqual(scene.diagnostics["inferred_sea_polygons"]?.doubleValue, 1)
    }

    // MARK: - When it must not fire

    func testNoCoastlineMeansNoSea() throws {
        let scene = try scene(["buildings": buildings()])
        XCTAssertNil(water(scene)?.geometries.first)
    }

    /// With nothing to tell the halves apart, guessing would be worse than
    /// leaving the page as the data left it.
    func testAFrameWithNoLandEvidenceIsLeftAlone() throws {
        let scene = try scene(["coastline": [coastline()]])
        XCTAssertNil(water(scene), "a sea was invented with no evidence either way")
    }

    /// A coastline that does not divide the frame divides nothing.
    func testACoastlineThatDoesNotCrossTheFrameMakesNoSea() throws {
        let stub = Feature(
            id: "c/0", layer: "coastline", source: "test",
            geometry: .lineString(LineString([
                Coordinate(lon: 23.02, lat: 37.02), Coordinate(lon: 23.03, lat: 37.03),
            ])),
            provenance: .measured
        )
        let scene = try scene(["coastline": [stub], "buildings": buildings()])
        XCTAssertNil(water(scene)?.geometries.first)
    }

    // MARK: - Living with the water that was fetched

    /// Real water keeps its place; the sea goes underneath it.
    func testFetchedWaterSurvivesAndTheSeaGoesUnderIt() throws {
        let lake = Feature(
            id: "w/0", layer: "water", source: "test",
            geometry: .polygon(Polygon(exterior: [
                Coordinate(lon: 23.07, lat: 37.07), Coordinate(lon: 23.08, lat: 37.07),
                Coordinate(lon: 23.08, lat: 37.08), Coordinate(lon: 23.07, lat: 37.08),
            ])),
            provenance: .measured
        )
        let scene = try scene([
            "coastline": [coastline()], "buildings": buildings(), "water": [lake],
        ])

        let water = try XCTUnwrap(water(scene))
        XCTAssertEqual(water.geometries.count, 2)
        // Drawn first, so the lake is not buried under the sea.
        let first = try XCTUnwrap(water.geometries.first?.bounds)
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        XCTAssertLessThan(
            (first.minX + first.maxX) / 2,
            projection.project(Coordinate(lon: 23.05, lat: 37.05)).x,
            "the sea should be the first geometry in the layer"
        )
        // And the layer still reports only what the provider actually returned.
        XCTAssertEqual(water.rawFeatureCount, 1)
    }

    /// Nothing is inferred when the map is not being trimmed to a frame: the
    /// faces are cut by the frame's own edges, so without one there are none.
    func testNoFrameMeansNoInference() throws {
        let scene = try SceneBuilder(options: SceneBuilder.Options(clipToArea: false))
            .build(from: FeatureCollection(
                featuresByLayer: ["coastline": [coastline()], "buildings": buildings()],
                metadata: [:], bbox: bbox, provenance: .measured
            ))
        XCTAssertNil(water(scene)?.geometries.first)
    }
}
