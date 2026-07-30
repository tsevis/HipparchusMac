import AppKit
import HipparchusRender
import SwiftUI

/// The map, drawn by the same renderer the CLI and the tests use.
///
/// An `NSView` rather than SwiftUI's `Canvas` because the scene is drawn straight
/// into a `CGContext`, and that is the whole point: one renderer serves the window,
/// the export and the headless tests, so there is no second drawing path that can
/// quietly disagree with the first.
struct MapCanvas: NSViewRepresentable {
    let scene: RenderScene?

    func makeNSView(context: Context) -> MapCanvasView {
        MapCanvasView()
    }

    func updateNSView(_ view: MapCanvasView, context: Context) {
        view.scene = scene
    }
}

final class MapCanvasView: NSView {
    var scene: RenderScene? {
        didSet { needsDisplay = true }
    }

    private let renderer = CoreGraphicsRenderer()

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        guard let scene else {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            return
        }

        context.saveGState()
        // An NSView's context has a bottom-left origin; CanvasTransform works in
        // top-left coordinates as a window does. One flip, in the same place and for
        // the same reason as in the bitmap and PDF renderers.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        renderer.draw(scene, in: context, size: bounds.size)
        context.restoreGState()
    }
}
