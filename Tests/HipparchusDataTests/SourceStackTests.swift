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
        XCTAssertEqual(
            settings.map(\.key),
            ["interval", "bands", "shading", "sun", "sunheight", "relief"]
        )
        XCTAssertEqual(settings.first?.value, .number(0))
        // Shading is a choice about the drawing rather than a fact about the
        // ground, so it starts off and is asked for by name.
        XCTAssertEqual(settings.first { $0.key == "shading" }?.value, .text("off"))
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

    /// Overpass is the source that dominates a fetch and the one most likely to
    /// need adjusting: a large area times out at the stock sixty seconds, and a
    /// self-hosted or mirrored instance answers where the main one is refusing.
    /// The Python offers all three in its Settings tab; here they are inline on
    /// the source, where the rest of a source's settings already live.
    func testOverpassExposesItsTimeoutRateAndEndpoint() throws {
        var stack = SourceStack()
        stack.setSetting(SourceID.overpass, "timeout", .number(180))
        stack.setSetting(SourceID.overpass, "rate", .number(0.5))

        let overrides = stack.providerOverrides(for: SourceID.overpass)
        XCTAssertEqual(overrides["timeoutSeconds"], .number(180))
        XCTAssertEqual(overrides["requestsPerSecond"], .number(0.5))

        // The endpoint is a choice of known instances rather than free text: a
        // mistyped URL in a sidebar row fails as silently as a dead server.
        let endpoint = try XCTUnwrap(
            stack.settings(for: SourceID.overpass).first { $0.key == "endpoint" }
        )
        XCTAssertEqual(endpoint.kind, .choice)
        XCTAssertGreaterThan(endpoint.choices.count, 1)
        XCTAssertEqual(endpoint.value, .text(OverpassSettings().endpoint))
        XCTAssertTrue(
            endpoint.choices.contains(.text(OverpassSettings().endpoint)),
            "the default instance is not among the choices"
        )
    }

    /// The defaults must be the provider's own, or the sidebar would quietly
    /// freeze today's values into every saved session.
    func testOverpassSettingsDefaultToTheProvidersOwn() throws {
        let settings = SourceStack().settings(for: SourceID.overpass)
        let timeout = try XCTUnwrap(settings.first { $0.key == "timeout" })
        let rate = try XCTUnwrap(settings.first { $0.key == "rate" })
        XCTAssertEqual(timeout.value, .number(OverpassSettings().timeoutSeconds))
        XCTAssertEqual(rate.value, .number(OverpassSettings().requestsPerSecond))
        XCTAssertTrue(SourceStack().providerOverrides(for: SourceID.overpass).isEmpty)
    }

    /// Provenance is load-bearing: it is what stops a generated map being
    /// mistaken for a survey, and a source that declares none would be invisible
    /// in the one place that claim is made.
    func testEverySourceDeclaresItsProvenance() {
        for definition in SourceStack.defaultDefinitions {
            XCTAssertFalse(
                definition.label.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(definition.id) has no label for the sidebar"
            )
            XCTAssertFalse(
                definition.subtitle.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(definition.id) says nothing about what it provides"
            )
        }
    }

    /// **A setting that targets nothing is a knob wired to no machinery** — the
    /// defect this port has hit repeatedly in other guises. Every setting must
    /// name a provider field, and two settings on one source must not name the
    /// same one, or the second silently wins.
    func testEverySettingTargetsADistinctProviderField() {
        for definition in SourceStack.defaultDefinitions {
            var seen: Set<String> = []
            for setting in definition.settings {
                XCTAssertFalse(
                    setting.target.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(definition.id).\(setting.key) targets no provider field"
                )
                XCTAssertFalse(
                    setting.label.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(definition.id).\(setting.key) has no label, so the undo menu cannot name it"
                )
                XCTAssertTrue(
                    seen.insert(setting.target).inserted,
                    "\(definition.id) has two settings writing to '\(setting.target)'"
                )
                // A choice with no choices is a control nobody can operate.
                if setting.kind == .choice {
                    XCTAssertFalse(
                        setting.choices.isEmpty,
                        "\(definition.id).\(setting.key) is a choice with nothing to choose"
                    )
                }
            }
        }
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
