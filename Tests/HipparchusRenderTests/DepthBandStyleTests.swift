import XCTest
@testable import HipparchusData
@testable import HipparchusRender

/// Depth bands for a preset that has never heard of them.
///
/// Eleven of the built-in presets fill the land's bands and **not one mentions
/// the sea's**, because `PresetTables.swift` is generated from the Python
/// registry and the Python has no depth bands to name. A hypsometric sheet drawn
/// from a preset alone gave the land graduated mass and left the Elbe as bare
/// hairline contours on white — the exact asymmetry the depth bands were built
/// to end, surviving in the one path nobody had rendered.
final class DepthBandStyleTests: XCTestCase {

    private func preset(
        bands: LayerStyle?,
        water: LayerStyle? = nil,
        bathymetry: LayerStyle? = nil,
        background: RGBAColor = RGBAColor(250, 250, 250)
    ) -> StyleProfile {
        var styles: [String: LayerStyle] = [:]
        if let bands { styles[TerrainLayer.elevationBands] = bands }
        if let water { styles["water"] = water }
        if let bathymetry { styles[TerrainLayer.bathymetry] = bathymetry }
        return StyleProfile(layerStyles: styles, background: background)
    }

    private func filledBands() -> LayerStyle {
        var style = LayerStyle()
        style.strokeWidth = 0
        style.fillEnabled = true
        style.fillColor = RGBAColor(232, 237, 226)
        style.fillColorHigh = RGBAColor(150, 122, 96)
        style.opacity = 0.9
        return style
    }

    private func linework() -> LayerStyle {
        var style = LayerStyle()
        style.strokeWidth = 0.35
        style.fillEnabled = false
        return style
    }

    private func filledWater(_ colour: RGBAColor) -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = true
        style.fillColor = colour
        return style
    }

    // MARK: - Following the land

    /// A preset that gives the land mass gives the sea mass too. This is the
    /// whole point: the Elbe was hairlines on white while the land beside it was
    /// graduated.
    func testASheetThatFillsTheLandFillsTheSea() {
        let sheet = preset(bands: filledBands(), water: filledWater(RGBAColor(150, 180, 200)))
        XCTAssertTrue(sheet.style(for: TerrainLayer.depthBands).fillEnabled)
    }

    /// **And a linework preset keeps its linework.** `Contour Study` fills
    /// nothing on purpose; forcing a filled sea onto it would be this fallback
    /// deciding what the sheet is. Its invisible depth bands are correct, and
    /// were never the bug.
    func testASheetThatFillsNothingIsLeftAlone() {
        let sheet = preset(bands: linework(), water: filledWater(RGBAColor(150, 180, 200)))
        XCTAssertFalse(sheet.style(for: TerrainLayer.depthBands).fillEnabled)
    }

    /// A preset with no elevation bands at all has said nothing about mass, so
    /// nothing is invented for it.
    func testAPresetWithNoBandsAtAllFillsNothing() {
        XCTAssertFalse(preset(bands: nil).style(for: TerrainLayer.depthBands).fillEnabled)
    }

    // MARK: - The shape of the ramp

    /// Bands share their edges. Stroking them draws every seam between tones,
    /// which is the one thing a band fill must not have.
    func testTheBandsAreNotStroked() {
        let sheet = preset(bands: filledBands(), water: filledWater(RGBAColor(150, 180, 200)))
        XCTAssertEqual(sheet.style(for: TerrainLayer.depthBands).strokeWidth, 0)
    }

    /// **Deep is darker.** The one thing about a depth ramp a reader assumes
    /// without being told, and the one that is invisible when inverted — every
    /// colour still looks defensible and the sea floor reads inside out.
    func testTheDeepEndIsDarkerThanTheShallow() throws {
        let sheet = preset(
            bands: filledBands(),
            water: filledWater(RGBAColor(150, 180, 200)),
            bathymetry: {
                var style = LayerStyle()
                style.strokeColor = RGBAColor(40, 60, 80)
                return style
            }()
        )
        let style = sheet.style(for: TerrainLayer.depthBands)
        let shallow = try XCTUnwrap(style.fillColorHigh)
        XCTAssertLessThan(luma(style.fillColor), luma(shallow))
    }

    /// **And on a dark sheet too**, which is where naming the ends rather than
    /// measuring them goes wrong: the ink is pale, the paper is near-black, and
    /// "toward ink" becomes the *lighter* mix. Five palettes shipped inverted
    /// that way before it was caught (`c08424b`); this is the same formula in
    /// the preset path, so it is the same trap.
    func testTheDeepEndIsDarkerOnADarkSheetToo() throws {
        let sheet = preset(
            bands: filledBands(),
            water: filledWater(RGBAColor(28, 44, 62)),
            bathymetry: {
                var style = LayerStyle()
                // Pale ink, because a dark sheet draws its lines light.
                style.strokeColor = RGBAColor(190, 205, 218)
                return style
            }(),
            background: RGBAColor(14, 17, 24)
        )
        let style = sheet.style(for: TerrainLayer.depthBands)
        let shallow = try XCTUnwrap(style.fillColorHigh)
        XCTAssertLessThan(
            luma(style.fillColor), luma(shallow),
            "the deep end came out brighter than the shallow — the ramp is inverted"
        )
    }

    private func luma(_ colour: RGBAColor) -> Double {
        (299.0 * Double(colour.r) + 587.0 * Double(colour.g) + 114.0 * Double(colour.b)) / 1000.0
    }

    /// The hue comes from the preset's own water rather than from a colour
    /// invented here — a sea drawn in somebody else's blue is a sheet with two
    /// palettes in it.
    func testTheColourIsTheSheetsOwnWater() {
        let green = preset(bands: filledBands(), water: filledWater(RGBAColor(90, 170, 130)))
        let blue = preset(bands: filledBands(), water: filledWater(RGBAColor(90, 130, 200)))
        XCTAssertNotEqual(
            green.style(for: TerrainLayer.depthBands).fillColor,
            blue.style(for: TerrainLayer.depthBands).fillColor
        )
    }

    /// An outlined water layer states its colour as a stroke rather than a fill,
    /// and reading the wrong one gives every such preset the same default sea.
    func testAnOutlinedWaterLayerStillGivesItsColour() {
        var outlined = LayerStyle()
        outlined.fillEnabled = false
        outlined.strokeColor = RGBAColor(70, 120, 190)
        let sheet = preset(bands: filledBands(), water: outlined)
        XCTAssertNotEqual(
            sheet.style(for: TerrainLayer.depthBands).fillColor,
            preset(bands: filledBands()).style(for: TerrainLayer.depthBands).fillColor
        )
    }

    // MARK: - Not overruling anybody

    /// A preset or plugin that *does* name the layer is used as written. The
    /// derivation is for silence, not for disagreement.
    func testAStatedStyleWins() {
        var stated = LayerStyle()
        stated.fillEnabled = true
        stated.fillColor = RGBAColor(1, 2, 3)
        var styles: [String: LayerStyle] = [TerrainLayer.elevationBands: filledBands()]
        styles[TerrainLayer.depthBands] = stated
        let sheet = StyleProfile(layerStyles: styles)
        XCTAssertEqual(sheet.style(for: TerrainLayer.depthBands).fillColor, RGBAColor(1, 2, 3))
    }

    /// Every shipped preset resolves to something drawable rather than throwing
    /// or landing on the hairline that started this.
    func testEveryShippedPresetResolvesTheLayer() {
        for name in Presets.names {
            let sheet = Presets.preset(name).styleProfile
            let style = sheet.style(for: TerrainLayer.depthBands)
            let landFilled = sheet.style(for: TerrainLayer.elevationBands).fillEnabled
            XCTAssertEqual(
                style.fillEnabled, landFilled,
                "\(name): the sea should follow the land"
            )
        }
    }
}
