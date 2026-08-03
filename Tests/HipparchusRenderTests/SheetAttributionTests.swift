import XCTest
@testable import HipparchusData
@testable import HipparchusGeometry
@testable import HipparchusRender

/// Whether the credit actually travels.
///
/// The About panel said the attributions travel with anything published from
/// here, and for a long time **nothing travelled** — no export carried a credit
/// of any kind. A registry that only feeds a window leaves that sentence false,
/// so what is checked here is the exported file rather than the registry.
final class SheetAttributionTests: XCTestCase {

    private let bbox = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)

    private func scene(_ metadata: [String: PropertyValue]) -> RenderScene {
        var layer = RenderLayer(name: "contours")
        layer.append(
            .lineString(LineString([
                Coordinate(lon: 23.4, lat: 36.5), Coordinate(lon: 23.6, lat: 36.7),
            ])),
            weight: nil, fillColor: nil
        )
        return RenderScene(layers: [layer], bbox: bbox, metadata: metadata)
    }

    private func svg(_ scene: RenderScene) -> String {
        var options = SVGExporter.Options()
        options.width = 1200
        options.height = 900
        return SVGExporter(options: options).svg(for: scene)
    }

    // MARK: - Reading what a sheet used

    func testTheSourcesComeFromTheMerge() {
        let found = SheetAttribution.sources(
            in: scene(["sources": .string("terrain_tiles, overpass")])
        )
        XCTAssertEqual(found, ["terrain_tiles", "overpass"])
    }

    /// **A single provider never goes through the merge**, so it writes `source`
    /// and no `sources`. Reading only the plural credited nothing at all on a
    /// plain terrain sheet — the commonest export this application makes — and
    /// the tests passed throughout, because every one of them supplied the key
    /// the code happened to read. A real render found it.
    func testASingleProviderFetchIsStillCredited() {
        let direct = scene(["source": .string("terrain_tiles")])
        XCTAssertEqual(SheetAttribution.sources(in: direct), ["terrain_tiles"])
        XCTAssertTrue(SheetAttribution.statement(for: direct).contains("Terrain Tiles"))
    }

    /// The merge writes the same list into `source` joined with `+`.
    func testThePlusJoinedFormIsReadToo() {
        let merged = scene(["source": .string("terrain_tiles+overpass")])
        XCTAssertEqual(SheetAttribution.sources(in: merged), ["terrain_tiles", "overpass"])
    }

    /// A fetch that found nothing records `none`, and a placeholder is not a
    /// source to credit.
    func testAPlaceholderSourceIsNotCredited() {
        XCTAssertTrue(SheetAttribution.sources(in: scene(["source": .string("none")])).isEmpty)
        XCTAssertTrue(SheetAttribution.sources(in: scene(["source": .string("unknown")])).isEmpty)
    }

    /// **EMODnet has no provider of its own.** It is blended inside
    /// `TerrainTileProvider`, so a sheet standing on it reports `terrain_tiles`
    /// and would otherwise credit nobody for the one source here whose licence
    /// explicitly asks for a line.
    func testEMODnetIsCreditedEvenThoughItIsNotASourceOfItsOwn() {
        let blended = scene([
            "sources": .string("terrain_tiles"),
            "terrain_tiles.bathymetry_source": .string("emodnet+terrarium"),
        ])
        XCTAssertTrue(SheetAttribution.sources(in: blended).contains(emodnetBathymetrySourceID))
        XCTAssertTrue(SheetAttribution.statement(for: blended).contains("EMODnet"))
    }

    /// The merge namespaces a provider's metadata by source; a single-provider
    /// fetch never goes through the merge. Both key forms have to work, and only
    /// one of them is what the app produces.
    func testTheUnnamespacedKeyWorksToo() {
        let direct = scene([
            "sources": .string("terrain_tiles"),
            "bathymetry_source": .string("emodnet+terrarium"),
        ])
        XCTAssertTrue(SheetAttribution.sources(in: direct).contains(emodnetBathymetrySourceID))
    }

    /// A sheet that fell back to the global grid did not use EMODnet, and saying
    /// it did would be a false credit rather than a generous one.
    func testAFallbackToTheGlobalGridDoesNotCreditEMODnet() {
        let fallback = scene([
            "sources": .string("terrain_tiles"),
            "terrain_tiles.bathymetry_source": .string("terrarium"),
        ])
        XCTAssertFalse(
            SheetAttribution.sources(in: fallback).contains(emodnetBathymetrySourceID)
        )
    }

    // MARK: - Whether it travels

    func testTheSVGCarriesTheCredit() {
        let out = svg(scene(["sources": .string("terrain_tiles, overpass")]))
        XCTAssertTrue(out.contains("data-hipparchus-attribution"), "no root attribute")
        XCTAssertTrue(out.contains("<metadata id=\"attribution\">"), "no metadata element")
        XCTAssertTrue(out.contains("OpenStreetMap contributors"), out.prefix(600).description)
    }

    /// A data attribute satisfies a machine and nobody else. `<metadata>` is
    /// where an editor looks, and this exporter exists so the file gets opened
    /// somewhere else.
    func testTheCreditIsReadableAndNotOnlyMachineReadable() {
        let out = svg(scene(["sources": .string("overpass")]))
        let element = try? XCTUnwrap(
            out.range(of: "<metadata id=\"attribution\">").map { out[$0.upperBound...] }
        )
        XCTAssertTrue(element?.hasPrefix("Map data © OpenStreetMap contributors") ?? false)
    }

    /// The diagnostics accompany *every* format. A PNG and a PDF have nowhere to
    /// print a credit of their own, so this is the only place theirs can live.
    func testTheDiagnosticsCarryTheCreditForFormatsThatCannot() throws {
        var options = SVGExporter.Options()
        options.width = 1200
        options.height = 900
        let diagnostics = SVGExporter(options: options).diagnostics(
            for: scene(["sources": .string("terrain_tiles, usgs_earthquakes")]),
            format: "png"
        )
        let credited = try XCTUnwrap(diagnostics.attribution).map(\.sourceID)
        XCTAssertEqual(Set(credited), [SourceID.terrainTiles, SourceID.usgsEarthquakes])
    }

    /// A sheet drawn from a generated field owes nobody anything, and an empty
    /// credit should be absent rather than present and blank.
    func testASheetThatOwesNothingCarriesNoCredit() {
        let out = svg(scene(["sources": .string("simulated_terrain")]))
        XCTAssertFalse(out.contains("data-hipparchus-attribution"))
        XCTAssertFalse(out.contains("<metadata id=\"attribution\">"))
    }

    /// The credit survives a round trip through the JSON, which is the form it
    /// actually reaches anybody in.
    func testTheCreditSurvivesTheDiagnosticsFile() throws {
        var options = SVGExporter.Options()
        options.width = 800
        options.height = 600
        let written = SVGExporter(options: options).diagnostics(
            for: scene(["sources": .string("overpass")]), format: "svg"
        )
        let reborn = try JSONDecoder().decode(
            ExportDiagnostics.self, from: try written.jsonData()
        )
        XCTAssertEqual(reborn.attribution?.first?.sourceID, SourceID.overpass)
    }

    /// A diagnostics file written before the registry existed has no
    /// `attribution` key at all, and must still decode.
    func testADiagnosticsFileFromBeforeTheRegistryStillDecodes() throws {
        let old = """
            {"format":"svg","width":100,"height":100,"renderCRS":"EPSG:4326",
             "sourceCRS":"EPSG:4326","layers":[],"metadata":{},"diagnostics":{}}
            """
        let reborn = try JSONDecoder().decode(ExportDiagnostics.self, from: Data(old.utf8))
        XCTAssertNil(reborn.attribution)
    }
}
