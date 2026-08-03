import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry
@testable import HipparchusRender

/// The one piece of furniture that is on by default.
///
/// The application draws buoys as chart symbols, wrecks with their masts and a
/// sea floor in filled depth bands, and the better all of that gets the more it
/// looks like something it is not. What is checked here is that the sheet says
/// so, that it says so only when it is actually drawing the sea, and that the
/// machine-readable half cannot be turned off.
final class NotForNavigationTests: XCTestCase {

    private let bbox = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)

    private func scene(
        _ layers: [RenderLayer], metadata: [String: PropertyValue] = [:]
    ) -> RenderScene {
        RenderScene(layers: layers, bbox: bbox, metadata: metadata)
    }

    private func populated(_ name: String) -> RenderLayer {
        var layer = RenderLayer(name: name)
        layer.append(
            .lineString(LineString([
                Coordinate(lon: 23.4, lat: 36.5), Coordinate(lon: 23.6, lat: 36.7),
            ])),
            weight: nil, fillColor: nil
        )
        return layer
    }

    private func svg(_ scene: RenderScene, composition: SVGExporter.Composition? = nil) throws -> String {
        var options = SVGExporter.Options()
        options.width = 1200
        options.height = 900
        if let composition { options.composition = composition }
        return SVGExporter(options: options).svg(for: scene)
    }

    // MARK: - When it applies

    func testASheetWithSeaMarksIsDrawingTheSea() {
        for layer in Seamarks.allLayers {
            XCTAssertTrue(
                NotForNavigation.applies(to: scene([populated(layer)])),
                "\(layer) should count as drawing the sea"
            )
        }
    }

    func testDepthsCountToo() {
        XCTAssertTrue(NotForNavigation.applies(to: scene([populated(TerrainLayer.bathymetry)])))
        XCTAssertTrue(NotForNavigation.applies(to: scene([populated(TerrainLayer.depthBands)])))
    }

    /// A drawing of where the water goes is at least as actionable as a depth,
    /// and it was missing from the list until a currents sheet was rendered and
    /// the notice turned out to be arriving only because bathymetry happened to
    /// be on as well.
    func testCurrentsCountToo() {
        XCTAssertTrue(NotForNavigation.applies(to: scene([populated(CurrentsProvider.layer)])))
    }

    // MARK: - Saying when

    /// A depth is as true this year as last. A current is not, and `[(last)]`
    /// means *the server's most recent step*, which is not the same as today —
    /// the geostrophic dataset answered an August request with a field from
    /// 26 March.
    func testASheetDrawingSomethingThatChangesSaysWhen() {
        let dated = scene(
            [populated(CurrentsProvider.layer)],
            metadata: ["erddap_current.erddap_time": .string("2026-03-26T00:00:00Z")]
        )
        XCTAssertTrue(NotForNavigation.notice(for: dated).hasSuffix("ocean data 2026-03-26"))
    }

    /// A sheet of depths and sea marks has nothing time-varying on it, and a
    /// date there would be inventing a currency it does not have.
    func testASheetWithNothingTimeVaryingStaysUndated() {
        let plain = scene([populated(TerrainLayer.depthBands)])
        XCTAssertEqual(NotForNavigation.notice(for: plain), NotForNavigation.notice)
    }

    /// The oldest ingredient decides, for the same reason the weakest provenance
    /// does: the sheet cannot claim currency its stalest layer does not support.
    func testTheEarliestObservationIsTheOneStated() {
        let mixed = scene(
            [populated(CurrentsProvider.layer)],
            metadata: [
                "erddap_current.erddap_time": .string("2026-03-26T00:00:00Z"),
                "erddap_sst.erddap_time": .string("2026-08-01T09:00:00Z"),
            ]
        )
        XCTAssertTrue(NotForNavigation.notice(for: mixed).hasSuffix("ocean data 2026-03-26"))
    }

    /// The date has to reach the paper, not just the diagnostics — a reader
    /// looking at the sheet is the person the notice is for.
    func testTheDateReachesTheSheet() throws {
        let dated = scene(
            [populated(CurrentsProvider.layer)],
            metadata: ["erddap_current.erddap_time": .string("2026-03-26T00:00:00Z")]
        )
        XCTAssertTrue(try svg(dated).contains("ocean data 2026-03-26"))
    }

    /// A river and a shoreline are geography. A street map of Amsterdam is not
    /// pretending to be a chart, and warning about it would teach a reader to
    /// ignore the warning.
    func testWaterAndCoastlineAreNotEnough() {
        XCTAssertFalse(NotForNavigation.applies(to: scene([populated("water")])))
        XCTAssertFalse(NotForNavigation.applies(to: scene([populated("coastline")])))
        XCTAssertFalse(NotForNavigation.applies(to: scene([populated("roads")])))
    }

    /// An empty `bathymetry` layer sits on every terrain sheet ever drawn — it
    /// is how the panel says "none here". Stamping a warning on a map of Everest
    /// because of it would be the same failure as never warning at all.
    func testAnEmptyMarineLayerIsNotDrawingTheSea() {
        XCTAssertFalse(NotForNavigation.applies(to: scene([
            RenderLayer(name: TerrainLayer.bathymetry),
            RenderLayer(name: Seamarks.buoys),
        ])))
    }

    // MARK: - What the sheet says

    func testTheNoticeIsDrawnWithoutBeingAskedFor() throws {
        let exported = try svg(scene([populated(Seamarks.buoys)]))
        XCTAssertTrue(exported.contains("not_for_navigation"), "the group is missing")
        XCTAssertTrue(exported.contains("NOT FOR NAVIGATION"))
    }

    /// Every other piece of furniture is off until asked for. This one being on
    /// is the statement, so a default composition must carry it.
    func testTheDefaultCompositionWantsNothingElse() {
        let composition = SVGExporter.Composition()
        XCTAssertFalse(composition.wantsAnything, "the rest of the furniture should still be off")
        XCTAssertTrue(composition.includeNotForNavigation)
    }

    func testASheetWithNoSeaSaysNothing() throws {
        let exported = try svg(scene([populated("roads")]))
        XCTAssertFalse(exported.contains("NOT FOR NAVIGATION"))
    }

    /// It is a drawing tool, and a poster of the Aegean does not want a warning
    /// stamped across it.
    func testTheWordsCanBeTurnedOff() throws {
        var composition = SVGExporter.Composition()
        composition.includeNotForNavigation = false
        let exported = try svg(scene([populated(Seamarks.buoys)]), composition: composition)
        XCTAssertFalse(exported.contains("NOT FOR NAVIGATION"))
    }

    /// But not the claim. This is the half that survives somebody removing the
    /// other half.
    func testTheClaimSurvivesTurningTheWordsOff() throws {
        var composition = SVGExporter.Composition()
        composition.includeNotForNavigation = false
        let exported = try svg(scene([populated(Seamarks.buoys)]), composition: composition)
        XCTAssertTrue(
            exported.contains("data-hipparchus-not-for-navigation=\"true\""),
            "the file should still say what it is to anything that reads it"
        )
    }

    func testASheetWithNoSeaMakesNoSuchClaim() throws {
        let exported = try svg(scene([populated("roads")]))
        XCTAssertFalse(exported.contains("data-hipparchus-not-for-navigation"))
    }

    /// The notice has to say what is wrong with the sheet, not merely that
    /// something is. "Not for navigation" alone reads as boilerplate.
    func testTheNoticeSaysWhyRatherThanOnlyThat() {
        XCTAssertTrue(NotForNavigation.notice.contains("Notices to Mariners"))
        XCTAssertTrue(NotForNavigation.notice.lowercased().contains("survey"))
    }

    // MARK: - Through the scene builder

    /// The SVG has furniture to write this on; a PNG and a PDF do not. The
    /// diagnostics travel beside all three.
    func testTheSceneCarriesTheFlagForTheExportsWithNoFurniture() throws {
        let collection = FeatureCollection(
            featuresByLayer: [Seamarks.buoys: [
                Feature(
                    id: "node/1", layer: Seamarks.buoys, source: "overpass",
                    geometry: .point(Coordinate(lon: 23.5, lat: 36.6)),
                    provenance: .measured, properties: [:]
                ),
            ]],
            metadata: ["source": .string("overpass")],
            bbox: bbox, provenance: .measured
        )
        let built = try SceneBuilder().build(from: collection)
        XCTAssertEqual(built.diagnostics["not_for_navigation"]?.boolValue, true)
    }

    func testASheetWithNoSeaSaysSoInTheDiagnosticsToo() throws {
        let collection = FeatureCollection(
            featuresByLayer: ["roads": [
                Feature(
                    id: "way/1", layer: "roads", source: "overpass",
                    geometry: .lineString(LineString([
                        Coordinate(lon: 23.4, lat: 36.5), Coordinate(lon: 23.6, lat: 36.7),
                    ])),
                    provenance: .measured, properties: [:]
                ),
            ]],
            metadata: ["source": .string("overpass")],
            bbox: bbox, provenance: .measured
        )
        let built = try SceneBuilder().build(from: collection)
        XCTAssertEqual(built.diagnostics["not_for_navigation"]?.boolValue, false)
    }
}
