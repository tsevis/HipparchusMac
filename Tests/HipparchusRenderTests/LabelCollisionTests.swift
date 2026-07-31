import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Labels must not pile on top of one another, at any scale.
///
/// The Python reserves a fixed box around each label — 50 units wide, 20 tall —
/// in **projected** space, and its own docstring calls that "obvious
/// projected-space overlap". In Web Mercator those units are metres, so the box
/// means something completely different depending on how much ground the sheet
/// shows: a few pixels across a city, and far less than one pixel across an
/// island chain. On a render of Hawaii every summit label landed on top of its
/// neighbour, because no two boxes could ever be found to overlap.
///
/// Here the box is a fraction of the frame instead, so it means the same thing
/// whatever the sheet covers. That is a deliberate divergence from the Python,
/// and this is the evidence for it.
final class LabelCollisionTests: XCTestCase {

    /// Summits crowded within a few kilometres of each other, as a volcanic
    /// island gives, over a frame of the requested width in degrees.
    private func scene(degreesWide: Double) throws -> RenderScene {
        let bbox = BoundingBox(
            minLon: -156.0, minLat: 19.0,
            maxLon: -156.0 + degreesWide, maxLat: 19.0 + degreesWide
        )
        // Twelve summits spread over the middle tenth of the frame: close
        // together on the page however wide the ground beneath them is.
        let features = (0..<12).map { index in
            let step = degreesWide * 0.1 * Double(index) / 12
            return Feature(
                id: "s/\(index)", layer: TerrainLayer.summits, source: "test",
                geometry: .point(Coordinate(
                    lon: bbox.minLon + degreesWide * 0.45 + step,
                    lat: bbox.minLat + degreesWide * 0.45 + step
                )),
                provenance: .measured,
                properties: ["name": .string("\(4000 + index * 11) m"), "elevation": .double(4000)]
            )
        }
        return try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: [TerrainLayer.summits: features],
            metadata: [:], bbox: bbox, provenance: .measured
        ))
    }

    private func labels(_ scene: RenderScene) -> [PlaceLabel] {
        scene.layers.first { $0.name == TerrainLayer.summits }?.labels ?? []
    }

    /// The case the Hawaii render exposed: a wide frame thinned nothing.
    func testCrowdedLabelsAreThinnedOnAWideFrameToo() throws {
        let island = try labels(scene(degreesWide: 0.2))
        let archipelago = try labels(scene(degreesWide: 12.0))

        XCTAssertLessThan(island.count, 12, "nothing was thinned even on a small frame")
        XCTAssertLessThan(
            archipelago.count, 12,
            "a wide frame thinned nothing — the collision box is in ground units again"
        )
    }

    /// Scale independence is the actual property. The same arrangement of
    /// labels, drawn over ten times the ground, must thin to the same extent —
    /// because it looks identical on the page.
    func testThinningDoesNotDependOnHowMuchGroundTheSheetShows() throws {
        let narrow = try labels(scene(degreesWide: 0.2)).count
        let wide = try labels(scene(degreesWide: 2.0)).count
        let widest = try labels(scene(degreesWide: 12.0)).count

        XCTAssertEqual(narrow, wide, "the same page thinned differently at a different scale")
        XCTAssertEqual(wide, widest)
    }

    /// Thinning must not become so eager that a sparse map loses labels it has
    /// room for. Four summits at the corners of the frame all survive.
    func testLabelsWithRoomAroundThemAreAllKept() throws {
        let bbox = BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)
        let corners = [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)]
        let features = corners.enumerated().map { index, corner in
            Feature(
                id: "s/\(index)", layer: TerrainLayer.summits, source: "test",
                geometry: .point(Coordinate(lon: corner.0, lat: corner.1)),
                provenance: .measured,
                properties: ["name": .string("Peak \(index)"), "elevation": .double(100)]
            )
        }
        let scene = try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: [TerrainLayer.summits: features],
            metadata: [:], bbox: bbox, provenance: .measured
        ))
        XCTAssertEqual(labels(scene).count, 4, "labels with room around them were dropped")
    }

    /// A longer name reserves more room, or two long names still collide.
    func testALongerNameReservesMoreRoom() {
        let frame = Bounds(minX: 0, minY: 0, maxX: 1000, maxY: 1000)
        let short = SceneBuilder.labelBox(
            for: PlaceLabel(name: "A", position: Coordinate(x: 500, y: 500)), in: frame
        )
        let long = SceneBuilder.labelBox(
            for: PlaceLabel(name: "Mauna Kea Observatory", position: Coordinate(x: 500, y: 500)),
            in: frame
        )
        XCTAssertGreaterThan(long.width, short.width)
        XCTAssertEqual(long.height, short.height, accuracy: 1e-9, "type does not grow taller")
    }
}
