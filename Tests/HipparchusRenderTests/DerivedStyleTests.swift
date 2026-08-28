import XCTest
@testable import HipparchusData
@testable import HipparchusRender

/// The ocean fields and the border, for a preset that has never named either.
///
/// The same gap `derivedDepthBands` and `derivedSeamarkStyle` close, five layers
/// further on. `PresetTables.swift` is generated from the Python registry and
/// the Python's tables predate `sst_bands`, `sst_contours`,
/// `current_streamlines`, `ferry_routes` and `admin_boundaries`, so not one of
/// the sixteen presets says anything about any of them and every one fell
/// through to the generic hairline.
///
/// For the four line layers that is a wrong-coloured stroke. For `sst_bands` it
/// is worse: it is a **fill** layer, and the fallback sets `fillEnabled = false`,
/// so a sea temperature sheet drew hairlines where its ramp belonged and lost
/// the one thing the layer exists to show.
///
/// The mixes are `PaletteSheet`'s own for these five layers, read off what the
/// preset itself already chose rather than off a full palette.
final class DerivedStyleTests: XCTestCase {

    private func profile(
        bands: LayerStyle? = nil,
        water: LayerStyle? = nil,
        bathymetry: LayerStyle? = nil,
        coastline: LayerStyle? = nil,
        buildings: LayerStyle? = nil,
        background: RGBAColor = RGBAColor(250, 250, 250)
    ) -> StyleProfile {
        var styles: [String: LayerStyle] = [:]
        if let bands { styles[TerrainLayer.elevationBands] = bands }
        if let water { styles["water"] = water }
        if let bathymetry { styles[TerrainLayer.bathymetry] = bathymetry }
        if let coastline { styles["coastline"] = coastline }
        if let buildings { styles["buildings"] = buildings }
        return StyleProfile(layerStyles: styles, background: background)
    }

    private func filled(_ colour: RGBAColor) -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = true
        style.fillColor = colour
        return style
    }

    private func unfilled() -> LayerStyle {
        var style = LayerStyle()
        style.fillEnabled = false
        return style
    }

    private let oceanLayers = ["sst_bands", "sst_contours", "current_streamlines", "ferry_routes"]

    // MARK: - The ocean layers

    func testEveryOceanLayerIsStyledRatherThanFallingBack() {
        let sheet = profile(bands: filled(RGBAColor(232, 237, 226)))
        for layer in oceanLayers {
            let style = sheet.style(for: layer)
            XCTAssertNotEqual(style, StyleProfile.unstyledFallback, "\(layer) fell back")
        }
    }

    func testTheLineLayersAreNeverFilled() {
        let sheet = profile(bands: filled(RGBAColor(232, 237, 226)))
        for layer in ["sst_contours", "current_streamlines", "ferry_routes"] {
            XCTAssertFalse(sheet.style(for: layer).fillEnabled, "\(layer) is filled")
        }
    }

    func testTheColoursAreTheSheetsOwnWater() {
        let green = profile(water: filled(RGBAColor(40, 120, 60)))
        let blue = profile(water: filled(RGBAColor(40, 60, 120)))
        for layer in ["sst_contours", "current_streamlines", "ferry_routes"] {
            XCTAssertNotEqual(
                green.style(for: layer).strokeColor,
                blue.style(for: layer).strokeColor,
                "\(layer) ignores the sheet's water"
            )
        }
    }

    /// When the currents are on they are the subject; a ferry route is a service.
    func testStreamlinesReadHeavierThanAFerryRoute() {
        let sheet = profile()
        let currents = sheet.style(for: "current_streamlines")
        let ferry = sheet.style(for: "ferry_routes")
        XCTAssertGreaterThan(currents.strokeWidth, ferry.strokeWidth)
        XCTAssertGreaterThan(currents.opacity, ferry.opacity)
    }

    func testStreamlinesAreRoundCapped() {
        XCTAssertEqual(profile().style(for: "current_streamlines").lineCap, .round)
    }

    /// Pinned, because these four numbers drifted apart once already.
    ///
    /// The Python's `derived_ocean_style` states the same values and its
    /// `OceanDerivationTests` pins them from the other side. They are literals
    /// rather than derived from anything, so a change here has to be a change
    /// somebody meant to make in both places.
    ///
    /// `current_streamlines` is the one that had to be chosen rather than
    /// copied: the Python's own `palette_sheet` says 1.1 and mix 0.62, roughly
    /// 47% heavier, and surface currents were written on this side first.
    func testTheDerivedWeightsMatchThePythonApplication() {
        let water = RGBAColor(150, 180, 200)
        let ink = RGBAColor(40, 60, 80)
        let sheet = profile()
        XCTAssertEqual(sheet.style(for: "sst_contours").strokeColor, water.mixed(towards: ink, amount: 0.5))

        let expected: [(String, Double, Double, Double)] = [
            ("sst_contours", 0.4, 0.5, 0.65),
            ("current_streamlines", 0.75, 0.7, 0.85),
            ("ferry_routes", 0.6, 0.2, 0.7),
        ]
        for (layer, width, amount, opacity) in expected {
            let style = sheet.style(for: layer)
            XCTAssertEqual(style.strokeWidth, width, accuracy: 1e-9, "\(layer): stroke width")
            XCTAssertEqual(style.opacity, opacity, accuracy: 1e-9, "\(layer): opacity")
            XCTAssertEqual(style.strokeColor, water.mixed(towards: ink, amount: amount), "\(layer): colour")
        }
    }

    // MARK: - Sea temperature bands

    /// Follows the land rather than overruling it, the rule `derivedDepthBands`
    /// follows for the sea floor.
    func testASheetThatFillsTheLandFillsTheTemperature() {
        let sheet = profile(bands: filled(RGBAColor(232, 237, 226)), water: filled(RGBAColor(150, 180, 200)))
        XCTAssertTrue(sheet.style(for: "sst_bands").fillEnabled)
    }

    func testALineworkSheetKeepsItsTemperatureUnfilled() {
        XCTAssertFalse(profile(bands: unfilled()).style(for: "sst_bands").fillEnabled)
    }

    func testASheetNamingNoBandsAtAllStaysUnfilled() {
        XCTAssertFalse(profile().style(for: "sst_bands").fillEnabled)
    }

    /// The bug this closes: the fallback threw the ramp away entirely.
    func testTheBandsCarryARampRatherThanOneFlatTone() {
        let sheet = profile(
            bands: filled(RGBAColor(232, 237, 226)),
            water: filled(RGBAColor(150, 180, 200)),
            buildings: filled(RGBAColor(204, 199, 190))
        )
        let style = sheet.style(for: "sst_bands")
        XCTAssertNotNil(style.fillColorHigh)
        XCTAssertNotEqual(style.fillColor, style.fillColorHigh)
    }

    /// A band edge and an isotherm are the same line; drawing both doubles it.
    func testTheBandsAreUnstroked() {
        let sheet = profile(bands: filled(RGBAColor(232, 237, 226)))
        XCTAssertEqual(sheet.style(for: "sst_bands").strokeWidth, 0.0)
    }

    /// They sit over the sea floor they describe, which has to stay readable.
    func testTheBandsStayTranslucent() {
        let sheet = profile(bands: filled(RGBAColor(232, 237, 226)))
        XCTAssertLessThan(sheet.style(for: "sst_bands").opacity, 0.6)
    }

    // MARK: - Admin boundaries

    /// A border partitions land; filling it paints one country out.
    func testABorderIsALineNotAFilledRegion() {
        XCTAssertFalse(profile().style(for: FileLayer.adminBoundaries).fillEnabled)
    }

    func testTheBorderColourIsTheSheetsOwnLand() {
        let pale = profile(buildings: filled(RGBAColor(230, 225, 215)))
        let dark = profile(buildings: filled(RGBAColor(60, 55, 50)))
        XCTAssertNotEqual(
            pale.style(for: FileLayer.adminBoundaries).strokeColor,
            dark.style(for: FileLayer.adminBoundaries).strokeColor
        )
    }

    /// A border follows a network it must not outshout.
    func testTheBorderIsDrawnLightly() {
        let style = profile().style(for: FileLayer.adminBoundaries)
        XCTAssertLessThan(style.opacity, 1.0)
        XCTAssertLessThanOrEqual(style.strokeWidth, 1.0)
    }

    // MARK: - Across the registry

    /// Layers still reaching the fallback, with the reason for each.
    ///
    /// **There are none left.** There were forty-seven here and sixty-three in
    /// the Python, in three groups, and each group had a different answer:
    ///
    /// - the contour pair on nine presets: closed by `derivedContourStyle`,
    ///   which reads each sheet's own relief ramp rather than imposing one
    ///   colour that could only ever suit some of them.
    /// - fifteen layers apiece on `OSM Standard` and `Editorial Print`: those
    ///   two are transcribed from tables the Python wrote from scratch, which
    ///   never gained what its shared base grew. Closed there by putting the
    ///   base underneath, and carried here by regenerating.
    /// - `terrain_hillshade` on all sixteen: a Python-only gap. This app has
    ///   always had `derivedHillshade`; the Python now has the port of it.
    ///
    /// Kept as an empty set rather than deleted, because the assertion that it
    /// is empty is the useful part, and the next gap has somewhere to go.
    private static func knownGaps() -> Set<String> {
        []
    }

    private func fallenBack() -> Set<String> {
        let known = Set(LayerInventory.labels.keys).union(LayerInventory.groups.keys)
        var found: Set<String> = []
        for name in Presets.names {
            let sheet = Presets.preset(name).styleProfile
            for layer in known where sheet.style(for: layer) == StyleProfile.unstyledFallback {
                found.insert("\(name)/\(layer)")
            }
        }
        return found
    }

    /// The rule, rather than the five instances found by rendering Cyprus.
    func testNothingNewFallsBackAcrossTheWholeRegistry() {
        let unexpected = fallenBack().subtracting(Self.knownGaps()).sorted()
        XCTAssertEqual(unexpected, [], "newly unstyled: \(unexpected)")
    }

    /// A gap that has been closed must be struck off the list, not left on it.
    func testTheKnownGapsAreStillReal() {
        let stale = Self.knownGaps().subtracting(fallenBack()).sorted()
        XCTAssertEqual(stale, [], "fixed but still listed as a gap: \(stale)")
    }

    func testTheLayersDerivedHereNeverFallBackUnderAnyPreset() {
        for name in Presets.names {
            let sheet = Presets.preset(name).styleProfile
            for layer in oceanLayers + [FileLayer.adminBoundaries, TerrainLayer.depthBands] {
                XCTAssertNotEqual(
                    sheet.style(for: layer), StyleProfile.unstyledFallback,
                    "\(name)/\(layer) fell back"
                )
            }
        }
    }
}
