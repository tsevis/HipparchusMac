import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Simplification must not collapse small polygons.
///
/// Ported from `_optimize_layer_geometries` / `_polygon_tolerance_cap`: on the
/// polygon layers, each feature's tolerance is capped by a fraction of its own
/// smallest dimension — 0.08 for buildings, 0.2 elsewhere — so a preset tuned
/// for sweeping coastlines cannot flatten a house into a sliver on the way.
final class SimplificationCapTests: XCTestCase {

    // MARK: - The rule

    func testBuildingsAreCappedTighterThanLandCover() {
        let square = Geometry.polygon(Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 0),
            Coordinate(x: 100, y: 100), Coordinate(x: 0, y: 100),
        ]))
        XCTAssertEqual(SceneBuilder.toleranceCap(for: square, layer: "buildings") ?? -1, 8.0)
        XCTAssertEqual(SceneBuilder.toleranceCap(for: square, layer: "water") ?? -1, 20.0)
        XCTAssertEqual(SceneBuilder.toleranceCap(for: square, layer: "parks") ?? -1, 20.0)
    }

    /// Line layers are not capped — a capped road would never simplify at all.
    func testLineLayersAreNotCapped() {
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 0),
        ]))
        XCTAssertNil(SceneBuilder.toleranceCap(for: line, layer: "roads_primary"))
        XCTAssertNil(SceneBuilder.toleranceCap(for: line, layer: "terrain_contours"))
    }

    /// A line that landed in a polygon layer is left alone entirely, as the
    /// Python leaves it: a cap of zero means no simplification.
    func testALineInAPolygonLayerIsLeftAlone() {
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 0),
        ]))
        XCTAssertEqual(SceneBuilder.toleranceCap(for: line, layer: "coastline"), 0)
    }

    // MARK: - Through the pipeline

    /// The point of the whole rule: a preset tuned coarse enough to mangle a
    /// small building is allowed to simplify the roads and forbidden to touch
    /// the house.
    func testACoarsePresetSimplifiesRoadsButNotTheHouse() throws {
        let bbox = BoundingBox(minLon: 23.70, minLat: 37.90, maxLon: 23.72, maxLat: 37.92)

        // A ~22 m house drawn with midpoints on each wall: honest extra vertices
        // a simplifier may remove, around corners it must not.
        let side = 0.0002
        let (x, y) = (23.705, 37.905)
        var wall: [Coordinate] = []
        for corner in [(0.0, 0.0), (side, 0.0), (side, side), (0.0, side)] {
            wall.append(Coordinate(lon: x + corner.0, lat: y + corner.1))
        }
        let house = Feature(
            id: "b/0", layer: "buildings", source: "test",
            geometry: .polygon(Polygon(exterior: wall)), provenance: .measured
        )

        // A road with 5 m wiggles a 50-unit tolerance should iron flat.
        var wiggles: [Coordinate] = []
        for step in 0...40 {
            wiggles.append(Coordinate(
                lon: 23.700 + Double(step) * 0.0005,
                lat: 37.910 + (step.isMultiple(of: 2) ? 0.00005 : -0.00005)
            ))
        }
        let road = Feature(
            id: "r/0", layer: "roads", source: "test",
            geometry: .lineString(LineString(wiggles)), provenance: .measured,
            properties: ["highway": .string("primary")]
        )

        var profile = Presets.preset("Hypsometric Relief").geometryProfile
        profile.simplifyTolerancePreview = 50
        let preset = ArtisticPreset(
            name: "Coarse", geometryProfile: profile,
            styleProfile: Presets.preset("Hypsometric Relief").styleProfile
        )
        // Named rather than left to the default: the tolerance under test is
        // `simplifyTolerancePreview`, and Print Export — now the default —
        // simplifies nothing at all, so the default would test the opposite of
        // what this is about.
        let scene = try SceneBuilder(options: SceneBuilder.Options(
            preset: preset, quality: Quality.profile("preview_fast")
        ))
            .build(from: FeatureCollection(
                featuresByLayer: ["buildings": [house], "roads": [road]],
                metadata: [:], bbox: bbox, provenance: .measured
            ))

        guard case .polygon(let simplified)? =
            scene.layers.first(where: { $0.name == "buildings" })?.geometries.first
        else {
            return XCTFail("the house went missing")
        }
        // Four corners plus closure: the cap held the tolerance below anything
        // that could move a wall.
        XCTAssertGreaterThanOrEqual(simplified.exterior.coordinates.count, 5)

        guard case .lineString(let flattened)? =
            scene.layers.first(where: { $0.name == "roads_primary" })?.geometries.first
        else {
            return XCTFail("the road went missing")
        }
        XCTAssertLessThan(
            flattened.coordinates.count, 41,
            "the tolerance never fired at all — the cap is not what saved the house"
        )
    }
}
