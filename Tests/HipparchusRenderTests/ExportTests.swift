import CoreGraphics
import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// The export is the product, so these check the file rather than the intent.
final class SVGExportTests: XCTestCase {

    private func svg() throws -> String {
        SVGExporter().svg(for: try Sample.scene())
    }

    func testTheDocumentIsWellFormedSVG() throws {
        let svg = try self.svg()
        XCTAssertTrue(svg.hasPrefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 4096 4096\""))
        // Balanced groups.
        XCTAssertEqual(
            svg.components(separatedBy: "<g ").count,
            svg.components(separatedBy: "</g>").count
        )
    }

    /// The reason the SVG is built this way: named groups become named layers on
    /// import, and a map you cannot take apart is a picture, not a drawing.
    func testEveryLayerIsItsOwnNamedGroupInDrawOrder() throws {
        let svg = try self.svg()
        var searchFrom = svg.startIndex
        for name in Sample.layerOrder {
            let marker = "data-layer-name=\"\(name)\""
            guard let range = svg.range(of: marker, range: searchFrom..<svg.endIndex) else {
                return XCTFail("\(name) is not a named group in the SVG, or is out of order")
            }
            XCTAssertTrue(svg[searchFrom...].contains("<g id=\"\(name)\""), "\(name) needs a readable id")
            searchFrom = range.upperBound
        }
        XCTAssertTrue(svg.contains("<g id=\"map_layers\">"))
    }

    func testTheGroundIsPaintedSoADarkPresetDoesNotExportBlank() throws {
        let svg = try self.svg()
        XCTAssertTrue(svg.contains("id=\"map_background\""))
        XCTAssertTrue(svg.contains("fill=\"\(Sample.preset.styleProfile.background.hex)\""))
    }

    func testAHoleInABandIsExportedAsASeparateEvenOddSubpath() throws {
        let svg = try self.svg()
        // Two rings for the low band plus one for the high band.
        let bandGroup = try XCTUnwrap(group(named: TerrainLayer.elevationBands, in: svg))
        XCTAssertEqual(bandGroup.components(separatedBy: "<path ").count - 1, 3)
        XCTAssertTrue(bandGroup.contains("fill-rule=\"evenodd\""), "without even-odd the hollow fills in")
    }

    func testBandsCarryTheirOwnFillFromTheRamp() throws {
        let svg = try self.svg()
        let bandGroup = try XCTUnwrap(group(named: TerrainLayer.elevationBands, in: svg))
        let style = Sample.style(TerrainLayer.elevationBands)
        XCTAssertTrue(bandGroup.contains("fill=\"\(style.fillColor.hex)\""))
        XCTAssertTrue(bandGroup.contains("fill=\"\(style.fillColorHigh!.hex)\""))
    }

    /// A fill colour carries its own alpha and `hex` is only three channels of
    /// it. Core Graphics honours the alpha, so the PNG and the PDF have always
    /// drawn a translucent wash where the SVG drew a solid slab — the same
    /// picture has to come out of all three, and relief shading is a translucent
    /// wash by construction.
    func testATranslucentFillKeepsItsAlphaInTheExport() throws {
        var style = Sample.style(TerrainLayer.elevationBands)
        style.fillColor = RGBAColor(120, 130, 140, 64)
        style.fillColorHigh = RGBAColor(200, 40, 40, 255)

        var profile = Sample.preset.styleProfile
        profile.layerStyles[TerrainLayer.elevationBands] = style
        let preset = ArtisticPreset(
            name: "translucent",
            geometryProfile: Sample.preset.geometryProfile,
            styleProfile: profile
        )
        let scene = try SceneBuilder(options: SceneBuilder.Options(preset: preset))
            .build(from: Sample.collection())
        let svg = SVGExporter().svg(for: scene)

        let bandGroup = try XCTUnwrap(group(named: TerrainLayer.elevationBands, in: svg))
        let quoted = try XCTUnwrap(
            bandGroup.components(separatedBy: "fill-opacity=\"").dropFirst().first,
            "a 64/255 fill exported opaque; alpha was dropped on the way out"
        )
        let written = try XCTUnwrap(Double(quoted.prefix { $0 != "\"" }))
        XCTAssertEqual(written, 64.0 / 255.0, accuracy: 1e-4)
        // An opaque fill says nothing, rather than saying "1" on every path.
        let opaquePath = bandGroup
            .components(separatedBy: "<path ")
            .first { $0.contains("fill=\"\(RGBAColor(200, 40, 40).hex)\"") }
        XCTAssertNotNil(opaquePath)
        XCTAssertFalse(opaquePath?.contains("fill-opacity") ?? true, "an opaque fill needs no attribute")
    }

    func testContoursAreStrokedNotFilled() throws {
        let svg = try self.svg()
        let contourGroup = try XCTUnwrap(group(named: TerrainLayer.minorContours, in: svg))
        XCTAssertTrue(contourGroup.contains("fill=\"none\""))
        XCTAssertTrue(contourGroup.contains("stroke=\"\(Sample.style(TerrainLayer.minorContours).strokeColor.hex)\""))
        XCTAssertTrue(contourGroup.contains("vector-effect=\"non-scaling-stroke\""))
    }

    func testIndexContoursAreHeavierThanMinorOnes() throws {
        let svg = try self.svg()
        let minor = try XCTUnwrap(strokeWidth(in: try XCTUnwrap(group(named: TerrainLayer.minorContours, in: svg))))
        let index = try XCTUnwrap(strokeWidth(in: try XCTUnwrap(group(named: TerrainLayer.indexContours, in: svg))))
        XCTAssertGreaterThan(index, minor)
    }

    func testSummitHeightsAreExportedAsSelectableText() throws {
        let svg = try self.svg()
        let summitGroup = try XCTUnwrap(group(named: TerrainLayer.summits, in: svg))
        XCTAssertTrue(summitGroup.contains(">525 m</text>"))
    }

    /// Kickoff detail 9, checked exactly: every vertex is written.
    func testEveryVertexIsWrittenToThePathData() throws {
        var coordinates: [Coordinate] = []
        for step in 0..<5200 {
            coordinates.append(Coordinate(x: Double(step), y: sin(Double(step) * 0.01) * 100))
        }
        var layer = RenderLayer(name: "long_contour")
        layer.style.fillEnabled = false
        layer.style.strokeWidth = 1
        layer.append(.lineString(LineString(coordinates)))

        let svg = SVGExporter().svg(for: RenderScene(layers: [layer]))
        let group = try XCTUnwrap(self.group(named: "long_contour", in: svg))
        XCTAssertEqual(group.components(separatedBy: " L ").count - 1, coordinates.count - 1)
        XCTAssertEqual(group.components(separatedBy: "M ").count - 1, 1)
    }

    func testProvenanceIsCarriedInTheFileItself() throws {
        let svg = try self.svg()
        // A file separated from its diagnostics must still say what it is.
        XCTAssertTrue(svg.contains("data-hipparchus-provenance=\"measured\""))
        XCTAssertTrue(svg.contains("data-hipparchus-render-crs=\"EPSG:3857\""))
        XCTAssertTrue(svg.contains("data-hipparchus-source-crs=\"EPSG:4326\""))
        XCTAssertTrue(svg.contains("data-hipparchus-elevation-model=\"surface\""))
        XCTAssertTrue(svg.contains("data-hipparchus-bbox=\"25.32,36.33,25.5,36.48\""))
    }

    func testCoordinatesAreRoundedRatherThanWrittenInFull() throws {
        let svg = try self.svg()
        // Five decimals, and trailing zeros trimmed, or the file bloats.
        XCTAssertFalse(svg.contains("0000000"))
        for fragment in svg.components(separatedBy: "L ").dropFirst().prefix(20) {
            let number = fragment.prefix { !$0.isWhitespace }
            if let dot = number.firstIndex(of: ".") {
                let decimals = number.distance(from: dot, to: number.endIndex) - 1
                XCTAssertLessThanOrEqual(decimals, 5, "too many decimals in \(number)")
            }
        }
    }

    func testAHiddenLayerIsKeptButMarkedHidden() throws {
        var scene = try Sample.scene()
        let index = try XCTUnwrap(scene.layers.firstIndex { $0.name == TerrainLayer.bathymetry })
        scene.layers[index].style.visible = false
        let svg = SVGExporter().svg(for: scene)
        let group = try XCTUnwrap(self.group(named: TerrainLayer.bathymetry, in: svg))
        // Kept, so it can be switched back on in Illustrator.
        XCTAssertTrue(group.contains("display=\"none\""))
        XCTAssertTrue(group.contains("<path "))
    }

    func testAnEmptySceneStillExportsAValidDocument() {
        let svg = SVGExporter().svg(for: RenderScene())
        XCTAssertTrue(svg.hasPrefix("<svg"))
        XCTAssertTrue(svg.contains("<g id=\"map_layers\">"))
        XCTAssertTrue(svg.hasSuffix("</svg>\n"))
    }

    func testTextIsEscaped() throws {
        var layer = RenderLayer(name: "labels")
        layer.labels.append(PlaceLabel(name: "Ampersand & <angle>", position: Coordinate(x: 0, y: 0)))
        var other = RenderLayer(name: "line")
        other.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1)])))
        let svg = SVGExporter().svg(for: RenderScene(layers: [layer, other]))
        XCTAssertTrue(svg.contains("Ampersand &amp; &lt;angle&gt;"))
        XCTAssertFalse(svg.contains("Ampersand & <angle>"))
    }

    func testWritingToDiskProducesTheSameDocument() throws {
        let scene = try Sample.scene()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-test-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: url) }

        let exporter = SVGExporter()
        let diagnostics = try exporter.write(scene, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), exporter.svg(for: scene))
        XCTAssertEqual(diagnostics.format, "svg")
        XCTAssertEqual(diagnostics.totalGeometries, 5)
    }

    // MARK: -

    private func group(named name: String, in svg: String) -> String? {
        guard let start = svg.range(of: "<g id=\"\(name)\"") else { return nil }
        guard let end = svg.range(of: "</g>", range: start.upperBound..<svg.endIndex) else { return nil }
        return String(svg[start.lowerBound..<end.upperBound])
    }

    private func strokeWidth(in group: String) -> Double? {
        guard let range = group.range(of: "stroke-width=\"") else { return nil }
        let rest = group[range.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return Double(rest[rest.startIndex..<quote])
    }
}

final class ExportDiagnosticsTests: XCTestCase {

    func testDiagnosticsRecordEveryLayerAndItsCount() throws {
        let diagnostics = SVGExporter().diagnostics(for: try Sample.scene(), format: "svg")
        XCTAssertEqual(diagnostics.layers.map(\.name), Sample.layerOrder)
        XCTAssertEqual(diagnostics.layers.first { $0.name == TerrainLayer.elevationBands }?.geometries, 2)
        XCTAssertEqual(diagnostics.layers.first { $0.name == TerrainLayer.summits }?.labels, 1)
    }

    /// Provenance in the machine-readable half too: this is what lets someone check
    /// later whether a map was a survey or a generated picture.
    func testDiagnosticsCarryProvenanceAndCRS() throws {
        let diagnostics = SVGExporter().diagnostics(for: try Sample.scene(), format: "svg")
        XCTAssertEqual(diagnostics.provenance, "measured")
        XCTAssertEqual(diagnostics.renderCRS, "EPSG:3857")
        XCTAssertEqual(diagnostics.sourceCRS, "EPSG:4326")
        XCTAssertEqual(diagnostics.bbox, [25.32, 36.33, 25.50, 36.48])
    }

    func testDiagnosticsEncodeToStableJSON() throws {
        let diagnostics = SVGExporter().diagnostics(for: try Sample.scene(), format: "svg")
        let json = try XCTUnwrap(String(data: try diagnostics.jsonData(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"provenance\" : \"measured\""))
        // Sorted keys, so two runs of the same map diff cleanly.
        XCTAssertEqual(try diagnostics.jsonData(), try diagnostics.jsonData())
        XCTAssertEqual(
            try JSONDecoder().decode(ExportDiagnostics.self, from: try diagnostics.jsonData()),
            diagnostics
        )
    }
}

final class PDFExportTests: XCTestCase {

    func testAPDFIsWrittenAndIsReadableAsAPDF() throws {
        let scene = try Sample.scene()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().write(scene, to: url)

        let document = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(document.numberOfPages, 1)
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 842, accuracy: 1)
        XCTAssertEqual(box.height, 595, accuracy: 1)
    }

    func testThePDFCarriesItsProvenance() throws {
        let scene = try Sample.scene()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        try PDFExporter().write(scene, to: url)

        // A printed map that cannot say whether it was measured or generated is the
        // thing provenance exists to prevent.
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(raw.contains("provenance"), "the PDF metadata should name the provenance")
    }

    func testAFailedDestinationIsReportedRatherThanIgnored() throws {
        let scene = try Sample.scene()
        let url = URL(fileURLWithPath: "/definitely/not/a/writable/path/map.pdf")
        XCTAssertThrowsError(try PDFExporter().write(scene, to: url))
    }
}
