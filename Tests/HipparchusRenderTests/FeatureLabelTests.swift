import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Labels come from geometry of every shape, not only from points.
///
/// Ported from `extract_labels` in `application/scene_builder.py`, which anchors
/// a LineString or Polygon label at the average of its coordinates. The port
/// originally labelled only point features, which silently disconnected four
/// layers whose features are never points: earthquakes are drawn as circles
/// (polygons), satellite tracks as lines — both styled, budgeted and typed for
/// labels that could never exist. A named shop mapped as a building outline
/// vanished the same way: no stroke in the presets, and no label either.
final class FeatureLabelTests: XCTestCase {

    private let bbox = BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.1)

    private func scene(_ layer: String, _ geometry: Geometry, name: String, properties: [String: PropertyValue] = [:]) throws -> RenderScene {
        var props = properties
        props["name"] = .string(name)
        let feature = Feature(
            id: "t/\(layer)/0", layer: layer, source: "test",
            geometry: geometry, provenance: .measured, properties: props
        )
        return try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: [layer: [feature]],
            metadata: [:], bbox: bbox, provenance: .measured
        ))
    }

    private func labels(_ scene: RenderScene, _ layer: String) -> [PlaceLabel] {
        scene.layers.first { $0.name == layer }?.labels ?? []
    }

    /// An earthquake is drawn as a circle, and its magnitude is the label.
    func testAPolygonalEarthquakeCarriesItsMagnitudeLabel() throws {
        let ring = [
            Coordinate(lon: 23.70, lat: 37.90), Coordinate(lon: 23.72, lat: 37.90),
            Coordinate(lon: 23.72, lat: 37.92), Coordinate(lon: 23.70, lat: 37.92),
        ]
        let scene = try scene(
            EarthquakeLayer.shallow, .polygon(Polygon(exterior: ring)), name: "M 5.2"
        )
        let found = labels(scene, EarthquakeLayer.shallow)
        XCTAssertEqual(found.map(\.name), ["M 5.2"])
        XCTAssertEqual(found.first?.placeType, "earthquake")

        // Anchored at the average of the ring's coordinates — including the
        // closing vertex, which counts the first corner twice. That is what the
        // Python computes over a GeoJSON ring (closed by spec), and on a
        // 48-segment earthquake circle the skew is invisible.
        let closed = ring + [ring[0]]
        let average = Coordinate(
            lon: closed.map(\.x).reduce(0, +) / Double(closed.count),
            lat: closed.map(\.y).reduce(0, +) / Double(closed.count)
        )
        let projection = ProjectionProfile(bbox: bbox, mode: Quality.default.projectionMode)
        let expected = projection.project(average)
        XCTAssertEqual(found.first?.position.x ?? .nan, expected.x, accuracy: 1e-6)
        XCTAssertEqual(found.first?.position.y ?? .nan, expected.y, accuracy: 1e-6)
    }

    /// A satellite track is a line, and its one label is the satellite's name.
    func testASatelliteTrackCarriesItsName() throws {
        let scene = try scene(
            SatelliteLayer.tracks,
            .lineString(LineString([
                Coordinate(lon: 23.6, lat: 37.85), Coordinate(lon: 23.9, lat: 38.05),
            ])),
            name: "ISS (ZARYA)"
        )
        let found = labels(scene, SatelliteLayer.tracks)
        XCTAssertEqual(found.map(\.name), ["ISS (ZARYA)"])
        XCTAssertEqual(found.first?.placeType, "satellite")
    }

    /// A restaurant mapped as its building outline is still a restaurant.
    func testAPolygonalAmenityIsLabelled() throws {
        let ring = [
            Coordinate(lon: 23.70, lat: 37.90), Coordinate(lon: 23.701, lat: 37.90),
            Coordinate(lon: 23.701, lat: 37.901), Coordinate(lon: 23.70, lat: 37.901),
        ]
        let scene = try scene(
            "amenities", .polygon(Polygon(exterior: ring)),
            name: "Taverna", properties: ["amenity": .string("restaurant")]
        )
        let found = labels(scene, "amenities")
        XCTAssertEqual(found.map(\.name), ["Taverna"])
        XCTAssertEqual(found.first?.placeType, "restaurant")
    }

    /// The geometry is still drawn: a label is in addition to the shape, where a
    /// point feature is a label *instead of* a shape.
    func testALabelledPolygonIsStillDrawn() throws {
        let ring = [
            Coordinate(lon: 23.70, lat: 37.90), Coordinate(lon: 23.72, lat: 37.90),
            Coordinate(lon: 23.72, lat: 37.92), Coordinate(lon: 23.70, lat: 37.92),
        ]
        let scene = try scene(
            EarthquakeLayer.shallow, .polygon(Polygon(exterior: ring)), name: "M 5.2"
        )
        XCTAssertEqual(scene.layers.first { $0.name == EarthquakeLayer.shallow }?.geometries.count, 1)
    }

    /// Roads and buildings do not label themselves this way — streets have their
    /// own rule (one label per name, on the longest run), and a named building
    /// outline is not a label layer in the Python either.
    func testNonLabelLayersAreLeftAlone() throws {
        let ring = [
            Coordinate(lon: 23.70, lat: 37.90), Coordinate(lon: 23.72, lat: 37.90),
            Coordinate(lon: 23.72, lat: 37.92), Coordinate(lon: 23.70, lat: 37.92),
        ]
        let scene = try scene("buildings", .polygon(Polygon(exterior: ring)), name: "Parliament")
        XCTAssertEqual(labels(scene, "buildings"), [])
    }
}
