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

    /// **Pinned to a named profile rather than to whatever the default is.**
    /// Half a dozen tests read this fixture's projection back as `EPSG:3857`,
    /// which was true only because the default happened to be the fast preview;
    /// when the default moved to Print Export they all failed at once, on a
    /// change that had nothing to do with what any of them was testing. A
    /// shared fixture that follows a default is a fixture that changes under
    /// tests which never asked it to.
    static let quality = Quality.profile("preview_fast")

    static func scene() throws -> RenderScene {
        try SceneBuilder(options: .init(quality: quality)).build(from: collection())
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

    /// Every layer a source can produce has a place in the draw order.
    ///
    /// A name missing from the order sorts after everything named — so night
    /// lights painted over every label and derived layer, while the panel filed
    /// them under Terrain, and admin boundaries floated wherever the alphabet
    /// put them. The Python has the same omission in `_ordered_layers`; ranking
    /// them is a deliberate divergence in the port's favour. Iso-lines of light
    /// sit with the relief they resemble; a border draws above the movement
    /// network it usually follows and below every label.
    func testEveryProducibleLayerHasAPlaceInTheDrawOrder() {
        func rank(_ name: String) -> Int { SceneBuilder.rank(name) }
        let unranked = SceneBuilder.preferredLayerOrder.count

        XCTAssertLessThan(rank("night_lights"), unranked, "night_lights is not ranked")
        XCTAssertLessThan(rank("admin_boundaries"), unranked, "admin_boundaries is not ranked")

        XCTAssertGreaterThan(rank("night_lights"), rank("terrain_index_contours"))
        XCTAssertLessThan(rank("night_lights"), rank("buildings"))

        XCTAssertGreaterThan(rank("admin_boundaries"), rank("ferry_routes"))
        XCTAssertLessThan(rank("admin_boundaries"), rank("summits"))
    }

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

        let previewTolerance = try XCTUnwrap(preview.diagnostics["simplified_tolerance"]?.doubleValue)
        let exportTolerance = try XCTUnwrap(export.diagnostics["simplified_tolerance"]?.doubleValue)
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

    /// The rule, rather than the two instances of it that were found by eye.
    ///
    /// `testEveryProducibleLayerHasAPlaceInTheDrawOrder` names `night_lights`
    /// and `admin_boundaries` because those are the ones somebody noticed. This
    /// holds the order to the layer inventory instead, so a source added
    /// tomorrow is ranked when it is added rather than when a sheet comes back
    /// with a fill painted over it. The Python had thirteen unranked layers,
    /// three of them fills, found only by rendering Cyprus and looking.
    func testTheDrawOrderCoversEveryLayerTheInventoryKnows() {
        let ranked = Set(SceneBuilder.preferredLayerOrder)
        let known = Set(LayerInventory.labels.keys).union(LayerInventory.groups.keys)
        let missing = known.subtracting(ranked).sorted()
        XCTAssertEqual(missing, [], "drawn last, over everything: \(missing)")
    }

    /// The other direction: a rank for a layer that does not exist is a typo.
    func testTheDrawOrderRanksNothingTheInventoryHasNeverHeardOf() {
        let known = Set(LayerInventory.labels.keys).union(LayerInventory.groups.keys)
        let unknown = SceneBuilder.preferredLayerOrder
            .filter { !known.contains($0) && $0 != "roads" && !$0.hasPrefix("roads_") }
            .sorted()
        XCTAssertEqual(unknown, [], "ranked but unknown to the inventory: \(unknown)")
    }

    func testNoLayerIsRankedTwice() {
        XCTAssertEqual(
            SceneBuilder.preferredLayerOrder.count,
            Set(SceneBuilder.preferredLayerOrder).count
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

final class CustomPaperTests: XCTestCase {

    /// The named sheets are document and poster proportions; a map is often
    /// neither. Two numbers must give exactly the aspect asked for.
    func testACustomSheetIsExactlyTheInchesAskedFor() throws {
        var page = PageSpec(paperName: PaperSize.customName, dpi: 300)
        page.customWidthInches = 20
        page.customHeightInches = 12

        let inches = try XCTUnwrap(page.inches(canvasAspect: 1))
        XCTAssertEqual(inches.width / inches.height, 5.0 / 3.0, accuracy: 1e-9)

        let pixels = page.pixelSize(canvasWidth: 1600, canvasHeight: 1200)
        XCTAssertEqual(pixels.width, 6000)
        XCTAssertEqual(pixels.height, 3600)
    }

    /// Orientation turns a named sheet. It must not turn a custom one: those
    /// two numbers are the request, and swapping them refuses what was typed.
    func testOrientationLeavesACustomSheetAlone() throws {
        var page = PageSpec(paperName: PaperSize.customName, orientation: "Landscape")
        page.customWidthInches = 12
        page.customHeightInches = 20

        let inches = try XCTUnwrap(page.inches(canvasAspect: 1))
        XCTAssertEqual(inches.width, 12, accuracy: 1e-9, "a tall custom sheet stays tall")
        XCTAssertEqual(inches.height, 20, accuracy: 1e-9)
    }

    /// A sheet of zero is not a sheet, and one of a thousand inches is a bitmap
    /// nobody can allocate.
    func testACustomSheetIsClampedToSomethingDrawable() throws {
        var page = PageSpec(paperName: PaperSize.customName)
        page.customWidthInches = 0
        page.customHeightInches = 10_000
        let paper = page.paper
        XCTAssertEqual(paper.widthInches, PageSpec.customInchRange.lowerBound)
        XCTAssertEqual(paper.heightInches, PageSpec.customInchRange.upperBound)
    }

    func testCustomIsOfferedInThePicker() {
        XCTAssertTrue(PaperSize.names.contains(PaperSize.customName))
    }
}

final class SheetFittingTests: XCTestCase {

    /// The letterbox is a sheet that disagrees with its map: a 2:1 world on a
    /// 4:3 canvas leaves a black bar that no margin setting can reach, because
    /// the space is sheet the map never covers.
    func testAWideMapGetsAWideSheet() {
        let world = Bounds(minX: -180, minY: -90, maxX: 180, maxY: 90)
        let fitted = CanvasTransform.sheet(
            fitting: world, into: CGSize(width: 1600, height: 1200)
        )
        XCTAssertEqual(fitted.width, 1600, "the long edge asked for is kept")
        XCTAssertEqual(fitted.height, 800, accuracy: 1, "2:1 map, 2:1 sheet")
    }

    /// The other way round, so a tall map is not silently widened.
    func testATallMapGetsATallSheet() {
        let tall = Bounds(minX: 0, minY: 0, maxX: 50, maxY: 200)
        let fitted = CanvasTransform.sheet(
            fitting: tall, into: CGSize(width: 1600, height: 1200)
        )
        XCTAssertEqual(fitted.height, 1600)
        XCTAssertEqual(fitted.width, 400, accuracy: 1)
    }

    /// Applied without checking first, so nothing to draw must not mean nothing
    /// to draw *on*.
    func testNoContentLeavesTheSheetAlone() {
        let asked = CGSize(width: 1600, height: 1200)
        XCTAssertEqual(CanvasTransform.sheet(fitting: nil, into: asked), asked)
    }

    /// Zero margin is a real request, not "unset".
    func testAZeroMarginBleedsToTheEdges() throws {
        let world = Bounds(minX: -180, minY: -90, maxX: 180, maxY: 90)
        let size = CGSize(width: 1600, height: 800)
        let bled = try XCTUnwrap(
            CanvasTransform(contentBounds: world, size: size, margin: 0)
        )
        let breathing = try XCTUnwrap(CanvasTransform(contentBounds: world, size: size))
        XCTAssertGreaterThan(
            bled.fitScale, breathing.fitScale,
            "bleeding must fill more of the sheet than the default margin does"
        )
        XCTAssertEqual(bled.offsetX, 0, accuracy: 0.5, "no bar on the left")
        XCTAssertEqual(bled.offsetY, 0, accuracy: 0.5, "no bar on the top")
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

    // MARK: - What the viewport is currently showing

    /// "Update map" needs to know what is actually on screen right now, not
    /// only what the fitted content bounds were at zoom 1 — that is what lets
    /// zooming out, then updating, fetch the bigger area actually being looked
    /// at rather than silently re-fetching the old one.
    func testAtIdentityTheVisibleBoundsMatchTheWholeCanvasMappedBack() throws {
        let t = try transform()
        let size = CGSize(width: 800, height: 600)
        let visible = t.visibleWorldBounds(canvasSize: size)

        let topLeft = t.screenToWorld(CGPoint(x: 0, y: 0))
        let bottomRight = t.screenToWorld(CGPoint(x: size.width, y: size.height))
        XCTAssertEqual(visible.minX, min(topLeft.x, bottomRight.x), accuracy: 1e-6)
        XCTAssertEqual(visible.maxY, max(topLeft.y, bottomRight.y), accuracy: 1e-6)
    }

    /// The whole point: zooming out doubles the ground shown, so fetching
    /// what is now visible gets more than what was fetched before.
    func testZoomingOutDoublesTheVisibleExtent() throws {
        let size = CGSize(width: 800, height: 600)
        let atOne = try transform(viewport: ViewportState(zoom: 1)).visibleWorldBounds(canvasSize: size)
        let atHalf = try transform(viewport: ViewportState(zoom: 0.5)).visibleWorldBounds(canvasSize: size)

        XCTAssertEqual(atHalf.maxX - atHalf.minX, (atOne.maxX - atOne.minX) * 2, accuracy: 1e-6)
        XCTAssertEqual(atHalf.maxY - atHalf.minY, (atOne.maxY - atOne.minY) * 2, accuracy: 1e-6)
    }

    func testZoomingInHalvesTheVisibleExtent() throws {
        let size = CGSize(width: 800, height: 600)
        let atOne = try transform(viewport: ViewportState(zoom: 1)).visibleWorldBounds(canvasSize: size)
        let atTwo = try transform(viewport: ViewportState(zoom: 2)).visibleWorldBounds(canvasSize: size)

        XCTAssertEqual(atTwo.maxX - atTwo.minX, (atOne.maxX - atOne.minX) / 2, accuracy: 1e-6)
    }

    /// Panning slides the visible window across the ground without resizing it.
    func testPanningMovesTheExtentWithoutResizingIt() throws {
        let size = CGSize(width: 800, height: 600)
        let still = try transform().visibleWorldBounds(canvasSize: size)
        let panned = try transform(viewport: ViewportState(panX: 100, panY: 0))
            .visibleWorldBounds(canvasSize: size)

        XCTAssertEqual(panned.maxX - panned.minX, still.maxX - still.minX, accuracy: 1e-6)
        XCTAssertNotEqual(panned.minX, still.minX)
    }

    /// A rotated viewport's visible region is a rotated rectangle, and only
    /// its true axis-aligned bounds can be read off by using all four
    /// corners — two opposite corners alone would under-report it, badly
    /// enough at 90° that width and height come out swapped instead of equal.
    func testRotationIsMeasuredFromAllFourCornersNotTwoOpposite() throws {
        let size = CGSize(width: 800, height: 600)
        let unrotated = try transform().visibleWorldBounds(canvasSize: size)
        let rotated90 = try transform(viewport: ViewportState(rotation: 90))
            .visibleWorldBounds(canvasSize: size)

        // A 90° turn swaps which canvas dimension maps to which world axis.
        XCTAssertEqual(
            rotated90.maxX - rotated90.minX, unrotated.maxY - unrotated.minY, accuracy: 1e-6
        )
        XCTAssertEqual(
            rotated90.maxY - rotated90.minY, unrotated.maxX - unrotated.minX, accuracy: 1e-6
        )
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

    /// Zooming and rotating turn the map where it is, rather than swinging it
    /// out of the window.
    ///
    /// Both used to happen about the origin of the pre-transform space, so the
    /// content walked down-right as it grew and left the canvas entirely at 90°.
    /// Nothing caught it because the round-trip stayed exact either way — an
    /// inverse can be perfect and still describe the wrong picture.
    func testZoomAndRotationTurnAboutTheCentreOfTheCanvas() throws {
        let scene = try Sample.scene()
        let bounds = try XCTUnwrap(scene.contentBounds)
        let middle = Coordinate(
            x: (bounds.minX + bounds.maxX) / 2, y: (bounds.minY + bounds.maxY) / 2
        )

        for viewport in [
            ViewportState(),
            ViewportState(zoom: 3),
            ViewportState(rotation: 90),
            ViewportState(zoom: 2.5, rotation: -45),
        ] {
            let point = try transform(viewport: viewport).worldToScreen(middle)
            XCTAssertEqual(point.x, 400, accuracy: 0.5, "zoom \(viewport.zoom) rot \(viewport.rotation)")
            XCTAssertEqual(point.y, 300, accuracy: 0.5, "zoom \(viewport.zoom) rot \(viewport.rotation)")
        }
    }

    /// Panning still moves the map, and by exactly what it was asked for.
    func testPanningMovesTheMapByTheAmountGiven() throws {
        let scene = try Sample.scene()
        let bounds = try XCTUnwrap(scene.contentBounds)
        let corner = Coordinate(x: bounds.minX, y: bounds.maxY)

        let still = try transform().worldToScreen(corner)
        let moved = try transform(viewport: ViewportState(panX: 30, panY: -20)).worldToScreen(corner)
        XCTAssertEqual(moved.x - still.x, 30, accuracy: 1e-9)
        XCTAssertEqual(moved.y - still.y, -20, accuracy: 1e-9)
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


/// Roads arrive as one layer and are drawn as eight.
///
/// Every one of the sixteen presets styles a road hierarchy with distinct weights
/// and colours, and until the split ran none of it was ever used: a footpath drew
/// exactly like a motorway.
final class RoadHierarchyTests: XCTestCase {

    private func road(_ highway: String, _ index: Int) -> Feature {
        Feature(
            id: "way/\(index)", layer: "roads", source: "overpass",
            geometry: .lineString(LineString([
                Coordinate(lon: 23.70 + Double(index) * 0.001, lat: 37.90),
                Coordinate(lon: 23.70 + Double(index) * 0.001, lat: 37.92),
            ])),
            provenance: .measured,
            properties: ["highway": .string(highway)]
        )
    }

    private func scene(_ highways: [String]) throws -> RenderScene {
        let features = highways.enumerated().map { road($1, $0) }
        return try SceneBuilder().build(from: FeatureCollection(
            featuresByLayer: ["roads": features],
            metadata: ["source": .string("overpass")],
            bbox: BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.1),
            provenance: .measured
        ))
    }

    func testEachHighwayValueLandsInItsOwnClass() throws {
        let scene = try scene([
            "motorway", "trunk", "primary", "secondary",
            "tertiary", "residential", "service", "raceway",
        ])

        func count(_ layer: String) -> Int {
            scene.layers.first { $0.name == layer }?.geometries.count ?? 0
        }
        XCTAssertEqual(count("roads_motorway"), 1)
        XCTAssertEqual(count("roads_trunk"), 1)
        XCTAssertEqual(count("roads_primary"), 1)
        XCTAssertEqual(count("roads_secondary"), 1)
        XCTAssertEqual(count("roads_tertiary"), 1)
        XCTAssertEqual(count("roads_residential"), 1)
        XCTAssertEqual(count("roads_service"), 1)
        // A value nobody listed is still a road.
        XCTAssertEqual(count("roads_other"), 1, "raceway went missing rather than to roads_other")
    }

    /// Link roads belong with the roads they link.
    func testLinkRoadsJoinTheirParentClass() throws {
        let scene = try scene(["motorway_link", "primary_link", "living_street", "footway"])

        func count(_ layer: String) -> Int {
            scene.layers.first { $0.name == layer }?.geometries.count ?? 0
        }
        XCTAssertEqual(count("roads_motorway"), 1)
        XCTAssertEqual(count("roads_primary"), 1)
        XCTAssertEqual(count("roads_residential"), 1)
        XCTAssertEqual(count("roads_service"), 1)
    }

    /// The point of the whole exercise: the classes draw differently.
    func testTheClassesTakeTheDistinctStylesThePresetDefines() throws {
        let scene = try scene(["motorway", "primary", "residential", "service"])

        func style(_ layer: String) throws -> LayerStyle {
            try XCTUnwrap(scene.layers.first { $0.name == layer }?.style)
        }
        let motorway = try style("roads_motorway")
        let primary = try style("roads_primary")
        let residential = try style("roads_residential")
        let service = try style("roads_service")

        // Widths descend with importance.
        XCTAssertGreaterThan(motorway.strokeWidth, primary.strokeWidth)
        XCTAssertGreaterThan(primary.strokeWidth, residential.strokeWidth)
        XCTAssertGreaterThan(residential.strokeWidth, service.strokeWidth)

        // And they are not all the same colour, which is what the old single
        // "roads" layer made them.
        let colours = [motorway, primary, residential, service].map(\.strokeColor)
        for outer in 0..<(colours.count - 1) {
            for inner in (outer + 1)..<colours.count {
                XCTAssertNotEqual(colours[outer], colours[inner], "two classes share a colour")
            }
        }
    }

    /// Drawn major over minor, so a motorway is not buried under the side streets.
    func testTheHierarchyIsDrawnMajorOverMinor() throws {
        let scene = try scene(["service", "motorway", "residential", "primary"])
        let order = scene.layers.map(\.name)

        let motorway = try XCTUnwrap(order.firstIndex(of: "roads_motorway"))
        let primary = try XCTUnwrap(order.firstIndex(of: "roads_primary"))
        let residential = try XCTUnwrap(order.firstIndex(of: "roads_residential"))
        let service = try XCTUnwrap(order.firstIndex(of: "roads_service"))

        XCTAssertLessThan(motorway, primary)
        XCTAssertLessThan(primary, residential)
        XCTAssertLessThan(residential, service)
    }

    /// With the hierarchy populated, an always-empty "Roads" row is noise.
    func testTheGenericRoadLayerGoesAway() throws {
        let scene = try scene(["motorway", "residential"])
        XCTAssertNil(scene.layers.first { $0.name == "roads" })
    }

    /// A source that already speaks the hierarchy passes straight through.
    func testAlreadyClassifiedRoadsAreLeftAlone() {
        let motorway = Feature(
            id: "a", layer: "roads_motorway", source: "vector_tiles",
            geometry: .lineString(LineString([
                Coordinate(lon: 0, lat: 0), Coordinate(lon: 1, lat: 1),
            ])),
            provenance: .measured
        )
        let result = SceneBuilder.classifyRoads(["roads_motorway": [motorway]])
        XCTAssertEqual(result["roads_motorway"]?.count, 1)
    }

    /// A feature moved between layers must say which layer it is in: the exporter
    /// and the diagnostics both read it.
    func testAMovedFeatureRecordsItsNewLayer() throws {
        let result = SceneBuilder.classifyRoads(["roads": [road("motorway", 0)]])
        XCTAssertEqual(result["roads_motorway"]?.first?.layer, "roads_motorway")
        XCTAssertEqual(result["roads_motorway"]?.first?.id, "way/0", "the feature lost its identity")
    }

    func testAMapWithNoRoadsIsUntouched() {
        let empty: [String: [Feature]] = ["water": []]
        XCTAssertEqual(SceneBuilder.classifyRoads(empty).keys.sorted(), ["water"])
    }
}

/// The profile has to govern how much ground is sampled, not only how the
/// samples are drawn.
final class QualitySamplingTests: XCTestCase {

    /// Print Export traced contours at full fidelity from a mosaic sampled at
    /// the preview's 1200 across — print-grade geometry over preview-grade
    /// ground. Fidelity downstream cannot restore detail never sampled.
    func testExportSamplesTheGroundMoreFinelyThanPreview() {
        let preview = Quality.profile("preview_fast")
        let print = Quality.profile("export_print")
        XCTAssertGreaterThan(
            print.samplingPixels, preview.samplingPixels,
            "an export profile that samples like a preview cannot be an export"
        )
    }

    /// Monotonic in menu order, so choosing a heavier profile never samples
    /// less than a lighter one.
    func testSamplingRisesWithTheProfile() {
        let widths = Quality.profiles.map(\.samplingPixels)
        XCTAssertEqual(widths, widths.sorted(), "menu order must not go backwards")
    }

    /// The mosaic caps at 256 tiles, which is 4096 px across. A profile asking
    /// past that would be silently clipped — the exact trap `maxTiles`
    /// documents.
    func testNoProfileAsksForMoreThanTheMosaicCanGive() {
        for profile in Quality.profiles {
            XCTAssertLessThanOrEqual(
                profile.samplingPixels, 4096,
                "\(profile.key) would be clipped by the tile budget without saying so"
            )
        }
    }
}
