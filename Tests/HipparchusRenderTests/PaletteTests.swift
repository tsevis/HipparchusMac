import Foundation
import XCTest
@testable import HipparchusRender

/// Colour as an axis, and the derivation kept honest.
///
/// There are now two copies of one palette engine: `sheet()` in
/// `Scripts/build-style-packs.py`, which generates the shipped packs at build
/// time, and `Palette.styleProfile()`, which does it at render time. Two copies
/// of a derivation drift, and the drift would be invisible — a green four units
/// off looks like a green. The fixture is the script's own output, so the pair
/// either agree exactly or a test fails.
///
/// Regenerate it the way the packs are regenerated, from
/// `Scripts/build-style-packs.py`.
final class PaletteTests: XCTestCase {

    private struct StoredColor: Decodable { let r, g, b, a: Int }

    private struct StoredStyle: Decodable {
        let strokeWidth: Double
        let strokeColor: StoredColor
        let opacity: Double
        let fillEnabled: Bool
        let fillColor: StoredColor?
        let casingWidth: Double
        let casingColor: StoredColor?

        enum CodingKeys: String, CodingKey {
            case strokeWidth = "stroke_width"
            case strokeColor = "stroke_color"
            case opacity
            case fillEnabled = "fill_enabled"
            case fillColor = "fill_color"
            case casingWidth = "casing_width"
            case casingColor = "casing_color"
        }
    }

    private func fixture() throws -> [String: [String: StoredStyle]] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "palette-parity", withExtension: "json"),
            "palette-parity.json is missing from the test bundle"
        )
        return try JSONDecoder().decode([String: [String: StoredStyle]].self, from: Data(contentsOf: url))
    }

    // MARK: -

    /// Every layer, every channel, against the script that ships the packs.
    func testTheSwiftEngineDerivesWhatTheBuildScriptDerives() throws {
        for (name, expected) in try fixture() {
            let palette = try XCTUnwrap(Palette.named(name), "no palette named \(name)")
            let derived = palette.styleProfile().layerStyles

            for (layer, reference) in expected {
                // The hillshade is stated by both, and has its own shape; it is
                // covered by `testTheShadeIsTheInkOfItsOwnSheet` below.
                if layer == "terrain_hillshade" { continue }
                let style = try XCTUnwrap(derived[layer], "\(name): no \(layer)")

                XCTAssertEqual(style.strokeWidth, reference.strokeWidth, accuracy: 1e-9,
                               "\(name)/\(layer): stroke width")
                XCTAssertEqual(style.opacity, reference.opacity, accuracy: 1e-9,
                               "\(name)/\(layer): opacity")
                XCTAssertEqual(style.casingWidth, reference.casingWidth, accuracy: 1e-9,
                               "\(name)/\(layer): casing width")
                XCTAssertEqual(style.fillEnabled, reference.fillEnabled,
                               "\(name)/\(layer): fill enabled")
                assertColor(style.strokeColor, reference.strokeColor, "\(name)/\(layer): stroke colour")
                if let fill = reference.fillColor, reference.fillEnabled {
                    assertColor(style.fillColor, fill, "\(name)/\(layer): fill colour")
                }
                if let casing = reference.casingColor {
                    assertColor(style.casingColor, casing, "\(name)/\(layer): casing colour")
                }
            }
        }
    }

    func testEveryPaletteCoversEveryLayerTheBuildScriptCovers() throws {
        let reference = try XCTUnwrap(try fixture()["Tsevis Daylight"])
        for palette in Palette.all {
            let derived = palette.styleProfile().layerStyles
            for layer in reference.keys {
                XCTAssertNotNil(derived[layer], "\(palette.name) says nothing about \(layer)")
            }
        }
    }

    /// A map that styles `roads` and not `roads_motorway` loses its motorways
    /// without a word.
    func testEveryPaletteStylesEveryRoadClass() {
        for palette in Palette.all {
            let styles = palette.styleProfile().layerStyles
            for road in Palette.roadWidths {
                let style = styles[road.layer]
                XCTAssertNotNil(style, "\(palette.name) has no \(road.layer)")
                XCTAssertGreaterThan(style?.strokeWidth ?? 0, 0, "\(palette.name)/\(road.layer) is invisible")
            }
        }
    }

    /// The relative road hierarchy is the design: a motorway is wider than a
    /// service road in every palette, whatever its road scale.
    func testTheRoadHierarchyHoldsInEveryPalette() {
        for palette in Palette.all {
            let styles = palette.styleProfile().layerStyles
            let motorway = styles["roads_motorway"]?.strokeWidth ?? 0
            let residential = styles["roads_residential"]?.strokeWidth ?? 0
            let service = styles["roads_service"]?.strokeWidth ?? 0
            XCTAssertGreaterThan(motorway, residential, palette.name)
            XCTAssertGreaterThan(residential, service, palette.name)
        }
    }

    /// A pale sheet shades with shadow and a dark sheet with light, and the
    /// untouched end of the ramp is transparent either way — the shade is drawn
    /// over the ground, not instead of it.
    func testTheShadeIsTheInkOfItsOwnSheet() {
        for palette in Palette.all {
            let shade = try? XCTUnwrap(palette.styleProfile().layerStyles["terrain_hillshade"])
            guard let shade else { continue }
            let high = shade.fillColorHigh

            XCTAssertEqual(shade.strokeWidth, 0, "\(palette.name): a stroked shade draws every seam")
            XCTAssertTrue(shade.fillEnabled, palette.name)

            let luma = (299.0 * Double(palette.ground.r) + 587.0 * Double(palette.ground.g)
                + 114.0 * Double(palette.ground.b)) / 255_000.0
            if luma < 0.5 {
                XCTAssertEqual(shade.fillColor.a, 0, "\(palette.name): a dark sheet must not add shadow")
                XCTAssertGreaterThan(high?.a ?? 0, 0, "\(palette.name): a dark sheet shades with light")
            } else {
                XCTAssertGreaterThan(shade.fillColor.a, 0, "\(palette.name): a pale sheet shades with shadow")
                XCTAssertEqual(high?.a, 0, "\(palette.name): the lit end must add nothing")
            }
            // Tone, in the sheet's own ink, not a neutral grey laid over it.
            XCTAssertEqual(shade.fillColor.r, palette.ink.r, palette.name)
            XCTAssertEqual(shade.fillColor.g, palette.ink.g, palette.name)
            XCTAssertEqual(shade.fillColor.b, palette.ink.b, palette.name)
        }
    }

    func testThePaperIsThePalettesGround() {
        for palette in Palette.all {
            XCTAssertEqual(palette.styleProfile().background, palette.ground, palette.name)
        }
    }

    // MARK: - Recolouring a preset

    /// A palette moves colour and nothing else. The geometry profile is what a
    /// preset still is once colour has been lifted out of it.
    func testRecolouringKeepsThePresetsGeometryAndName() throws {
        let preset = Presets.preset("Contour Study")
        let palette = try XCTUnwrap(Palette.named("Sepia"))
        let recoloured = preset.recoloured(with: palette)

        XCTAssertEqual(recoloured.name, preset.name)
        XCTAssertEqual(
            recoloured.geometryProfile.simplifyTolerancePreview,
            preset.geometryProfile.simplifyTolerancePreview
        )
        XCTAssertEqual(
            recoloured.geometryProfile.smoothingIterations,
            preset.geometryProfile.smoothingIterations
        )
        XCTAssertEqual(recoloured.styleProfile.background, palette.ground)
        XCTAssertNotEqual(recoloured.styleProfile.background, preset.styleProfile.background)
    }

    func testNoPaletteLeavesEveryPresetExactlyAsItWas() {
        for name in Presets.names {
            let preset = Presets.preset(name)
            let untouched = preset.recoloured(with: nil)
            XCTAssertEqual(untouched.styleProfile.background, preset.styleProfile.background, name)
            XCTAssertEqual(untouched.styleProfile.layerStyles.count,
                           preset.styleProfile.layerStyles.count, name)
        }
    }

    /// Any palette over any preset, with no combination throwing or producing an
    /// empty sheet — the point of having colour as an axis at all.
    func testEveryPaletteAppliesToEveryPreset() {
        for name in Presets.names {
            for palette in Palette.all {
                let recoloured = Presets.preset(name).recoloured(with: palette)
                XCTAssertGreaterThan(
                    recoloured.styleProfile.layerStyles.count, 30,
                    "\(name) in \(palette.name) came out nearly empty"
                )
            }
        }
    }

    func testTheOfferedNamesLeadWithLeavingThePresetAlone() {
        XCTAssertEqual(Palette.names.first, Palette.presetOwnName)
        XCTAssertNil(Palette.named(Palette.presetOwnName), "the no-op must not be a palette")
        XCTAssertEqual(Set(Palette.names).count, Palette.names.count, "duplicate palette name")
    }

    // MARK: -

    private func assertColor(
        _ actual: RGBAColor, _ expected: StoredColor, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Int(actual.r), expected.r, "\(message) — red", file: file, line: line)
        XCTAssertEqual(Int(actual.g), expected.g, "\(message) — green", file: file, line: line)
        XCTAssertEqual(Int(actual.b), expected.b, "\(message) — blue", file: file, line: line)
        XCTAssertEqual(Int(actual.a), expected.a, "\(message) — alpha", file: file, line: line)
    }
}
