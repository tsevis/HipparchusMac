import XCTest
import HipparchusData
@testable import HipparchusRender

/// Limassol Towel — a beach towel read as a hypsometric ramp. The land runs
/// yellow in the plain to black at the summit; the sea runs light at the coast
/// to black in the abyss. Three variations of the one idea.
final class LimassolTowelTests: XCTestCase {
    private let names = ["Limassol Towel", "Limassol Towel Noir", "Limassol Towel Sand"]

    func testAllThreeVariationsAreOffered() throws {
        for name in names {
            XCTAssertNotNil(Palette.named(name), "no palette named \(name)")
        }
    }

    func testTheLandRunsYellowPlainToBlackSummit() throws {
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let bands = try XCTUnwrap(styles["elevation_bands"], "\(name): no elevation bands")
            XCTAssertTrue(bands.fillEnabled, "\(name): the land is not filled")
            let plain = bands.fillColor
            let summit = try XCTUnwrap(bands.fillColorHigh, "\(name): the land has one stop, not two")
            // The plain is yellow — red and green high, blue low.
            XCTAssertGreaterThan(Int(plain.r), 200, "\(name): the plain is not yellow")
            XCTAssertGreaterThan(Int(plain.g), 150, "\(name): the plain is not yellow")
            XCTAssertLessThan(Int(plain.b), 120, "\(name): the plain is not yellow")
            // The summit is darker than the plain.
            XCTAssertLessThan(Palette.luma(summit), Palette.luma(plain),
                              "\(name): the summit is not darker than the plain")
        }
    }

    func testTheSeaRunsLightCoastToBlackAbyss() throws {
        for name in names {
            let styles = try XCTUnwrap(Palette.named(name)).styleProfile().layerStyles
            let depth = try XCTUnwrap(styles["depth_bands"], "\(name): no depth bands")
            let abyss = depth.fillColor
            let coast = try XCTUnwrap(depth.fillColorHigh, "\(name): the sea has one stop, not two")
            // The deepest is near-black; the coast far lighter.
            XCTAssertLessThan(Palette.luma(abyss), 20.0, "\(name): the abyss is not near-black")
            XCTAssertGreaterThan(Palette.luma(coast), Palette.luma(abyss) + 100.0,
                                 "\(name): the coast is not much lighter than the abyss")
        }
    }
}
