import XCTest
import HipparchusData
import HipparchusGEOS
import HipparchusGeometry
@testable import HipparchusRender

/// One label per named street, on its longest run.
///
/// Ported from `_street_labels` in `application/scene_builder.py`. OSM splits a
/// street into a way per block, so labelling every feature would stamp the same
/// name dozens of times down one road. Keeping only the longest run per name puts
/// the label where the street is most legible and leaves the rest of the sheet
/// clear.
final class StreetLabelTests: XCTestCase {

    private let bbox = BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.1)

    private func road(
        _ name: String?, line: [Coordinate], id: Int = 0
    ) -> Feature {
        var properties: [String: PropertyValue] = ["highway": .string("residential")]
        if let name { properties["name"] = .string(name) }
        return Feature(
            id: "o/roads/\(id)", layer: "roads", source: "overpass",
            geometry: .lineString(LineString(line)),
            provenance: .measured,
            properties: properties
        )
    }

    private func scene(_ roads: [Feature]) throws -> RenderScene {
        try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: ["roads": roads],
            metadata: ["source": .string("overpass")],
            bbox: bbox,
            provenance: .measured
        ))
    }

    private func streetLayer(_ scene: RenderScene) -> RenderLayer? {
        scene.layers.first { $0.name == "street_names" }
    }

    // MARK: - The rule

    /// The reason the function exists: a street arriving as one way per block is
    /// one street to a reader, and gets one label.
    func testOneLabelPerNamedStreetHoweverManyWaysItArrivesAs() throws {
        let blocks = (0..<5).map { index in
            road("Ermou", line: [
                Coordinate(lon: 23.70 + Double(index) * 0.01, lat: 37.95),
                Coordinate(lon: 23.70 + Double(index + 1) * 0.01, lat: 37.95),
            ], id: index)
        }
        let scene = try self.scene(blocks)

        let layer = try XCTUnwrap(streetLayer(scene), "named streets produced no street_names layer")
        XCTAssertEqual(layer.labels.count, 1, "one street, one label")
        XCTAssertEqual(layer.labels.first?.name, "Ermou")
        XCTAssertEqual(layer.labels.first?.placeType, "street")
    }

    /// The label sits at the midpoint of the *longest* run, not the first one
    /// found — that is where the street is most legible.
    func testTheLabelAnchorsOnTheLongestRunsMidpoint() throws {
        let short = road("Main Street", line: [
            Coordinate(lon: 23.60, lat: 37.90), Coordinate(lon: 23.61, lat: 37.90),
        ], id: 0)
        let long = road("Main Street", line: [
            Coordinate(lon: 23.70, lat: 37.95), Coordinate(lon: 23.90, lat: 37.95),
        ], id: 1)
        let scene = try self.scene([short, long])

        let label = try XCTUnwrap(streetLayer(scene)?.labels.first)
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        let expected = projection.project(Coordinate(lon: 23.80, lat: 37.95))
        XCTAssertEqual(label.position.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(label.position.y, expected.y, accuracy: 1e-6)
    }

    /// A street split across a MultiLineString anchors on its longest member.
    func testAMultiLineStreetAnchorsOnItsLongestMember() throws {
        let feature = Feature(
            id: "o/roads/0", layer: "roads", source: "overpass",
            geometry: .multiLineString([
                LineString([Coordinate(lon: 23.60, lat: 37.90), Coordinate(lon: 23.62, lat: 37.90)]),
                LineString([Coordinate(lon: 23.70, lat: 37.95), Coordinate(lon: 23.80, lat: 37.95)]),
            ]),
            provenance: .measured,
            properties: ["highway": .string("residential"), "name": .string("Panepistimiou")]
        )
        let scene = try self.scene([feature])

        let label = try XCTUnwrap(streetLayer(scene)?.labels.first)
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        let expected = projection.project(Coordinate(lon: 23.75, lat: 37.95))
        XCTAssertEqual(label.position.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(label.position.y, expected.y, accuracy: 1e-6)
    }

    // MARK: - What does not get a label

    /// No names, no layer: matching the Python, `street_names` appears only when
    /// it has something to say, so an empty row never sits in the panel.
    func testUnnamedRoadsProduceNoStreetNamesLayer() throws {
        let scene = try self.scene([
            road(nil, line: [Coordinate(lon: 23.7, lat: 37.9), Coordinate(lon: 23.8, lat: 37.9)]),
        ])
        XCTAssertNil(streetLayer(scene))
    }

    /// A name that is only whitespace is no name.
    func testWhitespaceNamesAreNoNames() throws {
        let scene = try self.scene([
            road("   ", line: [Coordinate(lon: 23.7, lat: 37.9), Coordinate(lon: 23.8, lat: 37.9)]),
        ])
        XCTAssertNil(streetLayer(scene))
    }

    /// Providers return everything that touches the area, so a street whose
    /// longest run lies mostly outside the frame anchors outside it — and a label
    /// nobody can see must not spend the budget.
    func testAnAnchorOutsideTheFrameIsDropped() throws {
        let scene = try self.scene([
            road("Leoforos Marathonos", line: [
                Coordinate(lon: 23.95, lat: 37.90), Coordinate(lon: 24.35, lat: 37.90),
            ]),
        ])
        XCTAssertNil(streetLayer(scene), "an off-frame anchor still produced a label")
    }

    // MARK: - The budget

    /// Only the longest streets make the sheet when the cap bites. The default cap
    /// is 160, as in the Python; the rule is what matters, so it is tested small.
    func testTheLongestStreetsWinTheBudget() throws {
        let roads = [
            road("Short", line: [Coordinate(lon: 23.70, lat: 37.90), Coordinate(lon: 23.71, lat: 37.90)], id: 0),
            road("Middling", line: [Coordinate(lon: 23.70, lat: 37.92), Coordinate(lon: 23.75, lat: 37.92)], id: 1),
            road("Longest", line: [Coordinate(lon: 23.70, lat: 37.94), Coordinate(lon: 23.90, lat: 37.94)], id: 2),
        ]
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        let labels = SceneBuilder.streetLabels(
            from: roads, projection: projection, geos: GEOSContext(), maxStreets: 2
        )
        XCTAssertEqual(labels.map(\.name).sorted(), ["Longest", "Middling"])
    }

    /// A degenerate run — a way whose vertices coincide — has no length to be
    /// longest and no direction to anchor along.
    func testAZeroLengthWayProducesNothing() throws {
        let scene = try self.scene([
            road("Ghost", line: [Coordinate(lon: 23.7, lat: 37.9), Coordinate(lon: 23.7, lat: 37.9)]),
        ])
        XCTAssertNil(streetLayer(scene))
    }
}
