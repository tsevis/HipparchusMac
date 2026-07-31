import XCTest
@testable import HipparchusRender

/// The preset registry, held to the invariants a preset promises.
///
/// Ported from `tests/test_presets.py`. `PresetTables.swift` is generated from
/// the Python by `Scripts/generate-presets.py`, so it cannot drift by hand — but
/// nothing asserted that the 16 presets and 573 layer styles it carries are
/// *usable*: that a dark preset's roads read against its ground, that a light one
/// stays light, that the name a launch flag asks for resolves.
final class PresetsTests: XCTestCase {

    /// Rec. 709 on the 0–255 scale, the same measure the furniture uses to decide
    /// which way to invert.
    private func luminance(_ colour: RGBAColor) -> Double {
        0.2126 * Double(colour.r) + 0.7152 * Double(colour.g) + 0.0722 * Double(colour.b)
    }

    private let night = "Night"

    // MARK: - Every preset

    func testEveryPresetIsRegisteredUnderItsOwnName() {
        XCTAssertEqual(Presets.names.count, 16)
        for name in Presets.names {
            XCTAssertEqual(Presets.preset(name).name, name)
        }
    }

    /// A ground the exporter can paint and the furniture can read.
    func testEveryPresetCarriesAnOpaqueBackground() {
        for name in Presets.names {
            XCTAssertEqual(
                Presets.preset(name).styleProfile.background.a, 255,
                "\(name) has a transparent ground"
            )
        }
    }

    /// Every preset but Night is a daylight sheet, and a daylight sheet that
    /// darkened would take its label halos and furniture the wrong way with it.
    func testDaylightPresetsKeepALightGround() {
        for name in Presets.names where name != night {
            XCTAssertGreaterThan(
                luminance(Presets.preset(name).styleProfile.background), 200,
                "\(name) is no longer a light sheet"
            )
        }
    }

    func testAnUnknownPresetFallsBackToTheDefault() {
        XCTAssertEqual(Presets.preset("No Such Preset").name, Presets.defaultName)
    }

    // MARK: - Night, the one preset that inverts

    func testNightGroundIsDarkAndOpaque() {
        let background = Presets.preset(night).styleProfile.background
        XCTAssertLessThan(luminance(background), 40)
        XCTAssertEqual(background.a, 255)
    }

    /// A dark preset is only legible if the road hierarchy reads brighter than
    /// the ground it is drawn on.
    func testNightRoadsGlowAgainstTheGround() {
        let preset = Presets.preset(night)
        let ground = luminance(preset.styleProfile.background)
        for layer in ["roads_motorway", "roads_primary", "roads_secondary", "roads_residential"] {
            XCTAssertGreaterThan(
                luminance(preset.styleProfile.style(for: layer).strokeColor), ground + 60,
                "\(layer) does not read against the night ground"
            )
        }
    }

    /// Casings separate adjacent roads, so they must be darker than the strokes
    /// they sit under — and wider, or they would not show at all.
    func testNightRoadCasingsStayDarkerAndWiderThanTheirStrokes() {
        let preset = Presets.preset(night)
        for layer in ["roads_motorway", "roads_primary", "roads_residential"] {
            let style = preset.styleProfile.style(for: layer)
            XCTAssertGreaterThan(style.casingWidth, style.strokeWidth, "\(layer) casing is not wider")
            XCTAssertLessThan(
                luminance(style.casingColor), luminance(style.strokeColor),
                "\(layer) casing is not darker than its stroke"
            )
        }
    }

    func testNightBuildingsAndWaterSeparateFromTheGround() {
        let preset = Presets.preset(night)
        let ground = luminance(preset.styleProfile.background)
        let buildings = preset.styleProfile.style(for: "buildings")
        let water = preset.styleProfile.style(for: "water")

        XCTAssertTrue(buildings.fillEnabled)
        XCTAssertGreaterThan(luminance(buildings.fillColor), ground + 8)
        XCTAssertTrue(water.fillEnabled)
        XCTAssertNotEqual(water.fillColor, buildings.fillColor)
    }

    /// The shared light halo would print as a white box around every label.
    func testNightLabelsUseADarkHalo() {
        let places = Presets.preset(night).styleProfile.style(for: "places")
        XCTAssertLessThan(luminance(places.labelHaloColor), 60)
        XCTAssertGreaterThan(luminance(places.strokeColor), 150)
    }

    /// A preset that styles fewer layers than the default is a preset with holes
    /// in it: the layers it forgot fall back to the hairline.
    func testNightCoversEveryLayerTheDefaultPresetDoes() {
        let night = Set(Presets.preset(self.night).styleProfile.layerStyles.keys)
        let standard = Set(Presets.preset(Presets.defaultName).styleProfile.layerStyles.keys)
        XCTAssertEqual(standard.subtracting(night), [], "Night is missing layers the default styles")
    }

    // MARK: - Resolving a name

    /// Backs `--preset` on the command line, so a bad value must never strand
    /// the app on no preset at all.
    func testAPresetNameResolvesRegardlessOfCaseAndPadding() {
        for requested in ["night", "  NIGHT  ", "nIgHt"] {
            XCTAssertEqual(Presets.resolveName(requested), night, "‘\(requested)’ did not resolve")
        }
    }

    func testAnUnknownOrEmptyNameFallsBack() {
        XCTAssertEqual(Presets.resolveName("Midnight"), Presets.defaultName)
        XCTAssertEqual(Presets.resolveName(""), Presets.defaultName)
        XCTAssertEqual(Presets.resolveName("   "), Presets.defaultName)
    }

    func testEveryBuiltInResolvesToItself() {
        for name in Presets.names {
            XCTAssertEqual(Presets.resolveName(name), name)
        }
    }

    /// The resolver takes the list it is given, so a list that grows — saved
    /// presets, one day — resolves against that rather than only the built-ins.
    func testResolvingHonoursTheListItIsGiven() {
        let available = Presets.names + ["My Night"]
        XCTAssertEqual(Presets.resolveName("My Night", available: available), "My Night")
        XCTAssertEqual(Presets.resolveName("My Night"), Presets.defaultName)
    }
}
