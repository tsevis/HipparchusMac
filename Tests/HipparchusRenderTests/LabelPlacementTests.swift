import CoreGraphics
import Foundation
import HipparchusGeometry
import XCTest
@testable import HipparchusRender

/// Labels from every layer compete for the same room on the sheet.
///
/// Thinning ran per layer when the scene was built, so a street name was only
/// ever tested against street names and a shop against shops, with boxes
/// guessed from the character count: on a city sheet the street names, places
/// and shops overprinted each other. Placement now measures every label, boxes
/// it as drawn — rotated with a street — and lets the more important one win.
final class LabelPlacementTests: XCTestCase {

    private static let side = 300.0

    private func layer(_ name: String, _ labels: [PlaceLabel], ink: RGBAColor = RGBAColor(0, 0, 0)) -> RenderLayer {
        var style = LayerStyle()
        style.fillEnabled = false
        style.strokeWidth = 0
        style.strokeColor = ink
        style.labelHaloWidth = 0
        return RenderLayer(name: name, style: style, labels: labels)
    }

    /// A frame of 0…300 in both directions, drawn onto a 300-point canvas.
    private func frame() -> RenderLayer {
        var frame = layer("buildings", [])
        frame.append(.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 300, y: 300)])))
        return frame
    }

    private func transform() throws -> CanvasTransform {
        try XCTUnwrap(CanvasTransform(
            contentBounds: Bounds(minX: 0, minY: 0, maxX: Self.side, maxY: Self.side),
            size: CGSize(width: Self.side, height: Self.side), viewport: ViewportState(), margin: 0
        ))
    }

    private func accepted(_ layers: [RenderLayer]) throws -> Set<LabelPlacement.Key> {
        LabelPlacement.accepted(
            in: layers, transform: try transform(), typeSize: PlaceLabel.typeSize, labelScale: 1
        )
    }

    private func key(_ layer: String, _ index: Int = 0) -> LabelPlacement.Key {
        LabelPlacement.Key(layer: layer, index: index)
    }

    // MARK: - The rule

    /// A town and a shop on the same spot: the town is drawn, the shop is not —
    /// and it does not matter which layer comes first in the drawing order.
    func testTheMoreImportantLabelWinsAcrossLayers() throws {
        let centre = Coordinate(x: 150, y: 150)
        let shops = layer("shops", [PlaceLabel(name: "Corner Shop", position: centre)])
        let places = layer("places", [PlaceLabel(name: "Townsville", position: centre, placeType: "town")])
        XCTAssertEqual(try accepted([frame(), shops, places]), [key("places")])
        XCTAssertEqual(try accepted([frame(), places, shops]), [key("places")])
    }

    /// A name the frame edge would cut in half is not drawn.
    func testALabelTheEdgeWouldCutIsDropped() throws {
        let edge = layer("places", [PlaceLabel(name: "Edgetown", position: Coordinate(x: 3, y: 150))])
        XCTAssertEqual(try accepted([frame(), edge]), [])
    }

    /// A street name runs along its street, and its box turns with it: a label
    /// beside a diagonal street, clear of the type itself but inside the square
    /// that would enclose it, is still drawn.
    func testADiagonalStreetNameReservesOnlyItsOwnBand() throws {
        let transform = try transform()
        let centre = transform.worldToScreen(Coordinate(x: 150, y: 150))
        // Rotated 45° in screen space (y down), the type runs towards +x +y; this
        // point is 40 points off that line, square to it.
        let beside = transform.screenToWorld(CGPoint(x: centre.x + 28, y: centre.y - 28))
        let street = layer("street_names", [PlaceLabel(
            name: "Northwest Twenty Second Avenue", position: Coordinate(x: 150, y: 150),
            placeType: "street", rotation: 45
        )])
        let place = layer("places", [PlaceLabel(name: "Ab", position: beside, placeType: "suburb")])
        XCTAssertEqual(try accepted([frame(), street, place]), [key("street_names"), key("places")])
    }

    // MARK: - Both renderers draw what placement decided

    private func overlapping() -> RenderScene {
        let centre = Coordinate(x: 150, y: 150)
        return RenderScene(layers: [
            frame(),
            layer("shops", [PlaceLabel(name: "Corner Shop", position: centre)], ink: RGBAColor(255, 0, 0)),
            layer("places", [PlaceLabel(name: "Townsville", position: centre, placeType: "town")]),
        ], background: RGBAColor(255, 255, 255))
    }

    func testTheCanvasDoesNotDrawALabelThatLostItsPlace() throws {
        var options = CoreGraphicsRenderer.Options()
        options.drawNotForNavigation = false
        let image = try XCTUnwrap(CoreGraphicsRenderer(options: options).image(
            of: overlapping(), size: CGSize(width: Self.side, height: Self.side), margin: 0
        ))
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let red = (0..<image.height).contains { y in
            (0..<image.width).contains { x in
                let index = y * image.bytesPerRow + x * 4
                return data[index] > 200 && data[index + 1] < 80 && data[index + 2] < 80
            }
        }
        XCTAssertFalse(red, "the shop's name was drawn over the town's")
    }

    func testTheSVGDoesNotWriteALabelThatLostItsPlace() {
        var options = SVGExporter.Options()
        options.width = Int(Self.side)
        options.height = Int(Self.side)
        let text = SVGExporter(options: options).svg(for: overlapping())
        XCTAssertTrue(text.contains(">Townsville<"), "the winning label is missing")
        XCTAssertFalse(text.contains(">Corner Shop<"), "the shop's name was written over the town's")
    }
}
