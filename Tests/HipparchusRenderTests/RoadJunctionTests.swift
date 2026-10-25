import CoreGraphics
import Foundation
import HipparchusData
import HipparchusGeometry
import XCTest
@testable import HipparchusRender

/// Where a minor street meets a major road, the major road runs on unbroken.
///
/// Each road class is a layer of its own, and a layer lays its casing down before
/// its line — so within one class a junction reads as one. Across classes it did
/// not: the classes were drawn major to minor, so every residential street painted
/// its casing and its line straight across the secondary road it met, and on a
/// city sheet the orange roads came out beaded, broken at every crossing.
///
/// The network is drawn as one: every class's casing first, then the lines from
/// minor to major, so a major road's line is the last ink at its junctions and a
/// minor street's line still reaches the major road's edge.
final class RoadJunctionTests: XCTestCase {

    private static let side = 200.0
    private static let major = RGBAColor(255, 0, 0)
    private static let minor = RGBAColor(0, 0, 255)

    /// A secondary road running east–west and a residential street running
    /// north–south, crossing at the centre of the frame.
    private func crossing() throws -> RenderScene {
        func road(_ highway: String, _ id: String, from: Coordinate, to: Coordinate) -> Feature {
            Feature(
                id: id, layer: "roads", source: "overpass",
                geometry: .lineString(LineString([from, to])),
                provenance: .measured,
                properties: ["highway": .string(highway)]
            )
        }
        let built = try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: ["roads": [
                road("secondary", "way/1",
                     from: Coordinate(lon: 23.0, lat: 37.05), to: Coordinate(lon: 23.1, lat: 37.05)),
                road("residential", "way/2",
                     from: Coordinate(lon: 23.05, lat: 37.0), to: Coordinate(lon: 23.05, lat: 37.1)),
            ]],
            metadata: ["source": .string("overpass")],
            bbox: BoundingBox(minLon: 23.0, minLat: 37.0, maxLon: 23.1, maxLat: 37.1),
            provenance: .measured
        ))
        // The builder decides the order; the colours are fixed here so the pixels
        // can say which road was drawn last.
        let layers = built.layers.map { layer -> RenderLayer in
            var restyled = layer
            switch layer.name {
            case "roads_secondary":
                restyled.style = Self.style(line: Self.major, width: 10, casing: 18)
            case "roads_residential":
                restyled.style = Self.style(line: Self.minor, width: 6, casing: 12)
            default:
                restyled.style.visible = false
            }
            return restyled
        }
        return RenderScene(layers: layers, background: RGBAColor(255, 255, 255))
    }

    private static func style(line: RGBAColor, width: Double, casing: Double) -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeWidth = width
        style.strokeColor = line
        style.casingWidth = casing
        style.casingColor = RGBAColor(0, 0, 0)
        style.lineCap = .butt
        return style
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let index = y * image.bytesPerRow + x * 4
        return (data[index], data[index + 1], data[index + 2])
    }

    func testAMajorRoadRunsUnbrokenThroughAMinorJunction() throws {
        var options = CoreGraphicsRenderer.Options()
        options.drawNotForNavigation = false
        options.drawLabels = false
        let image = try XCTUnwrap(CoreGraphicsRenderer(options: options).image(
            of: try crossing(), size: CGSize(width: Self.side, height: Self.side), margin: 20
        ))
        let centre = Int(Self.side / 2)

        let atCrossing = try pixel(image, x: centre, y: centre)
        XCTAssertEqual(
            [atCrossing.r, atCrossing.g, atCrossing.b], [255, 0, 0],
            "the residential street was drawn across the secondary road"
        )

        // On the residential street, between the secondary's line (5 px either
        // side) and its casing (9 px): the minor line must reach the major edge,
        // not be capped by the major road's casing.
        let atMouth = try pixel(image, x: centre, y: centre + 7)
        XCTAssertEqual(
            [atMouth.r, atMouth.g, atMouth.b], [0, 0, 255],
            "the secondary road's casing was drawn across the mouth of the residential street"
        )
    }

    /// The SVG is the same picture: every road casing in the run is written
    /// before any road line, and the layer groups keep their own line.
    func testTheSVGWritesEveryRoadCasingBeforeAnyRoadLine() throws {
        var options = SVGExporter.Options()
        options.width = Int(Self.side)
        options.height = Int(Self.side)
        let text = SVGExporter(options: options).svg(for: try crossing())

        func position(_ id: String) throws -> String.Index {
            try XCTUnwrap(text.range(of: "id=\"\(id)\"")?.lowerBound, "no \(id) in the export")
        }
        XCTAssertLessThan(
            try position("roads_secondary_casing"), try position("roads_residential"),
            "a road line was written before the secondary road's casing"
        )
        XCTAssertLessThan(
            try position("roads_residential_casing"), try position("roads_secondary"),
            "the residential casing was written over the secondary road"
        )
        XCTAssertLessThan(
            try position("roads_residential"), try position("roads_secondary"),
            "the minor road's line was written over the major road's"
        )
    }
}
