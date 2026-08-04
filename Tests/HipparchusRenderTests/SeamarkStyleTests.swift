import XCTest
@testable import HipparchusData
@testable import HipparchusRender

/// Sea marks for a preset that has never heard of them.
///
/// The same gap `DepthBandStyleTests` covers for the sea's mass: not one of the
/// sixteen built-in presets names `seamark_areas` through `seamark_lights`,
/// because `PresetTables.swift` is generated from the Python registry and the
/// Python has no sea marks either. Without a derivation every chart symbol on a
/// coastal sheet fell through to the generic hairline — a grey stroke round a
/// shape that needs to read as a can, a cone or a light's flare to mean
/// anything.
final class SeamarkStyleTests: XCTestCase {

    private func preset(
        buildings: LayerStyle? = nil,
        water: LayerStyle? = nil,
        bathymetry: LayerStyle? = nil,
        coastline: LayerStyle? = nil,
        background: RGBAColor = RGBAColor(250, 250, 250)
    ) -> StyleProfile {
        var styles: [String: LayerStyle] = [:]
        if let buildings { styles["buildings"] = buildings }
        if let water { styles["water"] = water }
        if let bathymetry { styles[TerrainLayer.bathymetry] = bathymetry }
        if let coastline { styles["coastline"] = coastline }
        return StyleProfile(layerStyles: styles, background: background)
    }

    private func filledBuildings() -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = true
        style.fillColor = RGBAColor(217, 208, 201)
        return style
    }

    private func linework() -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeColor = RGBAColor(150, 146, 138)
        return style
    }

    private func filledWater(_ colour: RGBAColor) -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = true
        style.fillColor = colour
        return style
    }

    // MARK: - Following the land

    /// A preset that gives its buildings mass gives its restricted areas and
    /// harbours mass too — the same rule the depth bands follow for the sea.
    func testAreasFollowAFilledPreset() {
        let sheet = preset(buildings: filledBuildings(), water: filledWater(RGBAColor(150, 180, 200)))
        XCTAssertTrue(sheet.style(for: Seamarks.areas).fillEnabled)
        XCTAssertTrue(sheet.style(for: Seamarks.harbours).fillEnabled)
    }

    /// **And a linework preset keeps its linework.** `Contour Study` leaves
    /// `buildings` unfilled on purpose; a solid area wash on top of that would
    /// be this derivation deciding what the sheet is.
    func testAreasStayUnfilledOnALineworkPreset() {
        let sheet = preset(buildings: linework(), water: filledWater(RGBAColor(150, 180, 200)))
        XCTAssertFalse(sheet.style(for: Seamarks.areas).fillEnabled)
        XCTAssertFalse(sheet.style(for: Seamarks.harbours).fillEnabled)
    }

    /// A preset with no buildings style at all has said nothing about mass, so
    /// the default reads as filled — the same default `derivedDepthBands` takes
    /// when the preset table it consults is silent.
    func testAPresetWithNoBuildingsStyleFillsByDefault() {
        XCTAssertTrue(preset().style(for: Seamarks.areas).fillEnabled)
    }

    /// The four point marks are strokes and halos regardless of whether the
    /// preset fills its polygons — a coastline is stroked whether or not the sea
    /// beside it is filled, and a chart symbol has to be there to be read at all.
    func testPointMarksAreNeverFilledEvenOnAFilledPreset() {
        let sheet = preset(buildings: filledBuildings())
        XCTAssertFalse(sheet.style(for: Seamarks.beacons).fillEnabled)
        XCTAssertFalse(sheet.style(for: Seamarks.buoys).fillEnabled)
        XCTAssertFalse(sheet.style(for: Seamarks.hazards).fillEnabled)
    }

    /// The light's flare is the one point mark that is filled everywhere — its
    /// weight comes from its area rather than its edge, filled preset or not.
    func testTheLightIsFilledEvenOnALineworkPreset() {
        let sheet = preset(buildings: linework())
        XCTAssertTrue(sheet.style(for: Seamarks.lights).fillEnabled)
    }

    // MARK: - The colour comes from the sheet

    /// The hue comes from the preset's own water and ink rather than an
    /// invented default — a mark drawn in somebody else's blue is a sheet with
    /// two palettes in it.
    func testTheColourIsTheSheetsOwnWater() {
        let green = preset(water: filledWater(RGBAColor(90, 170, 130)))
        let blue = preset(water: filledWater(RGBAColor(90, 130, 200)))
        XCTAssertNotEqual(
            green.style(for: Seamarks.buoys).strokeColor,
            blue.style(for: Seamarks.buoys).strokeColor
        )
    }

    /// A hazard's ink comes from the preset's darkest line on the sea — the
    /// sub-sea contours if it has them, the coastline if not — the same source
    /// `derivedDepthBands` reads for its own deep end.
    func testTheInkPrefersBathymetryOverCoastline() {
        let withBoth = preset(
            bathymetry: { var s = LayerStyle(); s.strokeColor = RGBAColor(10, 20, 30); return s }(),
            coastline: { var s = LayerStyle(); s.strokeColor = RGBAColor(200, 200, 200); return s }()
        )
        XCTAssertEqual(withBoth.style(for: Seamarks.hazards).strokeColor, RGBAColor(10, 20, 30))
    }

    // MARK: - Not overruling anybody

    /// A preset or plugin that *does* name a sea mark layer is used as written.
    /// The derivation is for silence, not for disagreement.
    func testAStatedStyleWins() {
        var stated = LayerStyle()
        stated.fillEnabled = true
        stated.fillColor = RGBAColor(1, 2, 3)
        let sheet = StyleProfile(layerStyles: [Seamarks.lights: stated])
        XCTAssertEqual(sheet.style(for: Seamarks.lights).fillColor, RGBAColor(1, 2, 3))
    }

    /// Every shipped preset resolves all six layers to something drawable
    /// rather than falling through to the generic hairline that started this.
    func testEveryShippedPresetResolvesEveryLayer() {
        let hairline = RGBAColor(120, 120, 120, 200)
        for name in Presets.names {
            let sheet = Presets.preset(name).styleProfile
            for layer in Seamarks.allLayers {
                let style = sheet.style(for: layer)
                XCTAssertNotEqual(
                    style.strokeColor, hairline,
                    "\(name)/\(layer): still drawing the unstyled fallback"
                )
            }
        }
    }
}
