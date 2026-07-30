import XCTest
import HipparchusGeometry
@testable import HipparchusRender

/// Ported from `tests/test_style_previews.py`.
///
/// The property that matters: a swatch is derived from the preset, so a preset
/// cannot advertise a look it no longer has.
final class StylePreviewsTests: XCTestCase {

    func testEveryFeaturedPresetExists() {
        let available = Set(Presets.names)
        for name in StylePreviews.featured {
            XCTAssertTrue(available.contains(name), "\(name) is featured but not in the registry")
        }
        XCTAssertEqual(StylePreviews.featuredNames, StylePreviews.featured)
    }

    /// If this ever passes by coincidence rather than by derivation, the picker has
    /// started lying.
    func testASwatchTakesItsColoursFromThePresetItself() {
        for name in StylePreviews.featuredNames {
            let preset = Presets.preset(name)
            let swatch = StylePreviews.swatch(for: name)

            XCTAssertEqual(swatch.background, preset.styleProfile.background, name)
            XCTAssertEqual(
                swatch.contourColor,
                preset.styleProfile.style(for: "terrain_contours").strokeColor,
                name
            )
        }
    }

    func testADarkPresetIsRecognisedAsDark() {
        XCTAssertTrue(StylePreviews.swatch(for: "Night").isDark)
        XCTAssertFalse(StylePreviews.swatch(for: "Clean Atlas").isDark)
    }

    /// A weighted sheet and a flat one must look different in the picker without
    /// anyone having to say which is which.
    func testIndexContourWeightShowsAsAlternatingRingWidths() {
        let weighted = StylePreviews.swatch(for: "Hypsometric Relief")
        XCTAssertGreaterThan(
            Set(weighted.contourWidths).count, 1,
            "a preset that accents its index contours must show alternating weights"
        )

        // A preset whose contours are all one weight comes back uniform.
        let flat = StylePreviews.ringWidths(
            contour: LayerStyle(strokeWidth: 0.5),
            index: LayerStyle(strokeWidth: 0.5),
            rings: 5
        )
        XCTAssertEqual(Set(flat).count, 1)
    }

    func testAHypsometricPresetCarriesItsRampAndAFlatOneDoesNot() {
        let ramped = StylePreviews.swatch(for: "Hypsometric Relief")
        XCTAssertEqual(ramped.bandColors.count, 5)
        XCTAssertNotEqual(ramped.bandColors.first, ramped.bandColors.last, "the ramp does not ramp")

        // A preset with no high stop has no ramp to draw.
        XCTAssertTrue(StylePreviews.bandColors(nil, rings: 5).isEmpty)
        XCTAssertTrue(
            StylePreviews.bandColors(LayerStyle(fillEnabled: false), rings: 5).isEmpty
        )
    }

    /// Concentric circles read as a target; terrain does not.
    func testTheRingIsALopsidedShapeInsideTheUnitSquare() {
        for index in 0..<5 {
            let ring = StylePreviews.ringGeometry(index: index, total: 5)
            XCTAssertEqual(ring.count, 41)
            XCTAssertEqual(ring.first, ring.last, "the ring must close")

            let bounds = Bounds(ring)
            XCTAssertNotNil(bounds)
            XCTAssertNotEqual(bounds?.width, bounds?.height, "a circle reads as a target, not a hill")
        }
    }

    /// Inner rings must sit inside outer ones, or the hill reads as noise.
    func testRingsNest() throws {
        let outer = try XCTUnwrap(Bounds(StylePreviews.ringGeometry(index: 0, total: 5)))
        let inner = try XCTUnwrap(Bounds(StylePreviews.ringGeometry(index: 3, total: 5)))
        XCTAssertLessThan(inner.width, outer.width)
        XCTAssertLessThan(inner.height, outer.height)
    }

    func testTheWholePickerCanBeDescribedInOneCall() {
        let swatches = StylePreviews.swatches()
        XCTAssertEqual(swatches.count, StylePreviews.featuredNames.count)
        XCTAssertEqual(swatches.map(\.name), StylePreviews.featuredNames)
    }
}
