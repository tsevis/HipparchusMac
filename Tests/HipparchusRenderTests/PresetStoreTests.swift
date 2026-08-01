import XCTest
@testable import HipparchusRender

/// Presets the user made, kept between launches.
///
/// The sixteen built-in presets are code and cannot change. A style tuned by
/// hand is worth keeping, and worth carrying to the Python app and back, which
/// is why the file this writes is the Python's own format key for key rather
/// than whatever Swift's synthesised `Codable` would have produced.
final class PresetStoreTests: XCTestCase {

    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preset-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PresetStore(url: directory.appendingPathComponent("presets.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A preset with something distinctive in every part, so a field lost in
    /// the round trip shows up rather than matching the default by luck.
    private func distinctive(named name: String) -> ArtisticPreset {
        var geometry = GeometryPipelineProfile()
        geometry.smoothingIterations = 7
        geometry.deriveHexGrid = true
        geometry.hexRadius = 45.5
        geometry.maxOnScreenFeaturesPerLayer = 1234
        geometry.layerSmoothingIterations = ["roads": 3, "water": 5]

        var roads = LayerStyle()
        roads.strokeWidth = 2.75
        roads.strokeColor = RGBAColor(11, 22, 33, 244)
        roads.fillColor = RGBAColor(44, 55, 66, 199)
        roads.fillEnabled = false
        roads.opacity = 0.65
        roads.visible = false
        roads.casingWidth = 1.5
        roads.casingColor = RGBAColor(7, 8, 9, 255)
        roads.lineCap = .round
        roads.labelHaloColor = RGBAColor(1, 2, 3, 4)
        roads.labelHaloWidth = 3.25
        roads.illumination = 0.8
        roads.illuminationAzimuth = 120
        roads.illuminationBands = 9
        roads.illuminationLitScale = 0.33
        roads.illuminationShadowScale = 2.4
        roads.fillColorHigh = RGBAColor(200, 100, 50, 128)

        return ArtisticPreset(
            name: name,
            geometryProfile: geometry,
            styleProfile: StyleProfile(layerStyles: ["roads": roads], background: RGBAColor(9, 8, 7, 255))
        )
    }

    // MARK: - Round trip

    func testNothingSavedReadsAsNoPresets() throws {
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testASavedPresetComesBack() throws {
        let preset = distinctive(named: "My Style")
        try store.save([preset])

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "My Style")
    }

    func testEveryFieldSurvivesTheRoundTrip() throws {
        let original = distinctive(named: "My Style")
        try store.save([original])
        let restored = try XCTUnwrap(try store.load().first)

        XCTAssertEqual(restored.geometryProfile, original.geometryProfile)
        XCTAssertEqual(restored.styleProfile.background, original.styleProfile.background)
        let roads = try XCTUnwrap(restored.styleProfile.layerStyles["roads"])
        XCTAssertEqual(roads, original.styleProfile.layerStyles["roads"])
    }

    func testPresetsAreSortedByNameOnDisk() throws {
        try store.save([distinctive(named: "Zulu"), distinctive(named: "Alpha")])
        // Sorted so the file diffs readably and two saves of the same set
        // produce the same bytes.
        XCTAssertEqual(try store.load().map(\.name), ["Alpha", "Zulu"])
    }

    func testSavingReplacesRatherThanAppends() throws {
        try store.save([distinctive(named: "One")])
        try store.save([distinctive(named: "Two")])
        XCTAssertEqual(try store.load().map(\.name), ["Two"])
    }

    // MARK: - The file itself

    func testTheFileUsesThePythonsOwnKeys() throws {
        try store.save([distinctive(named: "My Style")])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        // Interoperability is the point: a preset saved here has to load in
        // the Python app, which reads these exact names.
        for key in [
            "schema_version", "presets", "geometry_profile", "style_profile",
            "layer_styles", "background", "stroke_width", "stroke_color",
            "fill_color_high", "illumination_azimuth", "max_on_screen_features_per_layer",
            "layer_smoothing_iterations",
        ] {
            XCTAssertTrue(text.contains("\"\(key)\""), "missing \(key)")
        }
        XCTAssertTrue(text.contains("\"r\""), "colours are {r,g,b,a} objects")
    }

    func testTheDirectoryIsCreatedIfMissing() throws {
        let nested = directory
            .appendingPathComponent("a").appendingPathComponent("b")
            .appendingPathComponent("presets.json")
        let deep = PresetStore(url: nested)
        try deep.save([distinctive(named: "Deep")])
        XCTAssertEqual(try deep.load().map(\.name), ["Deep"])
    }

    // MARK: - Files that are not what they should be

    func testAPresetWithNoNameIsSkippedRatherThanLoaded() throws {
        try #"{"schema_version":1,"presets":[{"name":"   "},{"name":"Real"}]}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.load().map(\.name), ["Real"])
    }

    func testRubbishInTheFileIsAnErrorRatherThanACrash() throws {
        try "this is not json".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }

    func testAPresetSavedBeforeTheseFieldsExistedStillLoads() throws {
        // Forward compatibility the Python spells out: a preset written before
        // backgrounds, hypsometric tints or illumination existed must load with
        // sensible defaults rather than fail.
        try #"{"schema_version":1,"presets":[{"name":"Old","style_profile":{"layer_styles":{"roads":{"stroke_width":3}}}}]}"#
            .write(to: store.url, atomically: true, encoding: .utf8)

        let preset = try XCTUnwrap(try store.load().first)
        XCTAssertEqual(preset.name, "Old")
        XCTAssertEqual(preset.styleProfile.layerStyles["roads"]?.strokeWidth, 3)
        // The light ground the Python falls back to.
        XCTAssertEqual(preset.styleProfile.background, RGBAColor(250, 250, 250, 255))
        XCTAssertEqual(preset.styleProfile.layerStyles["roads"]?.illumination, 0)
        XCTAssertNil(preset.styleProfile.layerStyles["roads"]?.fillColorHigh)
    }
}
