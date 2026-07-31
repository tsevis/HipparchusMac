import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Map furniture on the SVG: title, scale bar, north arrow, legend.
///
/// Ported from `export/profiles.py` and the furniture half of
/// `export/svg_clean.py`, with `tests/test_export_profiles.py` and
/// `tests/test_svg_exporter.py` as the specification. All of it is off by
/// default — the map is the product, and furniture is asked for.
final class SVGCompositionTests: XCTestCase {

    private func scene(background: RGBAColor = RGBAColor(250, 250, 250)) -> RenderScene {
        var roads = RenderLayer(
            name: "roads", style: LayerStyle(strokeWidth: 1, fillEnabled: false), rawFeatureCount: 1
        )
        roads.append(.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 1000, y: 800),
        ])))
        return RenderScene(layers: [roads], background: background)
    }

    private func everything() -> SVGExporter.Composition {
        var composition = SVGExporter.Composition()
        composition.title = "Demo Map"
        composition.subtitle = "Composition test"
        composition.includeTitle = true
        composition.includeScaleBar = true
        composition.includeNorthArrow = true
        composition.includeLegend = true
        composition.paperPreset = "A4"
        return composition
    }

    // MARK: - Off by default

    func testFurnitureIsAbsentUnlessAskedFor() {
        let svg = SVGExporter().svg(for: scene())
        XCTAssertFalse(svg.contains("map_furniture"))
        XCTAssertFalse(svg.contains("north_arrow"))
        XCTAssertFalse(svg.contains("scale_bar"))
        XCTAssertFalse(svg.contains("map_legend"))
    }

    // MARK: - The furniture

    func testEveryPieceOfFurnitureAppearsWhenAskedFor() {
        var options = SVGExporter.Options()
        options.composition = everything()
        let svg = SVGExporter(options: options).svg(for: scene())

        XCTAssertTrue(svg.contains("id=\"map_furniture\""))
        XCTAssertTrue(svg.contains("id=\"map_title\""))
        XCTAssertTrue(svg.contains(">Demo Map</text>"))
        XCTAssertTrue(svg.contains(">Composition test</text>"))
        XCTAssertTrue(svg.contains("id=\"north_arrow\""))
        XCTAssertTrue(svg.contains(">N</text>"))
        XCTAssertTrue(svg.contains("id=\"scale_bar\""))
        XCTAssertTrue(svg.contains("id=\"map_legend\""))
    }

    /// The page declares what it was composed for, whether or not furniture is on
    /// — an importer can honour A4 landscape without parsing anything else.
    func testThePageDeclaresItsPaperAndOrientation() {
        var options = SVGExporter.Options()
        options.composition.paperPreset = "A4"
        options.composition.orientation = "Portrait"
        let svg = SVGExporter(options: options).svg(for: scene())

        XCTAssertTrue(svg.contains("data-hipparchus-paper=\"A4\""))
        XCTAssertTrue(svg.contains("data-hipparchus-orientation=\"Portrait\""))
    }

    /// On a night preset, dark-on-dark furniture would vanish into the ground.
    func testFurnitureInvertsOnADarkGround() throws {
        var options = SVGExporter.Options()
        options.composition.includeNorthArrow = true
        let svg = SVGExporter(options: options).svg(for: scene(background: RGBAColor(14, 17, 23)))

        let range = try XCTUnwrap(svg.range(of: "id=\"north_arrow\""))
        let arrow = String(svg[range.lowerBound...])
        XCTAssertTrue(arrow.contains("fill=\"#f2f2f2\""), "light furniture on a dark ground")
        XCTAssertFalse(arrow.contains("fill=\"#222222\""))
    }

    /// The legend calls layers what the layer panel calls them — one vocabulary.
    /// The Python keeps a second label map in `svg_clean.py` that differs from its
    /// panel in casing; carrying that fork over would be porting a bug.
    func testTheLegendNamesLayersAsThePanelDoes() {
        var scene = self.scene()
        var streets = RenderLayer(
            name: "street_names", style: LayerStyle(strokeWidth: 0, fillEnabled: false), rawFeatureCount: 1
        )
        streets.labels.append(PlaceLabel(name: "Ermou", position: Coordinate(x: 500, y: 400)))
        scene.layers.append(streets)

        var options = SVGExporter.Options()
        options.composition.includeLegend = true
        let svg = SVGExporter(options: options).svg(for: scene)

        XCTAssertTrue(svg.contains(">\(LayerInventory.label(for: "street_names"))</text>"))
        XCTAssertTrue(svg.contains(">\(LayerInventory.label(for: "roads"))</text>"))
    }

    /// A hidden or empty layer has no business in the legend.
    func testTheLegendListsOnlyVisibleLayersWithContent() {
        var scene = self.scene()
        var hidden = RenderLayer(name: "buildings", style: LayerStyle(), rawFeatureCount: 1)
        hidden.style.visible = false
        hidden.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1)])))
        scene.layers.append(hidden)
        scene.layers.append(RenderLayer(name: "water", style: LayerStyle(), rawFeatureCount: 0))

        var options = SVGExporter.Options()
        options.composition.includeLegend = true
        let svg = SVGExporter(options: options).svg(for: scene)

        XCTAssertFalse(svg.contains(">\(LayerInventory.label(for: "buildings"))</text>"))
        XCTAssertFalse(svg.contains(">\(LayerInventory.label(for: "water"))</text>"))
    }

    // MARK: - Paper

    /// The paper preset decides the export's pixel size — A4 and A3 at 300 dpi,
    /// as the Python's `PAPER_PRESETS` has them — and the orientation turns the
    /// sheet rather than the map. "Canvas" means whatever the caller was using.
    func testThePaperPresetDecidesTheExportSize() {
        var composition = SVGExporter.Composition()

        composition.paperPreset = "A4"
        composition.orientation = "Portrait"
        XCTAssertEqual(composition.exportSize(canvasWidth: 999, canvasHeight: 999).width, 2480)
        XCTAssertEqual(composition.exportSize(canvasWidth: 999, canvasHeight: 999).height, 3508)

        composition.orientation = "Landscape"
        XCTAssertEqual(composition.exportSize(canvasWidth: 999, canvasHeight: 999).width, 3508)
        XCTAssertEqual(composition.exportSize(canvasWidth: 999, canvasHeight: 999).height, 2480)

        composition.paperPreset = "Canvas"
        let canvas = composition.exportSize(canvasWidth: 1600, canvasHeight: 1200)
        XCTAssertEqual(canvas.width, 1600)
        XCTAssertEqual(canvas.height, 1200)

        // A preset nobody defined behaves as Canvas rather than as a zero-size page.
        composition.paperPreset = "Origami"
        XCTAssertEqual(composition.exportSize(canvasWidth: 1024, canvasHeight: 768).width, 1024)
    }

    // MARK: - The scale bar's arithmetic

    /// The label speaks the projection's units: degrees stay degrees, and metres
    /// grow into kilometres. Ported from `_format_distance`.
    func testTheScaleBarFormatsDistancesLikeThePython() {
        XCTAssertEqual(SVGExporter.formatDistance(25_000, renderCRS: "EPSG:3857"), "25 km")
        XCTAssertEqual(SVGExporter.formatDistance(1_500, renderCRS: "EPSG:3857"), "1.5 km")
        XCTAssertEqual(SVGExporter.formatDistance(500, renderCRS: "EPSG:3857"), "500 m")
        XCTAssertEqual(SVGExporter.formatDistance(0.5, renderCRS: "EPSG:3857"), "0.50 units")
        XCTAssertEqual(SVGExporter.formatDistance(2.25, renderCRS: "EPSG:4326"), "2.25 deg")
        XCTAssertEqual(SVGExporter.formatDistance(0.125, renderCRS: "EPSG:4326"), "0.1250 deg")
    }

    // MARK: - Diagnostics

    /// The diagnostics say how the page was composed, as the Python's do — a
    /// file separated from its export dialog can still say what it was for.
    func testDiagnosticsRecordTheComposition() {
        var options = SVGExporter.Options()
        options.composition = everything()
        let diagnostics = SVGExporter(options: options).diagnostics(for: scene(), format: "svg")

        XCTAssertEqual(diagnostics.composition?.paperPreset, "A4")
        XCTAssertEqual(diagnostics.composition?.includeScaleBar, true)
        XCTAssertEqual(diagnostics.composition?.title, "Demo Map")
    }

    // MARK: - Labels carry their halo

    /// The Python exports every label as a halo/text pair, so a street name stays
    /// legible over the linework it sits on. The bare text this port used to
    /// write lost the halo the presets specify.
    func testALabelExportsAsAHaloAndTextPair() throws {
        var scene = self.scene()
        var streets = RenderLayer(
            name: "street_names",
            style: LayerStyle(
                strokeWidth: 0, strokeColor: RGBAColor(60, 60, 60), fillEnabled: false,
                labelHaloColor: RGBAColor(247, 245, 240, 235), labelHaloWidth: 2.4
            ),
            rawFeatureCount: 1
        )
        streets.labels.append(PlaceLabel(name: "Ermou", position: Coordinate(x: 500, y: 400)))
        scene.layers.append(streets)

        let svg = SVGExporter().svg(for: scene)

        let occurrences = svg.components(separatedBy: ">Ermou</text>").count - 1
        XCTAssertEqual(occurrences, 2, "one halo behind, one text in front")

        XCTAssertTrue(svg.contains("stroke-width=\"2.4\""), "the halo carries its width")
        XCTAssertTrue(svg.contains("stroke=\"#f7f5f0\""), "the halo carries its colour")
        XCTAssertTrue(svg.contains("font-family"), "labels name a font for the editor")
    }
}
