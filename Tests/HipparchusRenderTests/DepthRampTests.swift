import XCTest
@testable import HipparchusRender

/// Which way the sea floor's ramp runs.
///
/// **Five of the seventeen palettes drew deep water bright**, from the day the
/// depth bands landed. The ramp was named rather than measured — one end "toward
/// ink", the other "toward ground" — and on a dark sheet the ink is pale and the
/// paper is near-black, so the two swap. Tsevis Nocturne, Slate, Pytheas,
/// Vespucci and High Contrast Dark all shipped inside out.
///
/// It survived every review because the twelve light palettes agree with the
/// naming, and those are the ones anybody renders. Nothing looked wrong: every
/// individual colour was defensible and the sheet was merely telling the reader
/// the trench was the shallow part.
///
/// The check is one line and it is the kind that only ever fails for a real
/// reason, which is the argument for asserting on polarity rather than trusting
/// a formula that reads correctly.
final class DepthRampTests: XCTestCase {

    private func luma(_ colour: RGBAColor) -> Double {
        (299 * Double(colour.r) + 587 * Double(colour.g) + 114 * Double(colour.b)) / 1000
    }

    /// Deep is darker. A reader assumes it without being told, which is exactly
    /// why getting it backwards is invisible.
    func testDeepIsDarkerThanShallowInEveryPalette() throws {
        for palette in Palette.all {
            let style = try XCTUnwrap(
                palette.styleProfile().layerStyles["depth_bands"],
                "\(palette.name) has no depth bands"
            )
            let shallow = try XCTUnwrap(style.fillColorHigh, "\(palette.name) has no far stop")
            XCTAssertLessThan(
                luma(style.fillColor), luma(shallow),
                "\(palette.name) draws deep water lighter than shallow"
            )
        }
    }

    /// Both ends have to exist for a two-stop ramp to be a ramp at all. A
    /// missing far stop is not a failure anybody sees — the layer simply draws
    /// flat, in one colour, and reads as a single sheet of water.
    func testEveryPaletteStatesBothEnds() throws {
        for palette in Palette.all {
            let style = try XCTUnwrap(palette.styleProfile().layerStyles["depth_bands"])
            XCTAssertTrue(style.fillEnabled, "\(palette.name) does not fill its depth bands")
            XCTAssertNotNil(style.fillColorHigh, "\(palette.name) has one stop, not two")
        }
    }

    /// The two ends have to be far enough apart to read as a ramp. A palette
    /// whose water, ink and ground are all nearly the same colour would pass the
    /// polarity check with two stops nobody can tell apart.
    func testTheTwoEndsAreDistinguishable() throws {
        for palette in Palette.all {
            let style = try XCTUnwrap(palette.styleProfile().layerStyles["depth_bands"])
            let shallow = try XCTUnwrap(style.fillColorHigh)
            XCTAssertGreaterThan(
                luma(shallow) - luma(style.fillColor), 8.0,
                "\(palette.name)'s depth ramp is too flat to read"
            )
        }
    }
}
