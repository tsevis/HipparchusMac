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
    private let cleanAtlas = "Clean Atlas"

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

    // MARK: - Clean Atlas contours

    /// Clean Atlas must name its contours rather than inherit a fallback.
    ///
    /// It tints elevation bands, so a terrain source gives it 800-odd contour
    /// lines over those fills — its most numerous layer by an order of
    /// magnitude. Naming nothing left them to `style(for:)`'s last resort, and
    /// the two apps' last resorts were never the same one: a grey hairline
    /// here, a near-black 1.0-wide line in the Python. The same preset drew a
    /// visibly different sheet in each, and the palettes were not the reason.
    func testCleanAtlasNamesItsContours() {
        let styles = Presets.preset(cleanAtlas).styleProfile.layerStyles
        for layer in ["terrain_contours", "terrain_index_contours"] {
            XCTAssertNotNil(styles[layer], "Clean Atlas leaves \(layer) to the fallback")
        }
    }

    /// Both presets fill the same bands, so both take the same ink over them.
    func testCleanAtlasContoursMatchTerrainStudy() {
        let clean = Presets.preset(cleanAtlas).styleProfile.layerStyles
        let study = Presets.preset("Terrain Study").styleProfile.layerStyles
        XCTAssertEqual(clean["elevation_bands"], study["elevation_bands"])
        for layer in ["terrain_contours", "terrain_index_contours"] {
            XCTAssertEqual(clean[layer], study[layer], "\(layer) diverges from Terrain Study")
        }
    }

    /// The Python fallback's near-black is what greyed the hypsometric tint down.
    func testCleanAtlasContoursAreBrownNotBlack() {
        let contours = Presets.preset(cleanAtlas).styleProfile.style(for: "terrain_contours")
        XCTAssertGreaterThan(contours.strokeColor.r, contours.strokeColor.b)
        XCTAssertGreaterThan(luminance(contours.strokeColor), 60.0)
        XCTAssertLessThan(contours.opacity, 1.0)
    }

    /// Every fifth line reads as the one carrying the number.
    func testCleanAtlasIndexContoursCarryMoreWeight() {
        let styles = Presets.preset(cleanAtlas).styleProfile
        let minor = styles.style(for: "terrain_contours")
        let index = styles.style(for: "terrain_index_contours")
        XCTAssertGreaterThan(index.strokeWidth, minor.strokeWidth)
        XCTAssertGreaterThan(index.opacity, minor.opacity)
        XCTAssertLessThan(luminance(index.strokeColor), luminance(minor.strokeColor))
    }

    /// `LayerStyle` fills by default, and a filled contour is a blot.
    func testCleanAtlasContoursAreDrawnAsLines() {
        let styles = Presets.preset(cleanAtlas).styleProfile.layerStyles
        for layer in ["terrain_contours", "terrain_index_contours"] {
            XCTAssertEqual(styles[layer]?.fillEnabled, false, "\(layer) is filled")
        }
    }

    /// Soft Urban is built from Clean Atlas's table in the Python and tints the
    /// identical bands, so it inherits the same contours. Asserted rather than
    /// left to chance: it is a second preset changed by a one-preset fix.
    func testSoftUrbanInheritsTheSameContours() {
        let clean = Presets.preset(cleanAtlas).styleProfile.layerStyles
        let soft = Presets.preset("Soft Urban").styleProfile.layerStyles
        XCTAssertEqual(soft["elevation_bands"], clean["elevation_bands"])
        for layer in ["terrain_contours", "terrain_index_contours"] {
            XCTAssertEqual(soft[layer], clean[layer], "Soft Urban's \(layer) drifted from Clean Atlas")
        }
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
