import XCTest
@testable import HipparchusRender

/// Plugins, and the one property that matters about loading them: a bad one
/// must not take the others down with it.
final class PluginLoaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writePlugin(_ folder: String, _ json: String) throws {
        let url = directory.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try json.write(to: url.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
    }

    private func loader(
        builtins: [any Plugin] = [], reserved: Set<String> = ["Santorini"]
    ) -> PluginLoader {
        PluginLoader(
            builtins: builtins, userPluginDirectory: directory, reservedPlaceNames: reserved
        )
    }

    // MARK: - Places

    func testAPluginCanContributePlaces() throws {
        try writePlugin("islands", #"""
        {"id": "com.example.islands", "name": "Greek Islands", "places": [
          {"name": "Lefkada", "west": 20.53, "south": 38.56, "east": 20.80, "north": 38.86},
          {"name": "Kefalonia", "west": 20.35, "south": 38.05, "east": 20.80, "north": 38.50}
        ]}
        """#)
        let registry = loader().loadAll()
        XCTAssertEqual(registry.places.map(\.name), ["Lefkada", "Kefalonia"])
        let lefkada = try XCTUnwrap(registry.places.first)
        XCTAssertEqual(lefkada.bbox.minLon, 20.53, accuracy: 1e-9)
        XCTAssertEqual(lefkada.bbox.maxLat, 38.86, accuracy: 1e-9)
    }

    func testAPlaceThatIsNotAnAreaIsRefused() throws {
        // West east of east. Refused rather than corrected: swapping them
        // silently hides whatever produced the file.
        try writePlugin("backwards", #"""
        {"id": "com.example.backwards", "name": "Backwards", "places": [
          {"name": "Nowhere", "west": 25.0, "south": 36.0, "east": 24.0, "north": 37.0}
        ]}
        """#)
        let loader = loader()
        _ = loader.loadAll()
        XCTAssertTrue(loader.loadedPlugins.isEmpty)
        XCTAssertEqual(loader.loadErrors.count, 1)
        XCTAssertTrue(loader.loadErrors[0].contains("Nowhere"), loader.loadErrors[0])
    }

    func testAPluginCannotShadowABuiltInPlace() throws {
        try writePlugin("cuckoo", #"""
        {"id": "com.example.cuckoo", "name": "Cuckoo", "places": [
          {"name": "Santorini", "west": 1.0, "south": 1.0, "east": 2.0, "north": 2.0}
        ]}
        """#)
        let registry = loader(reserved: ["Santorini"]).loadAll()
        XCTAssertTrue(registry.places.isEmpty, "a plugin must not redefine a place the app ships")
    }

    func testOneBadPlaceDoesNotCostTheWholePlugin_sPresets() throws {
        // A plugin is all-or-nothing on purpose: registration happens against
        // a copy, so a plugin that throws part way leaves nothing behind
        // rather than half of itself.
        try writePlugin("mixed", #"""
        {"id": "com.example.mixed", "name": "Mixed",
         "presets": [{"name": "Mixed Style"}],
         "places": [{"name": "Broken", "west": 5.0, "south": 5.0, "east": 4.0, "north": 6.0}]}
        """#)
        let loader = loader()
        let registry = loader.loadAll()
        XCTAssertTrue(registry.presets.isEmpty, "the preset must not survive its plugin failing")
        XCTAssertTrue(registry.places.isEmpty)
        XCTAssertEqual(loader.loadErrors.count, 1)
    }

    // MARK: - Loading

    func testNoPluginsAnywhereLoadsNothingAndFailsNothing() throws {
        let loader = PluginLoader(builtins: [], userPluginDirectory: directory)
        let registry = loader.loadAll()
        XCTAssertTrue(loader.loadedPlugins.isEmpty)
        XCTAssertTrue(loader.loadErrors.isEmpty)
        XCTAssertTrue(registry.presets.isEmpty)
    }

    func testAMissingUserDirectoryIsNotAnError() throws {
        let loader = PluginLoader(
            builtins: [], userPluginDirectory: directory.appendingPathComponent("nope")
        )
        _ = loader.loadAll()
        XCTAssertTrue(loader.loadErrors.isEmpty)
    }

    func testABuiltinPluginLoadsAndRegisters() throws {
        let loader = loader(builtins: [DemoPlugin()])
        let registry = loader.loadAll()

        XCTAssertEqual(loader.loadedPlugins.map(\.id), ["builtin.demo"])
        XCTAssertEqual(loader.loadedPlugins.first?.origin, "built-in")
        XCTAssertTrue(loader.loadErrors.isEmpty)
        XCTAssertTrue(registry.presets.isEmpty, "the demo plugin registers nothing, as in the Python")
    }

    func testAUserPluginLoadsAndContributesItsPresets() throws {
        try writePlugin("nightfall", """
        {
          "id": "com.example.nightfall",
          "name": "Nightfall",
          "presets": [
            {"name": "Nightfall Blue", "style_profile": {"background": {"r": 5, "g": 8, "b": 20, "a": 255}}}
          ]
        }
        """)

        let registry = loader().loadAll()
        XCTAssertEqual(registry.presets.map(\.name), ["Nightfall Blue"])
        XCTAssertEqual(registry.presets.first?.styleProfile.background, RGBAColor(5, 8, 20, 255))
    }

    func testALoadedPluginRecordsWhereItCameFrom() throws {
        try writePlugin("nightfall", #"{"id": "com.example.nightfall", "name": "Nightfall"}"#)
        let loader = loader()
        _ = loader.loadAll()

        let loaded = try XCTUnwrap(loader.loadedPlugins.first)
        XCTAssertEqual(loaded.id, "com.example.nightfall")
        XCTAssertEqual(loaded.name, "Nightfall")
        XCTAssertTrue(loaded.origin.hasSuffix("nightfall"), "origin was \(loaded.origin)")
    }

    // MARK: - Fault isolation, which is the whole point

    func testABrokenPluginIsReportedAndTheRestStillLoad() throws {
        try writePlugin("broken", "{ this is not json")
        try writePlugin("good", #"{"id": "com.example.good", "name": "Good"}"#)

        let loader = loader()
        _ = loader.loadAll()

        XCTAssertEqual(loader.loadedPlugins.map(\.id), ["com.example.good"])
        XCTAssertEqual(loader.loadErrors.count, 1)
        XCTAssertTrue(loader.loadErrors[0].contains("broken"), loader.loadErrors[0])
    }

    func testAPluginWithNoManifestIsReported() throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("empty"), withIntermediateDirectories: true
        )
        let loader = loader()
        _ = loader.loadAll()
        XCTAssertTrue(loader.loadedPlugins.isEmpty)
        XCTAssertEqual(loader.loadErrors.count, 1)
        XCTAssertTrue(loader.loadErrors[0].contains("plugin.json"), loader.loadErrors[0])
    }

    func testAPluginWithNoIdIsRefused() throws {
        try writePlugin("anonymous", #"{"name": "No Identity"}"#)
        let loader = loader()
        _ = loader.loadAll()
        XCTAssertTrue(loader.loadedPlugins.isEmpty)
        XCTAssertEqual(loader.loadErrors.count, 1)
    }

    func testATrowingBuiltinIsReportedAndDoesNotStopTheOthers() throws {
        let loader = loader(builtins: [ExplodingPlugin(), DemoPlugin()])
        _ = loader.loadAll()

        XCTAssertEqual(loader.loadedPlugins.map(\.id), ["builtin.demo"])
        XCTAssertEqual(loader.loadErrors.count, 1)
        XCTAssertTrue(loader.loadErrors[0].contains("builtin.exploding"), loader.loadErrors[0])
    }

    // MARK: - Two plugins claiming the same ground

    func testTheSameIdTwiceLoadsOnceAndSaysSo() throws {
        try writePlugin("first", #"{"id": "com.example.same", "name": "First"}"#)
        try writePlugin("second", #"{"id": "com.example.same", "name": "Second"}"#)

        let loader = loader()
        _ = loader.loadAll()

        XCTAssertEqual(loader.loadedPlugins.count, 1)
        XCTAssertEqual(loader.loadErrors.count, 1)
        XCTAssertTrue(loader.loadErrors[0].contains("com.example.same"), loader.loadErrors[0])
    }

    func testAPluginCannotOverwriteABuiltInPreset() throws {
        try writePlugin("cuckoo", """
        {"id": "com.example.cuckoo", "name": "Cuckoo",
         "presets": [{"name": "\(Presets.defaultName)"}]}
        """)

        let registry = loader().loadAll()
        // Refused, not merged: a plugin quietly redefining a built-in style is
        // how a map changes appearance for a reason nobody can find.
        XCTAssertTrue(registry.presets.isEmpty)
        XCTAssertEqual(loader().loadAll().presets.count, 0)
    }

    // MARK: - Plugins loading in a fixed order

    func testPluginsLoadInAStableOrder() throws {
        try writePlugin("zulu", #"{"id": "z", "name": "Zulu"}"#)
        try writePlugin("alpha", #"{"id": "a", "name": "Alpha"}"#)
        try writePlugin("mike", #"{"id": "m", "name": "Mike"}"#)

        let loader = loader()
        _ = loader.loadAll()
        // By folder name, so the same plugins always load in the same order —
        // which is what makes "the same id twice" resolve the same way twice.
        XCTAssertEqual(loader.loadedPlugins.map(\.id), ["a", "m", "z"])
    }
}

// MARK: - Test doubles

private struct DemoPlugin: Plugin {
    let id = "builtin.demo"
    let name = "Demo Builtin"
    func register(into registry: inout PluginRegistry) throws {}
}

private struct ExplodingPlugin: Plugin {
    let id = "builtin.exploding"
    let name = "Exploding"
    struct Boom: Error {}
    func register(into registry: inout PluginRegistry) throws { throw Boom() }
}
