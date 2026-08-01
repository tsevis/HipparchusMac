import CoreGraphics
import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// How relief shading is styled, and how it leaves the sheet it lands on.
///
/// None of the sixteen presets says anything about `terrain_hillshade` —
/// `PresetTables.swift` is generated from a Python registry that names the layer
/// and never produces one — so the style is derived. These check the two things
/// that derivation has to get right, both of which fail quietly rather than
/// loudly: that the untouched end of the ramp really is untouched, and that the
/// shading darkens pale ground and lightens dark ground rather than the reverse.
final class HillshadeStyleTests: XCTestCase {

    private func profile(background: RGBAColor, bands: LayerStyle? = nil) -> StyleProfile {
        StyleProfile(
            layerStyles: bands.map { [TerrainLayer.elevationBands: $0] } ?? [:],
            background: background
        )
    }

    private let paper = RGBAColor(250, 249, 245)
    private let ink = RGBAColor(16, 18, 26)

    // MARK: -

    /// The failure this is here for: setting the lit end to the background
    /// colour instead of to nothing. Every colour still looks reasonable on its
    /// own, and the sheet goes flat and grey because the lit half of the relief
    /// is painting paper over the elevation bands underneath it.
    func testTheUntouchedEndOfTheRampIsTransparentRatherThanTheBackground() {
        for background in [paper, ink] {
            let style = profile(background: background).derivedHillshade
            let high = try? XCTUnwrap(style.fillColorHigh)
            let ends = [style.fillColor.a, (high ?? RGBAColor(0, 0, 0)).a]
            XCTAssertTrue(
                ends.contains(0),
                "one end of the shade ramp must add nothing at all, or it repaints the ground"
            )
            XCTAssertNotEqual(
                style.fillColor.a, style.fillColorHigh?.a,
                "a ramp with the same alpha at both ends is a flat wash, not shading"
            )
        }
    }

    func testPaleGroundTakesShadowAndDarkGroundTakesLight() {
        // Band 0 is the deepest shadow; the last band is the brightest.
        let onPaper = profile(background: paper).derivedHillshade
        XCTAssertGreaterThan(onPaper.fillColor.a, 0, "pale ground should be darkened where it turns away")
        XCTAssertEqual(onPaper.fillColorHigh?.a, 0, "ground facing the sun should be left as it was")
        XCTAssertLessThan(Int(onPaper.fillColor.r), 128, "the shadow end should be a dark tone")

        let onInk = profile(background: ink).derivedHillshade
        XCTAssertEqual(onInk.fillColor.a, 0, "a dark sheet's shadows are already dark; leave them")
        XCTAssertGreaterThan(onInk.fillColorHigh?.a ?? 0, 0, "dark ground should be lit where it faces the sun")
        XCTAssertGreaterThan(Int(onInk.fillColorHigh?.r ?? 0), 128, "the lit end should be a light tone")
    }

    /// The `Night` case, and the reason this asks the elevation bands rather than
    /// the background: that preset pairs near-black paper with near-white bands,
    /// so the ground the shading actually lands on is pale even though the sheet
    /// is dark. Judged by the background alone it puts a white highlight onto
    /// white bands and shades nothing.
    func testTheGroundUnderTheShadeDecidesTheDirectionNotTheBackground() {
        let paleBands = LayerStyle(strokeWidth: 0, fillColor: RGBAColor(232, 237, 226))
        let style = profile(background: ink, bands: paleBands).derivedHillshade
        XCTAssertGreaterThan(
            style.fillColor.a, 0,
            "pale bands over dark paper still need shadow — this is the Night preset"
        )
        XCTAssertEqual(style.fillColorHigh?.a, 0)
    }

    /// A band fill that is not opaque is sitting on the background, so the two
    /// mix rather than one winning outright.
    func testATranslucentBandFillIsBlendedWithTheBackgroundRatherThanTakenWhole() {
        let faintPale = LayerStyle(strokeWidth: 0, fillColor: RGBAColor(255, 255, 255, 20))
        let style = profile(background: ink, bands: faintPale).derivedHillshade
        XCTAssertEqual(
            style.fillColor.a, 0,
            "a fill at 8% alpha barely tints near-black paper; the ground is still dark"
        )
        XCTAssertGreaterThan(style.fillColorHigh?.a ?? 0, 0)
    }

    /// Bands share their edges, so stroking them draws every seam between tones.
    func testTheShadeIsFilledAndNeverStroked() {
        for background in [paper, ink] {
            let style = profile(background: background).derivedHillshade
            XCTAssertEqual(style.strokeWidth, 0.0)
            XCTAssertTrue(style.fillEnabled)
            XCTAssertTrue(style.visible)
            XCTAssertLessThan(style.opacity, 1.0, "at full strength the shade buries the map it supports")
        }
    }

    /// Unfilled bands mean the shade lands on the paper itself, so the paper
    /// governs again.
    func testUnfilledBandsHandTheDecisionBackToTheBackground() {
        var unfilled = LayerStyle()
        unfilled.fillEnabled = false
        unfilled.fillColor = RGBAColor(255, 255, 255)
        let style = profile(background: ink, bands: unfilled).derivedHillshade
        XCTAssertEqual(style.fillColor.a, 0, "the bands are not drawn, so the dark paper decides")
        XCTAssertGreaterThan(style.fillColorHigh?.a ?? 0, 0)
    }

    /// A preset or plugin that states the layer outright is used as written.
    func testAStatedHillshadeStyleIsNotOverridden() {
        let stated = LayerStyle(strokeWidth: 2.5, strokeColor: RGBAColor(1, 2, 3))
        let profile = StyleProfile(layerStyles: [TerrainLayer.hillshade: stated], background: paper)
        XCTAssertEqual(profile.style(for: TerrainLayer.hillshade), stated)
    }

    /// Every shipped preset has to produce a usable shade, since none of them
    /// mentions the layer.
    func testEveryShippedPresetDerivesAWorkableShade() {
        for name in Presets.names {
            let style = Presets.preset(name).styleProfile.style(for: TerrainLayer.hillshade)
            XCTAssertTrue(style.fillEnabled, "\(name): shade must fill")
            XCTAssertEqual(style.strokeWidth, 0.0, "\(name): shade must not stroke its seams")
            let high = style.fillColorHigh
            XCTAssertNotNil(high, "\(name): a shade without a ramp is one flat tone")
            XCTAssertNotEqual(style.fillColor.a, high?.a, "\(name): both ends of the ramp are equal")
        }
    }
}
