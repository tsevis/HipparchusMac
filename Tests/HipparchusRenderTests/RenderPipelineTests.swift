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
}

final class SceneBuilderTests: XCTestCase {

    func testLayersComeOutInDrawOrderWithGroundUnderLinework() throws {
        let scene = try Sample.scene()
        XCTAssertEqual(scene.layers.map(\.name), SceneBuilder.layerOrder)
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
        let style = SceneBuilder.TerrainStyle()
        XCTAssertEqual(bands.fillColor(at: 0), style.bandLowColor)
        XCTAssertEqual(bands.fillColor(at: 1), style.bandHighColor)
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
