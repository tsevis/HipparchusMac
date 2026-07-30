import AppKit
import HipparchusGeometry
import HipparchusRender
import SwiftUI

/// The map, drawn by the same renderer the CLI and the tests use.
///
/// An `NSView` rather than SwiftUI's `Canvas` because the scene is drawn straight
/// into a `CGContext`, and that is the whole point: one renderer serves the window,
/// the export and the headless tests, so there is no second drawing path that can
/// quietly disagree with the first.
///
/// The map is the product, so it gets the room: drag to pan, scroll to zoom,
/// Option-drag to draw a new area.
struct MapCanvas: NSViewRepresentable {
    let scene: RenderScene?
    var viewport: ViewportState
    var onViewportChange: (ViewportState) -> Void
    var onAreaDrawn: (BoundingBox) -> Void

    func makeNSView(context: Context) -> MapCanvasView {
        let view = MapCanvasView()
        view.onViewportChange = onViewportChange
        view.onAreaDrawn = onAreaDrawn
        return view
    }

    func updateNSView(_ view: MapCanvasView, context: Context) {
        view.scene = scene
        view.viewport = viewport
        view.onViewportChange = onViewportChange
        view.onAreaDrawn = onAreaDrawn
    }
}

final class MapCanvasView: NSView {
    var scene: RenderScene? {
        didSet { needsDisplay = true }
    }
    var viewport = ViewportState() {
        didSet { needsDisplay = true }
    }
    var onViewportChange: (ViewportState) -> Void = { _ in }
    var onAreaDrawn: (BoundingBox) -> Void = { _ in }

    private let renderer = CoreGraphicsRenderer()
    private var transform: CanvasTransform?
    /// The rectangle being drawn right now, in view coordinates.
    private var selection: CGRect?
    private var dragOrigin: CGPoint?

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Drawing

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
        transform = renderer.draw(scene, in: context, size: bounds.size, viewport: viewport)
        context.restoreGState()

        if let selection {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            selection.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selection)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    // MARK: - Direct manipulation

    override func scrollWheel(with event: NSEvent) {
        guard scene != nil else { return }
        // Trackpad pinch and wheel both arrive here; a small exponent keeps a
        // trackpad's many small deltas from flying past the area of interest.
        let factor = exp(event.scrollingDeltaY * 0.01)
        guard factor.isFinite, factor > 0 else { return }
        onViewportChange(viewport.zoomed(by: factor))
    }

    override func magnify(with event: NSEvent) {
        guard scene != nil else { return }
        onViewportChange(viewport.zoomed(by: 1 + event.magnification))
    }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) {
            selection = .zero
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)

        if selection != nil {
            selection = CGRect(
                x: min(dragOrigin.x, point.x),
                y: min(dragOrigin.y, point.y),
                width: abs(point.x - dragOrigin.x),
                height: abs(point.y - dragOrigin.y)
            )
            needsDisplay = true
            return
        }

        onViewportChange(viewport.panned(
            dx: point.x - dragOrigin.x,
            // The view's y grows upward and the viewport's grows downward, so a
            // drag up must pan the map up rather than down.
            dy: dragOrigin.y - point.y
        ))
        self.dragOrigin = point
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            selection = nil
            needsDisplay = true
        }

        guard let selection, let transform, let scene,
              // A stray Option-click is not an area.
              selection.width > 8, selection.height > 8
        else {
            return
        }

        // View coordinates are bottom-left; the transform speaks top-left.
        let topLeft = CGPoint(x: selection.minX, y: bounds.height - selection.maxY)
        let bottomRight = CGPoint(x: selection.maxX, y: bounds.height - selection.minY)

        let first = scene.projection.unproject(transform.screenToWorld(topLeft))
        let second = scene.projection.unproject(transform.screenToWorld(bottomRight))

        onAreaDrawn(BoundingBox(
            minLon: min(first.lon, second.lon),
            minLat: min(first.lat, second.lat),
            maxLon: max(first.lon, second.lon),
            maxLat: max(first.lat, second.lat)
        ))
    }
}
