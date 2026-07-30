import XCTest
@testable import HipparchusData

/// Ported from `tests/test_source_stack.py`.
///
/// The rule these all circle is the one the interface is built on: sources stack,
/// they do not replace. A model dropdown that silently discarded the rest of the
/// map is what this design exists to prevent, so "adding elevation keeps the
/// streets" is the test that matters most here.
final class SourceStackTests: XCTestCase {

    // MARK: - The catalogue

    func testOpenStreetMapIsTheOnlyDefault() {
        XCTAssertEqual(SourceStack().enabledIDs, [SourceID.overpass])
    }

    func testEverySourceThatCanStandAloneSuppliesABase() {
        for definition in SourceStack.defaultDefinitions {
            var stack = SourceStack()
            stack.setEnabled(SourceID.overpass, false)
            if definition.needsPath { stack.setPath(definition.id, "/tmp/whatever.pbf") }
            stack.setEnabled(definition.id, true)
            XCTAssertEqual(stack.plan?.base, definition.id, "\(definition.id) cannot be a base")
        }
    }

    /// Provenance is load-bearing: it is what stops a generated map being mistaken
    /// for a survey. Every source has to declare what it is.
    func testTheGeneratedFieldIsLabelledSynthetic() throws {
        let simulated = try XCTUnwrap(SourceStack().definition(SourceID.simulatedTerrain))
        XCTAssertEqual(simulated.provenance, .synthetic)

        let terrain = try XCTUnwrap(SourceStack().definition(SourceID.terrainTiles))
        XCTAssertEqual(terrain.provenance, .measured)

        let gibs = try XCTUnwrap(SourceStack().definition(SourceID.gibsImagery))
        XCTAssertEqual(gibs.provenance, .uncalibrated, "GIBS is rendered brightness, not radiance")

        let satellites = try XCTUnwrap(SourceStack().definition(SourceID.satelliteTracks))
        XCTAssertEqual(satellites.provenance, .approximate)
    }

    // MARK: - Stacking

    /// The single most important behaviour in the whole interface.
    func testAddingElevationKeepsTheStreets() throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)

        let plan = try XCTUnwrap(stack.plan)
        XCTAssertEqual(plan.base, SourceID.overpass, "the streets must still be the base")
        XCTAssertEqual(plan.extras, [SourceID.terrainTiles])
        XCTAssertEqual(plan.sourceIDs, [SourceID.overpass, SourceID.terrainTiles])
    }

    func testManySourcesStackOntoOneBase() throws {
        var stack = SourceStack()
        for id in [SourceID.terrainTiles, SourceID.usgsEarthquakes, SourceID.satelliteTracks] {
            stack.setEnabled(id, true)
        }
        let plan = try XCTUnwrap(stack.plan)
        XCTAssertEqual(plan.base, SourceID.overpass)
        XCTAssertEqual(
            plan.extras,
            [SourceID.terrainTiles, SourceID.usgsEarthquakes, SourceID.satelliteTracks]
        )
    }

    func testOpenStreetMapAlwaysBecomesTheBaseWhenPresent() throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.overpass, false)
        stack.setEnabled(SourceID.terrainTiles, true)
        XCTAssertEqual(stack.plan?.base, SourceID.terrainTiles)

        // Ticked last, but still the base.
        stack.setEnabled(SourceID.overpass, true)
        XCTAssertEqual(stack.plan?.base, SourceID.overpass)
    }

    func testNoSourceSelectedIsNotAFetch() {
        var stack = SourceStack()
        stack.setEnabled(SourceID.overpass, false)
        XCTAssertNil(stack.plan, "an empty stack is a prompt, not an error")
        XCTAssertEqual(stack.summary, "No sources selected")
    }

    func testAProviderNeverAppearsTwice() throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)
        stack.setEnabled(SourceID.terrainTiles, true)
        let plan = try XCTUnwrap(stack.plan)
        XCTAssertEqual(plan.sourceIDs.count, Set(plan.sourceIDs).count)
        XCTAssertEqual(plan.sourceIDs.count, 2)
    }

    func testUntickingRemovesTheSource() {
        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)
        stack.setEnabled(SourceID.terrainTiles, false)
        XCTAssertEqual(stack.enabledIDs, [SourceID.overpass])
    }

    func testToggleReportsTheNewState() {
        var stack = SourceStack()
        XCTAssertTrue(stack.toggle(SourceID.terrainTiles))
        XCTAssertFalse(stack.toggle(SourceID.terrainTiles))
    }

    /// The same set of ticks must fetch in the same order however it was assembled.
    func testOrderFollowsTheSidebarNotTheClicks() {
        var stack = SourceStack()
        stack.setEnabled(SourceID.overpass, false)
        stack.setEnabled(SourceID.satelliteTracks, true)
        stack.setEnabled(SourceID.terrainTiles, true)
        stack.setEnabled(SourceID.usgsEarthquakes, true)

        XCTAssertEqual(
            stack.enabledIDs,
            [SourceID.terrainTiles, SourceID.usgsEarthquakes, SourceID.satelliteTracks]
        )
    }

    func testAnUnknownSourceIsIgnored() {
        var stack = SourceStack()
        stack.setEnabled("mystery_provider", true)
        XCTAssertEqual(stack.enabledIDs, [SourceID.overpass])
        XCTAssertFalse(stack.isAvailable("mystery_provider"))
    }

    // MARK: - File-backed sources

    func testASourceNeedingAFileCannotBeTickedWithoutOne() {
        var stack = SourceStack()
        stack.setEnabled(SourceID.localOSMPBF, true)
        XCTAssertFalse(stack.isEnabled(SourceID.localOSMPBF))
        XCTAssertFalse(stack.isAvailable(SourceID.localOSMPBF))
    }

    func testChoosingAFileMakesItAvailable() {
        var stack = SourceStack()
        stack.setPath(SourceID.localOSMPBF, "/data/greece.osm.pbf")
        XCTAssertTrue(stack.isAvailable(SourceID.localOSMPBF))
        stack.setEnabled(SourceID.localOSMPBF, true)
        XCTAssertTrue(stack.isEnabled(SourceID.localOSMPBF))
        XCTAssertEqual(stack.path(SourceID.localOSMPBF), "/data/greece.osm.pbf")
    }

    func testClearingTheFileUnticksIt() {
        var stack = SourceStack()
        stack.setPath(SourceID.localOSMPBF, "/data/greece.osm.pbf")
        stack.setEnabled(SourceID.localOSMPBF, true)

        stack.setPath(SourceID.localOSMPBF, "   ")
        XCTAssertFalse(stack.isEnabled(SourceID.localOSMPBF), "a source that lost its file cannot stay ticked")
        XCTAssertEqual(stack.path(SourceID.localOSMPBF), "")
    }

    func testSourcesWithoutFilesAreAlwaysAvailable() {
        let stack = SourceStack()
        for definition in SourceStack.defaultDefinitions where !definition.needsPath {
            XCTAssertTrue(stack.isAvailable(definition.id), "\(definition.id)")
        }
    }

    // MARK: - Settings

    func testDeclaredSettingsComeBackWithDefaults() throws {
        let settings = SourceStack().settings(for: SourceID.terrainTiles)
        XCTAssertEqual(settings.map(\.key), ["interval", "bands"])
        XCTAssertEqual(settings.first?.value, .number(0))
    }

    func testAnOverrideReplacesTheDefault() throws {
        var stack = SourceStack()
        stack.setSetting(SourceID.terrainTiles, "interval", .number(50))
        let interval = try XCTUnwrap(stack.settings(for: SourceID.terrainTiles).first { $0.key == "interval" })
        XCTAssertEqual(interval.value, .number(50))
    }

    func testOverridesAreKeyedByProviderAttribute() {
        var stack = SourceStack()
        stack.setSetting(SourceID.terrainTiles, "interval", .number(50))
        // "interval" is what the sidebar calls it; the provider field is not.
        XCTAssertEqual(
            stack.providerOverrides(for: SourceID.terrainTiles),
            ["contourIntervalMetres": .number(50)]
        )
    }

    /// A provider's own defaults are the better answer for anything untouched.
    func testUntouchedSourcesOverrideNothing() {
        XCTAssertTrue(SourceStack().providerOverrides(for: SourceID.terrainTiles).isEmpty)
    }

    func testAnUnknownSettingIsIgnored() {
        var stack = SourceStack()
        stack.setSetting(SourceID.terrainTiles, "chromaticity", .number(3))
        XCTAssertTrue(stack.providerOverrides(for: SourceID.terrainTiles).isEmpty)
    }

    func testNumberSettingsDisplayWithoutTrailingZeros() {
        var stack = SourceStack()
        stack.setSetting(SourceID.terrainTiles, "interval", .number(20))
        let settings = stack.settings(for: SourceID.terrainTiles)
        XCTAssertEqual(settings.first { $0.key == "interval" }?.display, "20 m")

        stack.setSetting(SourceID.usgsEarthquakes, "magnitude", .number(2.5))
        XCTAssertEqual(
            stack.settings(for: SourceID.usgsEarthquakes).first { $0.key == "magnitude" }?.display,
            "2.5 M"
        )
    }

    // MARK: - Summary

    func testTheSummaryNamesWhatTheMapIsMadeOf() {
        var stack = SourceStack()
        XCTAssertEqual(stack.summary, "OpenStreetMap")

        stack.setEnabled(SourceID.terrainTiles, true)
        XCTAssertEqual(stack.summary, "OpenStreetMap + Elevation")

        stack.setEnabled(SourceID.usgsEarthquakes, true)
        XCTAssertEqual(stack.summary, "OpenStreetMap, Elevation + Earthquakes")
    }
}
