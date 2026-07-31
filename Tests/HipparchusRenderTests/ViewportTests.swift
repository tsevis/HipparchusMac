import XCTest
@testable import HipparchusRender

/// Turning and scaling the view, and the arithmetic behind the controls.
///
/// `ViewportState` is view state, not map state: it is deliberately absent from
/// `Session` and from the undo history, and the exporters build their transform
/// with a fresh one — so rotating the preview frames the screen, never the file.
final class ViewportTests: XCTestCase {

    // MARK: - Rotation

    func testRotatingStepsByTheAmountGiven() {
        let turned = ViewportState().rotated(by: 15)
        XCTAssertEqual(turned.rotation, 15, accuracy: 1e-12)
        XCTAssertEqual(turned.rotated(by: 15).rotation, 30, accuracy: 1e-12)
        XCTAssertEqual(turned.rotated(by: -15).rotation, 0, accuracy: 1e-12)
    }

    /// The readout is a bearing, so it stays in the half-turn either side of
    /// north rather than counting up forever: twelve steps of 15° is a
    /// half-turn, and the thirteenth reads as −165°, not 195°.
    func testRotationWrapsIntoHalfATurnEitherWay() {
        var viewport = ViewportState()
        for _ in 0..<12 { viewport = viewport.rotated(by: 15) }
        XCTAssertEqual(viewport.rotation, 180, accuracy: 1e-9)

        viewport = viewport.rotated(by: 15)
        XCTAssertEqual(viewport.rotation, -165, accuracy: 1e-9)

        XCTAssertEqual(ViewportState().rotated(by: -190).rotation, 170, accuracy: 1e-9)
        XCTAssertEqual(ViewportState().rotated(to: 540).rotation, 180, accuracy: 1e-9)
        XCTAssertEqual(ViewportState().rotated(to: -180).rotation, 180, accuracy: 1e-9)
    }

    /// Turning the view keeps the zoom and pan it was turned at.
    func testRotatingLeavesTheRestOfTheViewportAlone() {
        let viewport = ViewportState(zoom: 2.5, panX: 30, panY: -12).rotated(by: 45)
        XCTAssertEqual(viewport.zoom, 2.5)
        XCTAssertEqual(viewport.panX, 30)
        XCTAssertEqual(viewport.panY, -12)
    }

    /// Fitting the map to the window undoes the turn as well as the zoom — one
    /// control that means "show me the whole thing the right way up".
    func testTheDefaultViewportIsUnturned() {
        XCTAssertEqual(ViewportState().rotation, 0)
        XCTAssertEqual(ViewportState().zoom, 1)
    }

    // MARK: - Zoom, which is bounded

    func testZoomIsClampedRatherThanRunningAway() {
        XCTAssertEqual(ViewportState().zoomed(by: 1000).zoom, 64)
        XCTAssertEqual(ViewportState().zoomed(by: 0.0001).zoom, 0.05)
    }

    // MARK: - What actually reaches the canvas

    /// A turned view draws a different picture, and still draws one.
    ///
    /// The arithmetic being right is not the same as the map being on the page:
    /// turning about the origin kept an exact inverse while sending the content
    /// off the canvas, and a test of the transform alone would have passed. This
    /// counts painted pixels instead.
    func testTurningTheViewRedrawsTheMapWithoutLosingIt() throws {
        let scene = try Sample.scene()
        let size = CGSize(width: 300, height: 300)
        let renderer = CoreGraphicsRenderer()

        func painted(_ viewport: ViewportState) throws -> (count: Int, data: Data) {
            let image = try XCTUnwrap(renderer.image(of: scene, size: size, viewport: viewport))
            let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
            let ground = scene.background
            var count = 0
            for index in stride(from: 0, to: pixels.count - 3, by: 4) {
                if abs(Int(pixels[index]) - Int(ground.r)) > 2
                    || abs(Int(pixels[index + 1]) - Int(ground.g)) > 2
                    || abs(Int(pixels[index + 2]) - Int(ground.b)) > 2 {
                    count += 1
                }
            }
            return (count, pixels)
        }

        let upright = try painted(ViewportState())
        let turned = try painted(ViewportState().rotated(by: 45))

        XCTAssertGreaterThan(upright.count, 500, "the unturned map drew nothing to compare against")
        XCTAssertGreaterThan(turned.count, 500, "the turned map left the canvas")
        // Within a quarter of each other: a square scene turned 45° loses a
        // little to the corners, but not most of itself.
        XCTAssertGreaterThan(Double(turned.count), Double(upright.count) * 0.75)
        XCTAssertNotEqual(turned.data, upright.data, "turning the view changed nothing on the page")
    }
}
