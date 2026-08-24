import XCTest
import HipparchusData
@testable import HipparchusRender

/// Limassol Towel — a dark topographic HUD. Land and sea are near-black; the
/// colour is in the lines, not the fills. Bright contours glow against the dark,
/// and the coast is the sharpest edge on the sheet. Three variations of the one
/// idea, differing in the colour of the light.
final class LimassolTowelTests: XCTestCase {
    private let names = ["Limassol Towel", "Limassol Towel Noir", "Limassol Towel Neon"]

    func testAllThreeVariationsAreOffered() throws {
        for name in names {
            XCTAssertNotNil(Palette.named(name), "no palette named \(name)")
        }
    }

    func testTheGroundIsDark() throws {
        // A HUD, not a page: the paper is near-black.
        for name in names {
            let palette = try XCTUnwrap(Palette.named(name))
            XCTAssertLessThan(Palette.luma(palette.ground), 40.0, "\(name): the ground is not dark")
        }
    }

    func testTheLandAndSeaAreDarkNotYellow() throws {
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let land = try XCTUnwrap(styles["elevation_bands"], "\(name): no elevation bands")
            let sea = try XCTUnwrap(styles["depth_bands"], "\(name): no depth bands")
            // Every fill stop is dark — the accent is the linework, never the fill.
            XCTAssertLessThan(Palette.luma(land.fillColor), 80.0, "\(name): the plain is not dark")
            XCTAssertLessThan(Palette.luma(try XCTUnwrap(land.fillColorHigh)), 80.0,
                              "\(name): the summit is not dark")
            XCTAssertLessThan(Palette.luma(sea.fillColor), 20.0, "\(name): the abyss is not near-black")
            XCTAssertLessThan(Palette.luma(try XCTUnwrap(sea.fillColorHigh)), 80.0,
                              "\(name): the shallows are not dark")
        }
    }

    func testTheContoursAreTheBrightEdge() throws {
        // The techie part: bright lines on a dark ground, and the contrast lives
        // where the line crosses the fill — at the edges of the relief.
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let contour = try XCTUnwrap(styles["terrain_contours"], "\(name): no contours")
            let land = try XCTUnwrap(styles["elevation_bands"])
            XCTAssertGreaterThan(Palette.luma(contour.strokeColor), 130.0,
                                 "\(name): the contours do not glow against the dark")
            XCTAssertGreaterThan(Palette.luma(contour.strokeColor),
                                 Palette.luma(land.fillColor) + 80.0,
                                 "\(name): too little contrast between the line and the ground")
        }
    }
}
