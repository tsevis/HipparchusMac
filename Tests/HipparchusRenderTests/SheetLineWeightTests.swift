import XCTest
import HipparchusGeometry
@testable import HipparchusRender

/// A bigger sheet draws the same picture enlarged, not the same lines thinner.
final class SheetLineWeightTests: XCTestCase {

    private func road() -> RenderScene {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeWidth = 3
        style.casingWidth = 5
        var layer = RenderLayer(name: "roads_secondary", style: style)
        layer.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 0)])))
        return RenderScene(layers: [layer], background: RGBAColor(255, 255, 255))
    }

    /// Three times the reference on each side: every line three times wider, so
    /// a print does not come out in hairlines.
    func testABigSheetDrawsTheSamePictureEnlarged() throws {
        let style = try XCTUnwrap(road().scaledForSheet(width: 4800, height: 3600).layers.first).style
        XCTAssertEqual(style.strokeWidth, 9, accuracy: 1e-9)
        XCTAssertEqual(style.casingWidth, 15, accuracy: 1e-9)
    }

    /// The default canvas, and an edge-to-edge sheet fitted inside it, draw at
    /// exactly the widths the preset states — never thinner.
    func testTheDefaultCanvasAndSmallerSheetsAreUnchanged() throws {
        for (width, height) in [(1600.0, 1200.0), (1600.0, 1067.0), (400.0, 300.0)] {
            let style = try XCTUnwrap(road().scaledForSheet(width: width, height: height).layers.first).style
            XCTAssertEqual(style.strokeWidth, 3, "a \(Int(width)) × \(Int(height)) sheet changed its lines")
        }
    }
}
