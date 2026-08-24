import XCTest
import HipparchusData
@testable import HipparchusRender

/// Limassol Towel — a dark topographic HUD. The land is near-black with warm
/// relief contours; the sea is greyscale, its depth read as many greys from the
/// light shelves to the black trenches. All the colour is in the lines. Three
/// variations of the one idea, differing in the colour of the light on the land.
final class LimassolTowelTests: XCTestCase {
    private let names = ["Limassol Towel", "Limassol Towel Noir", "Limassol Towel Neon"]

    private func channelSpread(_ colour: RGBAColor) -> Int {
        Int(max(colour.r, max(colour.g, colour.b))) - Int(min(colour.r, min(colour.g, colour.b)))
    }

    func testAllThreeVariationsAreOffered() throws {
        for name in names {
            XCTAssertNotNil(Palette.named(name), "no palette named \(name)")
        }
    }

    func testTheGroundIsDark() throws {
        for name in names {
            let palette = try XCTUnwrap(Palette.named(name))
            XCTAssertLessThan(Palette.luma(palette.ground), 40.0, "\(name): the ground is not dark")
        }
    }

    func testTheLandIsDarkRelief() throws {
        for name in names {
            let land = try XCTUnwrap(
                try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles["elevation_bands"]
            )
            XCTAssertLessThan(Palette.luma(land.fillColor), 80.0, "\(name): the plain is not dark")
            XCTAssertLessThan(Palette.luma(try XCTUnwrap(land.fillColorHigh)), 80.0,
                              "\(name): the summit is not dark")
        }
    }

    func testTheContoursAreTheBrightEdge() throws {
        // Bright lines on a dark ground; the contrast lives where the line
        // crosses the fill — at the edges of the relief.
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

    func testTheSeaIsGreyscaleDepthNotColour() throws {
        // Many greys, not a hue: light on the shelves, black in the trenches.
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let sea = try XCTUnwrap(styles["depth_bands"], "\(name): no depth bands")
            let trench = sea.fillColor
            let shelf = try XCTUnwrap(sea.fillColorHigh)
            XCTAssertLessThanOrEqual(channelSpread(trench), 12, "\(name): the trench has a hue, not grey")
            XCTAssertLessThanOrEqual(channelSpread(shelf), 12, "\(name): the shelf has a hue, not grey")
            XCTAssertLessThan(Palette.luma(trench), 25.0, "\(name): the trench is not near-black")
            XCTAssertGreaterThan(Palette.luma(shelf) - Palette.luma(trench), 60.0,
                                 "\(name): too little range for many greys")
        }
    }

    func testTheSeaFloorCarriesItsOwnContours() throws {
        // A black sea is not an empty void: the sub-sea contours are its own
        // bright grey linework, brighter than the shelf they cross.
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let bathymetry = try XCTUnwrap(styles["bathymetry"], "\(name): no bathymetry")
            XCTAssertLessThanOrEqual(channelSpread(bathymetry.strokeColor), 12,
                                     "\(name): the sea floor lines have a hue")
            XCTAssertGreaterThan(Palette.luma(bathymetry.strokeColor), 150.0,
                                 "\(name): the sea floor contours do not read")
        }
    }
}
