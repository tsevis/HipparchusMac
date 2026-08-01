import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Relief shading as the terrain provider emits it.
///
/// The arithmetic is pinned in `HillshadeParityTests`. What is checked here is
/// everything between the shade field and a feature: that it is off unless asked
/// for, that the polygons carry what the colour ramp needs, that the tones tile
/// the ground without overlapping, and that the sun the sheet was lit by is
/// recorded rather than lost.
///
/// Offline, like every test in this file: tiles are synthesised in-process.
/// A tile with a ridge across it, so there is a lit side and a shadowed one.
/// A plain ramp shades to a single tone and tests nothing about banding.
private func ridgeTileData() -> Data {
    let size = WebMercator.tilePixels
    let field = Field2D(rows: size, columns: size) { row, column in
        let across = (Double(column) - Double(size) / 2.0) / (Double(size) / 6.0)
        let along = Double(row) / Double(size)
        return 400.0 * exp(-across * across) + 220.0 * along
    }
    return encodeTerrariumPNG(field)!
}

final class TerrainHillshadeTests: XCTestCase {

    private func settings(_ mutate: (inout TerrainTileSettings) -> Void = { _ in }) -> TerrainTileSettings {
        var settings = TerrainTileSettings()
        settings.maxTiles = 4
        settings.targetPixels = 160
        settings.targetLineCount = 12
        settings.retryDelaySeconds = 0
        settings.emitHillshade = true
        mutate(&settings)
        return settings
    }

    private func fetch(_ settings: TerrainTileSettings) async throws -> FeatureCollection {
        let stub = StubFetcher(alwaysReturning: ridgeTileData())
        return try await TerrainTileProvider(settings: settings, http: stub).fetch(athens)
    }

    // MARK: -

    /// Shading changes the look of every sheet, so it is asked for rather than
    /// assumed. The layer is still *present* and empty — the panel has to be able
    /// to say "none here" rather than have the row vanish.
    func testShadingIsOffUntilItIsAskedFor() async throws {
        let result = try await fetch(settings { $0.emitHillshade = false })
        XCTAssertNotNil(
            result.featuresByLayer[TerrainLayer.hillshade],
            "the layer must exist even when it is switched off"
        )
        XCTAssertTrue(result.features(in: TerrainLayer.hillshade).isEmpty)
        XCTAssertEqual(result.metadata["hillshade_band_count"]?.doubleValue, 0)
    }

    func testShadingProducesFilledTonesWhenAskedFor() async throws {
        let result = try await fetch(settings())
        let shade = result.features(in: TerrainLayer.hillshade)
        XCTAssertFalse(shade.isEmpty, "a ridge lit from the north-west has both a lit and a shadowed side")
        XCTAssertEqual(result.metadata["hillshade_band_count"]?.doubleValue, Double(shade.count))
        for feature in shade {
            XCTAssertTrue(feature.geometry.hasArea, "a tone is a region, not a line")
            XCTAssertEqual(feature.layer, TerrainLayer.hillshade)
            XCTAssertEqual(feature.provenance, .measured)
        }
    }

    /// The whole reason the shade is banded rather than rasterised: these
    /// properties are what the existing two-stop fill ramp reads, so the layer
    /// colours itself through machinery that already exists.
    func testEveryToneCarriesWhatTheColourRampNeeds() async throws {
        let shade = try await fetch(settings()).features(in: TerrainLayer.hillshade)
        let count = shade.count
        var seen: Set<Int> = []
        for feature in shade {
            let index = Int(try XCTUnwrap(feature.property("band_index")?.doubleValue))
            XCTAssertEqual(feature.property("band_count")?.doubleValue, Double(count))
            XCTAssertTrue((0..<count).contains(index), "band index \(index) is outside 0..<\(count)")
            XCTAssertTrue(seen.insert(index).inserted, "band index \(index) appears twice")

            let low = try XCTUnwrap(feature.property("shade_low")?.doubleValue)
            let high = try XCTUnwrap(feature.property("shade_high")?.doubleValue)
            XCTAssertLessThan(low, high)
            XCTAssertTrue(low >= 0.0 && high <= 1.0, "a tone outside 0...1 is not a shade")
        }
    }

    /// Darker tones must come first, because the ramp runs shadow to light and a
    /// reversed order would light the map inside out while every individual
    /// polygon stayed correct.
    func testTonesAreOrderedFromShadowToLight() async throws {
        let shade = try await fetch(settings()).features(in: TerrainLayer.hillshade)
        let byIndex = shade.sorted { ($0.property("band_index")?.doubleValue ?? 0) < ($1.property("band_index")?.doubleValue ?? 0) }
        let lows = byIndex.compactMap { $0.property("shade_low")?.doubleValue }
        XCTAssertEqual(lows, lows.sorted(), "band 0 must be the deepest shadow")
    }

    func testTheSunTheSheetWasLitByIsRecorded() async throws {
        let sun = SunPosition(azimuthDegrees: 120.0, altitudeDegrees: 28.0)
        let result = try await fetch(settings {
            $0.sun = sun
            $0.hillshadeExaggeration = 2.5
        })
        XCTAssertEqual(result.metadata["hillshade_sun_azimuth"]?.doubleValue, 120.0)
        XCTAssertEqual(result.metadata["hillshade_sun_altitude"]?.doubleValue, 28.0)
        XCTAssertEqual(result.metadata["hillshade_exaggeration"]?.doubleValue, 2.5)

        for feature in result.features(in: TerrainLayer.hillshade) {
            XCTAssertEqual(feature.property("sun_azimuth")?.doubleValue, 120.0)
            XCTAssertEqual(feature.property("sun_altitude")?.doubleValue, 28.0)
        }
    }

    /// Moving the sun has to move the shadows. Without a real cell size the
    /// gradient would swamp the light direction and every sun would draw the same
    /// sheet — which looks plausible until you try to use the control.
    func testMovingTheSunChangesTheGroundThatIsInShadow() async throws {
        func darkestTone(azimuth: Double) async throws -> Geometry? {
            let shade = try await fetch(settings {
                $0.sun = SunPosition(azimuthDegrees: azimuth, altitudeDegrees: 45.0)
            }).features(in: TerrainLayer.hillshade)
            return shade.first { $0.property("band_index")?.doubleValue == 0 }?.geometry
        }

        let litFromNorthWest = try await darkestTone(azimuth: 315.0)
        let litFromSouthEast = try await darkestTone(azimuth: 135.0)
        let northWest = try XCTUnwrap(litFromNorthWest)
        let southEast = try XCTUnwrap(litFromSouthEast)
        XCTAssertNotEqual(
            northWest, southEast,
            "the same ground was in shadow under opposite suns, so the light is not being used"
        )
    }

    func testAskingForFewerThanTwoTonesProducesNoneRatherThanOne() async throws {
        let result = try await fetch(settings { $0.hillshadeBandCount = 1 })
        XCTAssertTrue(result.features(in: TerrainLayer.hillshade).isEmpty)
    }

    /// Flat ground has no relief to shade, and must not invent any — every cell
    /// takes the same tone, so there is no band boundary to trace.
    func testGroundWithNoReliefIsNotShaded() async throws {
        let size = WebMercator.tilePixels
        let flat = Field2D(rows: size, columns: size, repeating: 120.0)
        let stub = StubFetcher(alwaysReturning: encodeTerrariumPNG(flat)!)
        let result = try await TerrainTileProvider(settings: settings(), http: stub).fetch(athens)
        XCTAssertTrue(result.features(in: TerrainLayer.hillshade).isEmpty)
    }

    /// Contours, bands and summits must be exactly what they were: shading is an
    /// added layer, not a change to the ones already there.
    func testShadingLeavesEveryOtherLayerAlone() async throws {
        let without = try await fetch(settings { $0.emitHillshade = false })
        let with = try await fetch(settings())
        for layer in [TerrainLayer.minorContours, TerrainLayer.indexContours,
                      TerrainLayer.elevationBands, TerrainLayer.summits] {
            XCTAssertEqual(
                without.features(in: layer).count, with.features(in: layer).count,
                "\(layer) changed when shading was switched on"
            )
        }
    }
}
