import CoreGraphics
import Foundation
import HipparchusGeometry
import XCTest
@testable import HipparchusRender

/// On a bigger sheet the labels grow with the lines.
///
/// Line weights learned to scale with the sheet and the type did not: a print at
/// three times the canvas carried roads three times wider and place names at the
/// size they had on screen, a third of what they should be beside the roads.
final class SheetLabelScaleTests: XCTestCase {

    private func labelled() -> RenderScene {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeColor = RGBAColor(0, 0, 0)
        style.strokeWidth = 0
        style.labelHaloWidth = 0
        var layer = RenderLayer(
            name: "places", style: style,
            labels: [PlaceLabel(name: "MMMM", position: Coordinate(x: 50, y: 50))]
        )
        // Something to frame: the label sits at the centre of this square.
        layer.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 100)])))
        return RenderScene(layers: [layer], background: RGBAColor(255, 255, 255))
    }

    /// How wide the dark ink is along the middle rows of the canvas, in pixels.
    private func inkWidth(of scene: RenderScene) throws -> Int {
        var options = CoreGraphicsRenderer.Options()
        options.drawNotForNavigation = false
        let side = 600
        let image = try XCTUnwrap(CoreGraphicsRenderer(options: options).image(
            of: scene, size: CGSize(width: side, height: side), margin: 0
        ))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        var left = side, right = -1
        for y in (side / 2 - 40)..<(side / 2 + 40) {
            for x in 0..<side {
                let index = y * image.bytesPerRow + x * 4
                // The diagonal under the label is drawn at zero width, so any dark
                // pixel here is type.
                if data[index] < 100 { left = min(left, x); right = max(right, x) }
            }
        }
        return right - left
    }

    func testTheCanvasDrawsLabelsLargerOnABiggerSheet() throws {
        let plain = try inkWidth(of: labelled())
        let enlarged = try inkWidth(of: labelled().scaledForSheet(width: 4800, height: 3600))
        XCTAssertGreaterThan(plain, 0, "the label was not drawn at all")
        XCTAssertEqual(
            Double(enlarged) / Double(plain), 3, accuracy: 0.3,
            "a sheet three times the canvas drew its labels at \(enlarged) px against \(plain)"
        )
    }

    func testTheSVGWritesLabelsLargerOnABiggerSheet() throws {
        var scene = labelled()
        scene.layers[0].style.labelHaloWidth = 2
        let text = SVGExporter().svg(for: scene.scaledForSheet(width: 4800, height: 3600))
        XCTAssertTrue(text.contains("font-size=\"27\""), "the label kept the screen's type size")
        XCTAssertTrue(text.contains("stroke-width=\"6\""), "the halo kept the screen's width")
    }
}
