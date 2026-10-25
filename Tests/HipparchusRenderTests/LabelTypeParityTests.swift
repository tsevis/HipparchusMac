import CoreGraphics
import Foundation
import HipparchusGeometry
import XCTest
@testable import HipparchusRender

/// The two files of one sheet set their labels alike.
///
/// The canvas (and so the PNG, the PDF and the window) drew labels at 9 in
/// Helvetica Neue with a halo of 0.22 × the type size, ignoring the halo width
/// every preset states; the SVG wrote 12 in Arial with the preset's halo. The
/// same sheet exported twice came out with different type.
final class LabelTypeParityTests: XCTestCase {

    private func labelled(halo: Double) -> RenderScene {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeColor = RGBAColor(0, 0, 0)
        style.strokeWidth = 0
        style.labelHaloWidth = halo
        style.labelHaloColor = RGBAColor(255, 0, 0)
        var layer = RenderLayer(
            name: "places", style: style,
            labels: [PlaceLabel(name: "MMMM", position: Coordinate(x: 50, y: 50))]
        )
        layer.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 100)])))
        return RenderScene(layers: [layer], background: RGBAColor(255, 255, 255))
    }

    /// Rows of red halo ink around the label, which is how tall the halo reaches.
    private func haloRows(halo: Double) throws -> Int {
        var options = CoreGraphicsRenderer.Options()
        options.drawNotForNavigation = false
        let side = 300
        let image = try XCTUnwrap(CoreGraphicsRenderer(options: options).image(
            of: labelled(halo: halo), size: CGSize(width: side, height: side), margin: 0
        ))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        return (0..<side).filter { y in
            (0..<side).contains { x in
                let index = y * image.bytesPerRow + x * 4
                return data[index] > 200 && data[index + 1] < 80 && data[index + 2] < 80
            }
        }.count
    }

    func testTheSVGSetsLabelsInTheCanvasType() {
        let text = SVGExporter().svg(for: labelled(halo: 2))
        XCTAssertTrue(text.contains("font-size=\"9\""), "the SVG's labels are not the canvas's size")
        XCTAssertTrue(
            text.contains("font-family=\"'Helvetica Neue', Helvetica, Arial, sans-serif\""),
            "the SVG's labels are not the canvas's face"
        )
    }

    func testTheCanvasDrawsTheHaloThePresetStates() throws {
        let narrow = try haloRows(halo: 1)
        let wide = try haloRows(halo: 8)
        XCTAssertGreaterThan(narrow, 0, "no halo was drawn at all")
        XCTAssertGreaterThan(wide, narrow + 4, "a halo of 8 drew as tall as a halo of 1")
    }
}
