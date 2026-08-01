import HipparchusGeometry
import XCTest
@testable import HipparchusRender

/// One multiplier over every stroke.
///
/// The point of the control is that it moves the *absolute* scale and leaves the
/// preset's *relative* weights alone — a motorway stays wider than a footpath by
/// the ratio the preset chose. Most of what follows is checking that ratios
/// survive.
final class LineWeightTests: XCTestCase {

    private func scene(_ widths: [String: (stroke: Double, casing: Double)]) -> RenderScene {
        RenderScene(layers: widths.keys.sorted().map { name in
            var style = LayerStyle()
            style.strokeWidth = widths[name]!.stroke
            style.casingWidth = widths[name]!.casing
            return RenderLayer(name: name, style: style)
        })
    }

    private func widths(_ scene: RenderScene) -> [String: (stroke: Double, casing: Double)] {
        Dictionary(uniqueKeysWithValues: scene.layers.map {
            ($0.name, ($0.style.strokeWidth, $0.style.casingWidth))
        })
    }

    // MARK: -

    func testEveryStrokeAndCasingIsMultiplied() {
        let before = scene([
            "roads_motorway": (3.2, 4.3),
            "roads_service": (0.6, 1.7),
            "terrain_contours": (0.3, 0.0),
        ])
        let after = widths(before.scalingLineWeights(by: 2.5))

        XCTAssertEqual(after["roads_motorway"]!.stroke, 8.0, accuracy: 1e-12)
        XCTAssertEqual(after["roads_motorway"]!.casing, 10.75, accuracy: 1e-12)
        XCTAssertEqual(after["roads_service"]!.stroke, 1.5, accuracy: 1e-12)
        XCTAssertEqual(after["terrain_contours"]!.stroke, 0.75, accuracy: 1e-12)
        // A layer with no casing does not acquire one.
        XCTAssertEqual(after["terrain_contours"]!.casing, 0.0, accuracy: 1e-12)
    }

    /// The design is the ratios. Whatever the multiplier, a motorway has to stay
    /// the same multiple of a service road.
    func testTheRelativeWeightsThePresetChoseAreUnchanged() {
        let before = scene([
            "roads_motorway": (3.2, 4.3),
            "roads_primary": (2.3, 3.4),
            "roads_service": (0.6, 1.7),
        ])
        let ratio = 3.2 / 0.6

        for scale in [0.25, 0.5, 1.0, 1.7, 4.0] {
            let after = widths(before.scalingLineWeights(by: scale))
            XCTAssertEqual(
                after["roads_motorway"]!.stroke / after["roads_service"]!.stroke,
                ratio, accuracy: 1e-12,
                "scale \(scale) changed the preset's relative weights"
            )
        }
    }

    func testOneIsExactlyTheSceneItWasGiven() {
        let before = scene(["water": (0.6, 0.0), "roads": (1.0, 2.1)])
        let after = widths(before.scalingLineWeights(by: 1.0))
        XCTAssertEqual(after["water"]!.stroke, 0.6, accuracy: 1e-12)
        XCTAssertEqual(after["roads"]!.casing, 2.1, accuracy: 1e-12)
    }

    /// Nonsense in leaves the scene alone rather than erasing every line on it.
    func testAnUnusableScaleIsRefusedRatherThanApplied() {
        let before = scene(["roads": (1.5, 2.6)])
        for scale in [0.0, -2.0, Double.nan, Double.infinity] {
            let after = widths(before.scalingLineWeights(by: scale))
            XCTAssertEqual(after["roads"]!.stroke, 1.5, accuracy: 1e-12, "scale \(scale)")
            XCTAssertEqual(after["roads"]!.casing, 2.6, accuracy: 1e-12, "scale \(scale)")
        }
    }

    /// A label halo is sized against the type, and the type is not getting
    /// bigger. Scaling it with the strokes fattens every label's outline until
    /// the text inside disappears.
    func testLabelHalosDoNotScaleWithTheLines() {
        var style = LayerStyle()
        style.strokeWidth = 1.0
        style.labelHaloWidth = 2.0
        let before = RenderScene(layers: [RenderLayer(name: "places", style: style)])

        let after = before.scalingLineWeights(by: 4.0)
        XCTAssertEqual(after.layers[0].style.strokeWidth, 4.0, accuracy: 1e-12)
        XCTAssertEqual(after.layers[0].style.labelHaloWidth, 2.0, accuracy: 1e-12)
    }

    /// Scaling must not disturb anything else on the scene — it is a copy with
    /// wider strokes, not a rebuild.
    func testNothingElseAboutTheSceneMoves() {
        var style = LayerStyle()
        style.strokeWidth = 1.0
        style.fillColor = RGBAColor(10, 20, 30, 200)
        style.opacity = 0.4
        style.visible = false
        let layer = RenderLayer(name: "water", style: style)
        let before = RenderScene(
            layers: [layer],
            background: RGBAColor(9, 9, 9),
            metadata: ["source": .string("overpass")]
        )

        let after = before.scalingLineWeights(by: 3.0)
        XCTAssertEqual(after.layers[0].style.fillColor, RGBAColor(10, 20, 30, 200))
        XCTAssertEqual(after.layers[0].style.opacity, 0.4, accuracy: 1e-12)
        XCTAssertFalse(after.layers[0].style.visible)
        XCTAssertEqual(after.background, RGBAColor(9, 9, 9))
        XCTAssertEqual(after.metadata["source"]?.stringValue, "overpass")
        XCTAssertEqual(after.layers.count, 1)
    }

    // MARK: - Relief over the built environment

    private func ordered(_ names: [String]) -> RenderScene {
        RenderScene(layers: names.map { RenderLayer(name: $0, style: LayerStyle()) })
    }

    /// Lifted, the shading sits above everything structural and below the type.
    /// Nothing is worth burying a place name for.
    func testRaisingReliefPutsItAboveTheBuildingsAndBelowTheLabels() {
        let scene = ordered([
            "water", "elevation_bands", "terrain_hillshade", "terrain_contours",
            "buildings", "roads_primary", "railways", "places", "street_names",
        ])
        let names = scene.raisingReliefOverTheBuiltEnvironment().layers.map(\.name)

        let relief = try? XCTUnwrap(names.firstIndex(of: "terrain_hillshade"))
        let buildings = try? XCTUnwrap(names.firstIndex(of: "buildings"))
        let roads = try? XCTUnwrap(names.firstIndex(of: "roads_primary"))
        let places = try? XCTUnwrap(names.firstIndex(of: "places"))

        XCTAssertGreaterThan(relief ?? 0, buildings ?? 0, "relief should be over the buildings")
        XCTAssertGreaterThan(relief ?? 0, roads ?? 0, "relief should be over the roads")
        XCTAssertLessThan(relief ?? 0, places ?? 0, "labels stay on top")
        XCTAssertEqual(Set(names), Set(scene.layers.map(\.name)), "no layer was lost or duplicated")
        XCTAssertEqual(names.count, scene.layers.count)
    }

    /// A sheet with no labels at all still has to place the relief, rather than
    /// leaving it where it was because it found nothing to sit under.
    func testWithNoLabelsTheReliefGoesOnTop() {
        let names = ordered(["elevation_bands", "terrain_hillshade", "buildings", "roads"])
            .raisingReliefOverTheBuiltEnvironment().layers.map(\.name)
        XCTAssertEqual(names.last, "terrain_hillshade")
    }

    /// Most sheets have no shading on them at all; that must not disturb the
    /// order of everything else.
    func testASceneWithNoReliefIsUntouched() {
        let before = ordered(["water", "buildings", "roads", "places"])
        let after = before.raisingReliefOverTheBuiltEnvironment()
        XCTAssertEqual(after.layers.map(\.name), before.layers.map(\.name))
    }

    /// The scaled scene is what both the canvas and every exporter read, so a
    /// hairline that reads on screen is a hairline that lands in the file.
    func testTheScaledSceneIsWhatTheExportersSee() throws {
        var style = LayerStyle()
        style.strokeWidth = 0.5
        style.fillEnabled = false
        let line = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 10),
        ]))
        var layer = RenderLayer(name: "terrain_contours", style: style)
        layer.append(line)
        let scene = RenderScene(layers: [layer], bbox: BoundingBox(
            minLon: 0, minLat: 0, maxLon: 1, maxLat: 1
        ))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("line-weight-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try SVGExporter().write(scene.scalingLineWeights(by: 6.0), to: url)
        let svg = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(svg.contains("stroke-width=\"3\""), "the exporter drew the preset's width, not the scaled one")
    }
}
