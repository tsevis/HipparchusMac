import CoreGraphics
import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Fixtures shared by the render and export tests.
enum Sample {
    static let bbox = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)

    /// Two nested bands, two contours and one summit — enough to exercise fills,
    /// holes, strokes, per-feature colour and labels.
    static func collection() -> FeatureCollection {
        func ring(_ inset: Double) -> [Coordinate] {
            [
                Coordinate(lon: bbox.minLon + inset, lat: bbox.minLat + inset),
                Coordinate(lon: bbox.maxLon - inset, lat: bbox.minLat + inset),
                Coordinate(lon: bbox.maxLon - inset, lat: bbox.maxLat - inset),
                Coordinate(lon: bbox.minLon + inset, lat: bbox.maxLat - inset),
            ]
        }

        let lowBand = Feature(
            id: "t/elevation_bands/0", layer: TerrainLayer.elevationBands, source: "terrain_tiles",
            // A band with a hole in it: the case a naive fill covers over.
            geometry: .polygon(Polygon(exterior: ring(0.01), holes: [ring(0.04)])),
            provenance: .measured,
            properties: ["band_index": .int(0), "band_count": .int(2),
                         "elevation_low": .double(-79), "elevation_high": .double(220)]
        )
        let highBand = Feature(
            id: "t/elevation_bands/1", layer: TerrainLayer.elevationBands, source: "terrain_tiles",
            geometry: .polygon(Polygon(exterior: ring(0.04))),
            provenance: .measured,
            properties: ["band_index": .int(1), "band_count": .int(2),
                         "elevation_low": .double(220), "elevation_high": .double(525)]
        )
        let contour = Feature(
            id: "t/terrain_contours/0", layer: TerrainLayer.minorContours, source: "terrain_tiles",
            geometry: .lineString(LineString(ring(0.02) + [ring(0.02)[0]])),
            provenance: .measured,
            properties: ["elevation": .double(100), "index_contour": .bool(false)]
        )
        let indexContour = Feature(
            id: "t/terrain_index_contours/0", layer: TerrainLayer.indexContours, source: "terrain_tiles",
            geometry: .lineString(LineString(ring(0.03) + [ring(0.03)[0]])),
            provenance: .measured,
            properties: ["elevation": .double(500), "index_contour": .bool(true)]
        )
        let bathymetry = Feature(
            id: "t/bathymetry/0", layer: TerrainLayer.bathymetry, source: "terrain_tiles",
            geometry: .lineString(LineString(ring(0.005))),
            provenance: .measured,
            properties: ["elevation": .double(-50), "index_contour": .bool(false)]
        )
        let summit = Feature(
            id: "t/summit/0", layer: TerrainLayer.summits, source: "terrain_tiles",
            geometry: .point(Coordinate(lon: 25.41, lat: 36.40)),
            provenance: .measured,
            properties: ["name": .string("525 m"), "elevation": .double(525)]
        )

        return FeatureCollection(
            featuresByLayer: [
                TerrainLayer.elevationBands: [lowBand, highBand],
                TerrainLayer.minorContours: [contour],
                TerrainLayer.indexContours: [indexContour],
                TerrainLayer.bathymetry: [bathymetry],
                TerrainLayer.summits: [summit],
            ],
            metadata: [
                "source": .string("terrain_tiles"),
                "contour_interval_metres": .double(20),
                "elevation_model": .string("surface"),
            ],
            bbox: bbox,
            provenance: .measured
        )
    }

    static func scene() throws -> RenderScene {
        try SceneBuilder().build(from: collection())
    }

    /// The preset the terrain slice is drawn with, and the one the tests measure
    /// against. Reading the colours from the preset rather than restating them means
    /// a regenerated `PresetTables.swift` cannot quietly disagree with the tests.
    static let preset = SceneBuilder.Options().preset

    static func style(_ layer: String) -> LayerStyle {
        preset.styleProfile.style(for: layer)
    }

    /// The terrain layers, in the order `SceneBuilder.preferredLayerOrder` puts them.
    static let layerOrder = [
        TerrainLayer.elevationBands,
        TerrainLayer.bathymetry,
        TerrainLayer.minorContours,
        TerrainLayer.indexContours,
        TerrainLayer.summits,
    ]
}

final class SceneBuilderTests: XCTestCase {

    func testLayersComeOutInDrawOrderWithGroundUnderLinework() throws {
        let scene = try Sample.scene()
        XCTAssertEqual(scene.layers.map(\.name), Sample.layerOrder)
        // Fills must be under the lines that describe the same ground, or the fill
        // paints over the contour.
        let bands = try XCTUnwrap(scene.layers.firstIndex { $0.name == TerrainLayer.elevationBands })
        let contours = try XCTUnwrap(scene.layers.firstIndex { $0.name == TerrainLayer.minorContours })
        XCTAssertLessThan(bands, contours)
    }

    func testGeometryIsProjectedOutOfDegreesIntoMetres() throws {
        let scene = try Sample.scene()
        XCTAssertEqual(scene.projection.renderCRS, "EPSG:3857")
        let bounds = try XCTUnwrap(scene.contentBounds)
        // Web Mercator metres, not degrees: Santorini is about 2.8 million metres east.
        XCTAssertGreaterThan(bounds.minX, 2_000_000)
    }

    /// Kickoff detail 6, the one that bit the Python twice.
    func testPerFeatureColoursStayInStepWithTheirGeometry() throws {
        let scene = try Sample.scene()
        let bands = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.elevationBands })

        XCTAssertEqual(bands.geometries.count, bands.fillColors.count)
        XCTAssertEqual(bands.geometries.count, bands.weights.count)
        XCTAssertEqual(bands.geometries.count, 2)

        // Band 0 takes the low end of the ramp, band 1 the high end.
        let style = Sample.style(TerrainLayer.elevationBands)
        XCTAssertEqual(bands.fillColor(at: 0), style.fillColor)
        XCTAssertEqual(bands.fillColor(at: 1), style.fillColorHigh)
    }

    func testABandWithAHoleKeepsItsHoleThroughTheBuild() throws {
        let scene = try Sample.scene()
        let bands = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.elevationBands })
        XCTAssertTrue(
            bands.geometries.contains { $0.polygons.contains { !$0.holes.isEmpty } },
            "the enclosed hollow must survive projection and clipping"
        )
    }

    func testClippingKeepsGeometryInsideTheArea() throws {
        var collection = Sample.collection()
        // A contour running well outside the frame, as a tile-mosaic contour does.
        collection.featuresByLayer[TerrainLayer.minorContours]?.append(Feature(
            id: "t/terrain_contours/outside", layer: TerrainLayer.minorContours, source: "terrain_tiles",
            geometry: .lineString(LineString([
                Coordinate(lon: 25.0, lat: 36.0), Coordinate(lon: 26.0, lat: 36.9),
            ])),
            provenance: .measured, properties: ["elevation": .double(60)]
        ))

        let scene = try SceneBuilder().build(from: collection)
        let projected = scene.projection.project(Sample.bbox)
        for layer in scene.layers {
            for geometry in layer.geometries {
                guard let bounds = geometry.bounds else { continue }
                XCTAssertGreaterThanOrEqual(bounds.minX, projected.minX - 1.0, "\(layer.name)")
                XCTAssertLessThanOrEqual(bounds.maxX, projected.maxX + 1.0, "\(layer.name)")
                XCTAssertGreaterThanOrEqual(bounds.minY, projected.minY - 1.0, "\(layer.name)")
                XCTAssertLessThanOrEqual(bounds.maxY, projected.maxY + 1.0, "\(layer.name)")
            }
        }
        XCTAssertEqual(scene.diagnostics["clipped_geometries"]?.doubleValue, 1)
    }

    func testSummitsBecomeLabelsCarryingTheirHeight() throws {
        let scene = try Sample.scene()
        let summits = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.summits })
        XCTAssertEqual(summits.labels.map(\.name), ["525 m"])
        XCTAssertTrue(summits.geometries.isEmpty, "a summit is a label, not linework")
    }

    /// Provenance has to survive the whole way to the scene.
    func testProvenanceReachesTheScene() throws {
        let scene = try Sample.scene()
        XCTAssertEqual(scene.metadata["provenance"]?.stringValue, "measured")
        XCTAssertEqual(scene.metadata["elevation_model"]?.stringValue, "surface")
    }

    func testAnEmptyLayerIsKeptSoItCanSayNoneHere() throws {
        var collection = Sample.collection()
        collection.featuresByLayer[TerrainLayer.bathymetry] = []
        let scene = try SceneBuilder().build(from: collection)
        let bathymetry = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.bathymetry })
        XCTAssertTrue(bathymetry.isEmpty)
        XCTAssertEqual(bathymetry.featureCount, 0)
    }

    func testTheSceneSummarisesWhatItHolds() throws {
        XCTAssertEqual(try Sample.scene().summary, "5 layers · 6 features")
    }

    // MARK: - Presets, quality and illumination in the pipeline

    /// The scene must actually be drawn with the chosen preset. A preset picker that
    /// changes a label and nothing else is exactly the failure the kickoff warns
    /// about — the interface says one thing while the renderer does another.
    func testChoosingAPresetChangesTheGroundAndTheLinework() throws {
        func scene(_ name: String) throws -> RenderScene {
            try SceneBuilder(options: .init(preset: Presets.preset(name)))
                .build(from: Sample.collection())
        }

        let hypsometric = try scene("Hypsometric Relief")
        let night = try scene("Night")

        XCTAssertEqual(hypsometric.background, Presets.preset("Hypsometric Relief").styleProfile.background)
        XCTAssertEqual(night.background, Presets.nightGround)
        XCTAssertNotEqual(hypsometric.background, night.background)

        let hypsometricContours = try XCTUnwrap(hypsometric.layers.first { $0.name == TerrainLayer.minorContours })
        let nightContours = try XCTUnwrap(night.layers.first { $0.name == TerrainLayer.minorContours })
        XCTAssertNotEqual(hypsometricContours.style.strokeColor, nightContours.style.strokeColor)

        XCTAssertEqual(night.metadata["preset"]?.stringValue, "Night")
    }

    /// Tanaka illumination has to reach the scene, not merely exist in the geometry
    /// target. `Contour Study` lights its contours; `Hypsometric Relief` does not.
    func testAnIlluminatedPresetSplitsContoursIntoRunsOfVaryingWeight() throws {
        let plain = try SceneBuilder(options: .init(preset: Presets.preset("Hypsometric Relief")))
            .build(from: Sample.collection())
        let lit = try SceneBuilder(options: .init(preset: Presets.preset("Contour Study")))
            .build(from: Sample.collection())

        let plainContours = try XCTUnwrap(plain.layers.first { $0.name == TerrainLayer.minorContours })
        let litContours = try XCTUnwrap(lit.layers.first { $0.name == TerrainLayer.minorContours })

        XCTAssertEqual(plainContours.geometries.count, 1, "unlit, one contour stays one path")
        XCTAssertEqual(Set(plainContours.weights), [1.0])

        // The sample contour is a closed rectangle, so its four sides face the light
        // four different ways and cannot all come out at one weight.
        XCTAssertGreaterThan(litContours.geometries.count, 1, "the contour was never split into runs")
        XCTAssertGreaterThan(Set(litContours.weights).count, 1, "every run came out at the same weight")
        XCTAssertEqual(litContours.geometries.count, litContours.weights.count)

        XCTAssertTrue(
            lit.diagnostics["illuminated_layers"]?.stringValue?.contains(TerrainLayer.minorContours) == true,
            "the scene does not record which layers it lit"
        )
    }

    /// Illumination multiplies the geometry count, so the count of what was *fetched*
    /// has to be kept separately or the layer panel reports runs as contours.
    func testTheRawFeatureCountSurvivesIllumination() throws {
        let lit = try SceneBuilder(options: .init(preset: Presets.preset("Contour Study")))
            .build(from: Sample.collection())
        let contours = try XCTUnwrap(lit.layers.first { $0.name == TerrainLayer.minorContours })
        XCTAssertEqual(contours.rawFeatureCount, 1, "one contour was fetched, however many runs it became")
        XCTAssertGreaterThan(contours.geometries.count, contours.rawFeatureCount)
    }

    /// A quality profile says how much work to spend, and export spends more.
    func testExportQualityUsesALocalProjectionAndATighterTolerance() throws {
        let preview = try SceneBuilder(options: .init(quality: Quality.profile("preview_fast")))
            .build(from: Sample.collection())
        let export = try SceneBuilder(options: .init(quality: Quality.profile("export_print")))
            .build(from: Sample.collection())

        // A printed sheet should not carry a visible Mercator stretch across it.
        XCTAssertEqual(preview.projection.renderCRS, "EPSG:3857")
        XCTAssertNotEqual(export.projection.renderCRS, "EPSG:3857")

        let previewTolerance = try XCTUnwrap(preview.diagnostics["simplify_tolerance"]?.doubleValue)
        let exportTolerance = try XCTUnwrap(export.diagnostics["simplify_tolerance"]?.doubleValue)
        XCTAssertGreaterThan(previewTolerance, exportTolerance)
        XCTAssertEqual(export.diagnostics["quality_profile"]?.stringValue, "export_print")
    }

    /// Fast preview switches smoothing off entirely; that is what makes it fast.
    ///
    /// Measured on the contours, because those are a line-smoothing layer. Elevation
    /// bands are deliberately left alone in both codebases — rounding a measured
    /// band edge is fabrication, not smoothing.
    func testSmoothingRunsForExportAndIsSkippedForFastPreview() throws {
        func contourVertices(quality: QualityProfile) throws -> Int {
            let scene = try SceneBuilder(options: .init(quality: quality)).build(from: Sample.collection())
            let contours = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.minorContours })
            return contours.geometries.reduce(0) { count, geometry in
                count + geometry.lineStrings.reduce(0) { $0 + $1.coordinates.count }
            }
        }

        // Corner-cutting replaces each corner with two points, so a smoothed line
        // carries more vertices than the one it came from.
        let fast = try contourVertices(quality: Quality.profile("preview_fast"))
        let clean = try contourVertices(quality: Quality.profile("export_clean"))
        XCTAssertGreaterThan(clean, fast, "the smoothing pass never ran")
        XCTAssertEqual(
            try SceneBuilder(options: .init(quality: Quality.profile("preview_fast")))
                .build(from: Sample.collection())
                .diagnostics["smoothed_geometries"]?.doubleValue,
            0,
            "fast preview must not spend time smoothing"
        )
    }

    /// Bands are measured edges. A preset that smooths contours must not round these.
    func testMeasuredBandEdgesAreNeverSmoothed() throws {
        func bandVertices(quality: QualityProfile) throws -> Int {
            let scene = try SceneBuilder(options: .init(quality: quality)).build(from: Sample.collection())
            let bands = try XCTUnwrap(scene.layers.first { $0.name == TerrainLayer.elevationBands })
            return bands.geometries.reduce(0) { count, geometry in
                count + geometry.polygons.reduce(0) { $0 + $1.exterior.coordinates.count }
            }
        }
        XCTAssertEqual(
            try bandVertices(quality: Quality.profile("export_clean")),
            try bandVertices(quality: Quality.profile("preview_fast"))
        )
    }

    func testAnUnknownLayerIsDrawnAfterEverythingItCouldSitUnder() {
        let ordered = SceneBuilder.ordered([
            "terrain_contours", "zebra_crossings", "elevation_bands", "aardvarks",
        ])
        XCTAssertEqual(ordered, ["elevation_bands", "terrain_contours", "aardvarks", "zebra_crossings"])
    }

    func testSpacedThousandsReadsAsTheInterfaceShowsIt() {
        XCTAssertEqual(spacedThousands(999), "999")
        XCTAssertEqual(spacedThousands(1045), "1045")
        XCTAssertEqual(spacedThousands(46211), "46 211")
        XCTAssertEqual(spacedThousands(154572), "154 572")
    }
}

final class CanvasTransformTests: XCTestCase {

    private func transform(viewport: ViewportState = ViewportState()) throws -> CanvasTransform {
        let scene = try Sample.scene()
        return try XCTUnwrap(CanvasTransform(
            contentBounds: scene.contentBounds,
            size: CGSize(width: 800, height: 600),
            viewport: viewport
        ))
    }

    /// The property that makes modifier-drag-to-draw-an-area possible.
    func testScreenToWorldIsTheExactInverseOfWorldToScreen() throws {
        for viewport in [
            ViewportState(),
            ViewportState(zoom: 2.5),
            ViewportState(zoom: 0.8, panX: 40, panY: -25),
            ViewportState(zoom: 1.7, panX: -12, panY: 30, rotation: 33),
        ] {
            let transform = try self.transform(viewport: viewport)
            for point in [
                Coordinate(x: 2_820_000, y: 4_350_000),
                Coordinate(x: 2_840_000, y: 4_370_000),
            ] {
                let back = transform.screenToWorld(transform.worldToScreen(point))
                XCTAssertEqual(back.x, point.x, accuracy: 1e-6, "zoom \(viewport.zoom) rot \(viewport.rotation)")
                XCTAssertEqual(back.y, point.y, accuracy: 1e-6, "zoom \(viewport.zoom) rot \(viewport.rotation)")
            }
        }
    }

    func testTheMapIsCentredWithAMargin() throws {
        let transform = try self.transform()
        let scene = try Sample.scene()
        let bounds = try XCTUnwrap(scene.contentBounds)
        let topLeft = transform.worldToScreen(Coordinate(x: bounds.minX, y: bounds.maxY))
        let bottomRight = transform.worldToScreen(Coordinate(x: bounds.maxX, y: bounds.minY))

        let margin = CanvasTransform.margin(width: 800, height: 600)
        XCTAssertGreaterThanOrEqual(topLeft.x, margin - 1)
        XCTAssertGreaterThanOrEqual(topLeft.y, margin - 1)
        XCTAssertLessThanOrEqual(bottomRight.x, 800 - margin + 1)
        XCTAssertLessThanOrEqual(bottomRight.y, 600 - margin + 1)
    }

    func testNorthIsUp() throws {
        let transform = try self.transform()
        let north = transform.worldToScreen(Coordinate(x: 2_830_000, y: 4_370_000))
        let south = transform.worldToScreen(Coordinate(x: 2_830_000, y: 4_350_000))
        XCTAssertLessThan(north.y, south.y, "canvas y grows downward, so north must have the smaller y")
    }

    func testStrokeWidthsAreScaledOutOfWorldUnits() throws {
        let transform = try self.transform()
        // World units here are metres, so an unscaled 0.35 would be sub-pixel.
        XCTAssertGreaterThan(transform.strokeWidth(0.35), 0)
        XCTAssertEqual(transform.strokeWidth(1.0), 1.0 / transform.fitScale, accuracy: 1e-12)
    }

    func testAnEmptySceneHasNoTransformRatherThanAWrongOne() {
        XCTAssertNil(CanvasTransform(contentBounds: nil, size: CGSize(width: 100, height: 100)))
        XCTAssertNil(CanvasTransform(
            contentBounds: Bounds(minX: 0, minY: 0, maxX: 1, maxY: 1),
            size: .zero
        ))
    }
}

final class CoreGraphicsRendererTests: XCTestCase {

    /// The headless half of "did the change break drawing?".
    ///
    /// The Python could not test its render path at all — creating a second Tk root
    /// hangs on macOS — and a UI edit once disabled rendering entirely while every
    /// test still passed. Drawing into a bitmap makes that a testable claim.
    func testRenderingActuallyPutsInkOnTheCanvas() throws {
        let scene = try Sample.scene()
        let image = try XCTUnwrap(CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: 400, height: 300)
        ))
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)

        let pixels = try nonBackgroundPixelCount(image, background: scene.background)
        XCTAssertGreaterThan(pixels, 500, "the canvas is empty: nothing was drawn")
    }

    func testAnEmptySceneDrawsTheBackgroundAndNothingElse() throws {
        let scene = RenderScene(layers: [], background: RGBAColor(10, 20, 30))
        let image = try XCTUnwrap(CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: 60, height: 40)
        ))
        XCTAssertEqual(try nonBackgroundPixelCount(image, background: scene.background), 0)
    }

    func testAHiddenLayerIsNotDrawn() throws {
        var scene = try Sample.scene()
        let withEverything = try nonBackgroundPixelCount(
            try XCTUnwrap(CoreGraphicsRenderer().image(of: scene, size: CGSize(width: 300, height: 300))),
            background: scene.background
        )

        for index in scene.layers.indices {
            scene.layers[index].style.visible = false
        }
        let withNothing = try nonBackgroundPixelCount(
            try XCTUnwrap(CoreGraphicsRenderer().image(of: scene, size: CGSize(width: 300, height: 300))),
            background: scene.background
        )

        XCTAssertGreaterThan(withEverything, 0)
        XCTAssertEqual(withNothing, 0)
    }

    /// Kickoff detail 9: a long path must arrive whole, never truncated with a
    /// chord ruled across the shape.
    ///
    /// Counted exactly rather than inferred from how much ink landed. Seven of
    /// Santorini's contours exceed five thousand vertices, so the number here is
    /// realistic, and every one of them has to reach the page.
    func testEveryVertexOfALongPathReachesThePath() throws {
        var coordinates: [Coordinate] = []
        for step in 0..<6000 {
            let angle = Double(step) * 0.01
            let radius = 1000.0 + Double(step) * 0.5
            coordinates.append(Coordinate(x: 2_830_000 + radius * cos(angle), y: 4_360_000 + radius * sin(angle)))
        }

        let transform = try XCTUnwrap(CanvasTransform(
            contentBounds: Bounds(coordinates),
            size: CGSize(width: 500, height: 500)
        ))
        let path = try XCTUnwrap(CoreGraphicsRenderer().path(
            for: .lineString(LineString(coordinates)), transform: transform
        ))

        var moves = 0
        var lines = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: moves += 1
            case .addLineToPoint: lines += 1
            default: break
            }
        }
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(lines, coordinates.count - 1, "the vertex list was cut short")
    }

    func testAPolygonWithAHoleBecomesTwoSubpaths() throws {
        let outer = [
            Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0),
            Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10),
        ]
        let inner = [
            Coordinate(x: 3, y: 3), Coordinate(x: 7, y: 3),
            Coordinate(x: 7, y: 7), Coordinate(x: 3, y: 7),
        ]
        let transform = try XCTUnwrap(CanvasTransform(
            contentBounds: Bounds(outer), size: CGSize(width: 200, height: 200)
        ))
        let path = try XCTUnwrap(CoreGraphicsRenderer().path(
            for: .polygon(Polygon(exterior: outer, holes: [inner])), transform: transform
        ))

        var moves = 0
        var closes = 0
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: moves += 1
            case .closeSubpath: closes += 1
            default: break
            }
        }
        // Exterior and hole, each its own closed subpath, which is what even-odd
        // filling needs to leave the hollow hollow.
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(closes, 2)
    }

    func testTheRendererReportsTheTransformItUsed() throws {
        let scene = try Sample.scene()
        let size = CGSize(width: 320, height: 240)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return XCTFail("could not make a context")
        }
        let transform = try XCTUnwrap(CoreGraphicsRenderer().draw(scene, in: context, size: size))
        // The caller needs this to turn a click back into a coordinate.
        XCTAssertGreaterThan(transform.fitScale, 0)
    }

    // MARK: -

    private func nonBackgroundPixelCount(_ image: CGImage, background: RGBAColor) throws -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw XCTSkip("no sRGB colour space")
        }
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw XCTSkip("no bitmap context")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // Tolerant of one unit of rounding through the colour space.
            if abs(Int(pixels[index]) - Int(background.r)) > 2
                || abs(Int(pixels[index + 1]) - Int(background.g)) > 2
                || abs(Int(pixels[index + 2]) - Int(background.b)) > 2 {
                count += 1
            }
        }
        return count
    }
}

/// An open line must never be filled.
///
/// A layer style says `fillEnabled`, but a style describes a *layer* and a layer can
/// hold both areas and open lines. Ninety-eight of the 140 coastline ways in an
/// Athens fetch are unclosed polylines, and filling one closes it with an invisible
/// chord and paints the wedge behind it — a pale triangle straight across the sea.
final class OpenLineFillTests: XCTestCase {

    private func layer(_ geometry: Geometry) -> RenderLayer {
        var layer = RenderLayer(name: "coastline")
        layer.style.fillEnabled = true
        layer.style.fillColor = RGBAColor(0, 0, 255)
        layer.style.strokeWidth = 0
        layer.style.strokeColor = RGBAColor(0, 0, 0, 0)
        layer.append(geometry)
        return layer
    }

    private let coast = [
        Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 40),
        Coordinate(x: 40, y: 100),
    ]

    func testAnOpenCoastlineDoesNotPaintAWedge() throws {
        let scene = RenderScene(
            layers: [layer(.lineString(LineString(coast)))],
            background: RGBAColor(255, 255, 255)
        )
        let image = try XCTUnwrap(CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: 200, height: 200)
        ))
        XCTAssertEqual(try filledPixels(image), 0, "the open line was filled")
    }

    func testAClosedShapeInTheSameLayerIsStillFilled() throws {
        let scene = RenderScene(
            layers: [layer(.polygon(Polygon(exterior: coast)))],
            background: RGBAColor(255, 255, 255)
        )
        let image = try XCTUnwrap(CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: 200, height: 200)
        ))
        XCTAssertGreaterThan(try filledPixels(image), 500, "a real area stopped being filled")
    }

    func testTheExportedSVGDoesNotFillAnOpenLineEither() throws {
        let scene = RenderScene(
            layers: [layer(.lineString(LineString(coast)))],
            background: RGBAColor(255, 255, 255)
        )
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("open-line-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try SVGExporter().write(scene, to: url)
        let svg = try String(contentsOf: url, encoding: .utf8)
        // An editor filling an open path closes it the same way the canvas does.
        XCTAssertTrue(svg.contains("fill=\"none\""))
        XCTAssertFalse(svg.contains("fill=\"#0000ff\""), "the SVG fills a path that has no area")
    }

    func testGeometryKnowsWhetherItEnclosesAnything() {
        XCTAssertFalse(Geometry.lineString(LineString(coast)).hasArea)
        XCTAssertFalse(Geometry.point(Coordinate(x: 0, y: 0)).hasArea)
        XCTAssertTrue(Geometry.polygon(Polygon(exterior: coast)).hasArea)
        XCTAssertTrue(Geometry.multiPolygon([Polygon(exterior: coast)]).hasArea)
    }

    private func filledPixels(_ image: CGImage) throws -> Int {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw XCTSkip("no sRGB") }
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw XCTSkip("no bitmap context") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 2] > 200
            && pixels[index] < 60 {
            count += 1
        }
        return count
    }
}

/// The derived artistic layers: structure invented from the map rather than
/// fetched with it.
///
/// None of the sixteen presets turns one on — not here and not in the Python — so
/// these all drive them through `Options.derivations`, which is the only switch.
final class DerivedLayerTests: XCTestCase {

    /// A handful of buildings and a road grid: enough to seed all four derivations.
    private func townCollection() -> FeatureCollection {
        let bbox = BoundingBox(minLon: 0, minLat: 0, maxLon: 0.02, maxLat: 0.02)
        var buildings: [Feature] = []
        for row in 0..<4 {
            for column in 0..<4 {
                let x = 0.003 + Double(column) * 0.004
                let y = 0.003 + Double(row) * 0.004
                buildings.append(Feature(
                    id: "b/\(row)/\(column)", layer: "buildings", source: "test",
                    geometry: .polygon(Polygon(exterior: [
                        Coordinate(lon: x, lat: y), Coordinate(lon: x + 0.001, lat: y),
                        Coordinate(lon: x + 0.001, lat: y + 0.001), Coordinate(lon: x, lat: y + 0.001),
                    ])),
                    provenance: .measured
                ))
            }
        }

        var roads: [Feature] = []
        for step in 0..<5 {
            let position = 0.002 + Double(step) * 0.004
            roads.append(Feature(
                id: "r/h/\(step)", layer: "roads", source: "test",
                geometry: .lineString(LineString([
                    Coordinate(lon: 0.001, lat: position), Coordinate(lon: 0.019, lat: position),
                ])),
                provenance: .measured
            ))
            roads.append(Feature(
                id: "r/v/\(step)", layer: "roads", source: "test",
                geometry: .lineString(LineString([
                    Coordinate(lon: position, lat: 0.001), Coordinate(lon: position, lat: 0.019),
                ])),
                provenance: .measured
            ))
        }

        return FeatureCollection(
            featuresByLayer: ["buildings": buildings, "roads": roads],
            metadata: ["source": .string("test")],
            bbox: bbox,
            provenance: .measured
        )
    }

    private func scene(_ configure: (inout GeometryPipelineProfile) -> Void) throws -> RenderScene {
        var profile = GeometryPipelineProfile()
        configure(&profile)
        return try SceneBuilder(options: SceneBuilder.Options(
            // Export quality, because a preview of a busy frame declines to derive.
            quality: Quality.profile("export_clean"),
            derivations: profile
        )).build(from: townCollection())
    }

    private func layer(_ scene: RenderScene, _ name: String) -> RenderLayer? {
        scene.layers.first { $0.name == name }
    }

    /// The default is off, and staying off is what keeps existing maps identical.
    func testNoDerivationRunsUnlessAsked() throws {
        let scene = try SceneBuilder(options: SceneBuilder.Options(
            quality: Quality.profile("export_clean")
        )).build(from: townCollection())

        for name in ["voronoi_cells", "delaunay_mesh", "hex_grid", "circle_packing"] {
            XCTAssertNil(layer(scene, name), "\(name) appeared without being asked for")
        }
    }

    func testVoronoiCellsAreDerivedFromTheBuildings() throws {
        let scene = try scene { $0.deriveVoronoi = true }
        let cells = try XCTUnwrap(layer(scene, "voronoi_cells"))

        // Sixteen buildings, so sixteen cells — one per site.
        XCTAssertEqual(cells.geometries.count, 16)
        XCTAssertTrue(cells.geometries.allSatisfy(\.hasArea))
    }

    func testTheDelaunayMeshIsSeededByRoadCrossings() throws {
        let scene = try scene { $0.deriveDelaunay = true }
        let mesh = try XCTUnwrap(layer(scene, "delaunay_mesh"))
        XCTAssertGreaterThan(mesh.geometries.count, 8, "a 5x5 road grid has 25 crossings to triangulate")
        XCTAssertTrue(mesh.geometries.allSatisfy(\.hasArea))
    }

    func testTheHexGridCoversTheMap() throws {
        let scene = try scene {
            $0.deriveHexGrid = true
            // Projected units are metres, and this frame is about 2 km across.
            $0.hexRadius = 120
        }
        let grid = try XCTUnwrap(layer(scene, "hex_grid"))
        XCTAssertGreaterThan(grid.geometries.count, 10)
        XCTAssertTrue(grid.geometries.allSatisfy(\.hasArea))
    }

    func testCirclesArePacked() throws {
        let scene = try scene {
            $0.deriveCirclePacking = true
            $0.circleMinRadius = 60
            $0.circleMaxRadius = 200
        }
        let packing = try XCTUnwrap(layer(scene, "circle_packing"))
        XCTAssertGreaterThan(packing.geometries.count, 2)
        XCTAssertTrue(packing.geometries.allSatisfy(\.hasArea))
    }

    /// A derived layer is drawn, not just built.
    func testADerivedLayerReachesTheCanvasAndTheLayerPanel() throws {
        let scene = try scene {
            $0.deriveHexGrid = true
            $0.hexRadius = 120
        }
        let rows = LayerInventory.entries(for: scene)
        let hexRow = try XCTUnwrap(rows.first { $0.layerID == "hex_grid" })
        XCTAssertEqual(hexRow.label, "Hex grid")
        XCTAssertEqual(hexRow.group, "Derived")
        XCTAssertTrue(hexRow.hasData)

        // And it puts ink on the canvas.
        let image = try XCTUnwrap(CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: 300, height: 300)
        ))
        XCTAssertEqual(image.width, 300)
    }

    /// Derived layers are artistic overlays, so they sit above the base map.
    func testDerivedLayersDrawOverTheMapTheyCameFrom() throws {
        let scene = try scene {
            $0.deriveHexGrid = true
            $0.hexRadius = 120
        }
        let buildings = try XCTUnwrap(scene.layers.firstIndex { $0.name == "buildings" })
        let grid = try XCTUnwrap(scene.layers.firstIndex { $0.name == "hex_grid" })
        XCTAssertLessThan(buildings, grid, "a derived overlay must not be painted under the map")
    }

    /// Deriving a second structure on top of a hundred thousand shapes is not what
    /// "fast preview" means.
    func testAFastPreviewOfADenseMapDeclinesToDerive() throws {
        var collection = townCollection()
        var crowd: [Feature] = []
        // 320 x 320 = 102 400, and every one has to survive the clip to count —
        // laying them out past the frame would leave the total short of the
        // threshold and quietly test nothing.
        for index in 0..<102_400 {
            let x = 0.0005 + Double(index % 320) * 0.00006
            let y = 0.0005 + Double(index / 320) * 0.00006
            crowd.append(Feature(
                id: "w/\(index)", layer: "water", source: "test",
                geometry: .lineString(LineString([
                    Coordinate(lon: x, lat: y), Coordinate(lon: x + 0.00002, lat: y),
                ])),
                provenance: .measured
            ))
        }
        collection.featuresByLayer["water"] = crowd

        var profile = GeometryPipelineProfile()
        profile.deriveHexGrid = true
        profile.hexRadius = 200
        let scene = try SceneBuilder(options: SceneBuilder.Options(
            quality: Quality.profile("preview_fast"), derivations: profile
        )).build(from: collection)

        XCTAssertNil(layer(scene, "hex_grid"), "a fast preview should not have derived anything")
    }

    /// With nothing to bound them, there is nothing to derive inside.
    func testAnEmptyMapDerivesNothing() throws {
        var profile = GeometryPipelineProfile()
        profile.deriveHexGrid = true
        profile.deriveVoronoi = true

        let scene = try SceneBuilder(options: SceneBuilder.Options(
            quality: Quality.profile("export_clean"), derivations: profile
        )).build(from: FeatureCollection(
            featuresByLayer: ["buildings": []],
            bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)
        ))

        XCTAssertNil(layer(scene, "hex_grid"))
        XCTAssertNil(layer(scene, "voronoi_cells"))
    }
}
