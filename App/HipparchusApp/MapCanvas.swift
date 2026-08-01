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
/// A weak handle onto the live canvas, so "Render map" can ask it what is on
/// screen right now.
///
/// `MapCanvas` is a value type recreated on every body evaluation, so a parent
/// cannot hold the `NSView` itself; this is the usual small reference-type
/// go-between for reaching into an `NSViewRepresentable` on demand rather than
/// only reacting to callbacks it chooses to fire.
@MainActor
final class MapCanvasHandle {
    fileprivate weak var view: MapCanvasView?

    /// The area currently on screen, accounting for pan, zoom and rotation —
    /// `nil` before anything has ever been drawn.
    func visibleArea() -> BoundingBox? {
        view?.visibleArea()
    }

    /// How wide the canvas is relative to its height. Available before
    /// anything has been drawn, unlike `visibleArea()`, which is the whole
    /// point of it: the *first* fetch needs to know the window's shape too,
    /// and until now it could not, so the first map ever drawn was always the
    /// wrong shape for the window it appeared in.
    func canvasAspect() -> Double? {
        guard let view, view.bounds.height > 0, view.bounds.width > 0 else { return nil }
        return view.bounds.width / view.bounds.height
    }
}

struct MapCanvas: NSViewRepresentable {
    let scene: RenderScene?
    var viewport: ViewportState
    var onViewportChange: (ViewportState) -> Void
    var onAreaDrawn: (BoundingBox) -> Void
    var handle: MapCanvasHandle?

    func makeNSView(context: Context) -> MapCanvasView {
        let view = MapCanvasView()
        view.onViewportChange = onViewportChange
        view.onAreaDrawn = onAreaDrawn
        handle?.view = view
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

    /// What this canvas is showing right now, in real coordinates — what
    /// "Render map" fetches instead of whatever was last typed, so zooming
    /// out (or in, or panning) and pressing it gets what is actually being
    /// looked at.
    ///
    /// Reuses the transform the last `draw(_:)` built rather than
    /// reconstructing one, so this can never disagree with what is actually
    /// on screen.
    func visibleArea() -> BoundingBox? {
        guard let scene, let transform else { return nil }

        // Inset by the same margin the fit leaves around the map, rather than
        // taking the canvas corners raw.
        //
        // The map is drawn inside the canvas less a margin, so the raw corners
        // describe an area about an eighth larger than the one on show. Fetch
        // that, fit it with a margin again, fetch that — and every press of
        // Render map walks the area outwards a little, which reads as the map
        // slowly zooming out on its own. Insetting makes the round trip a
        // fixed point: what is drawn is what is asked for next time.
        let margin = CanvasTransform.margin(width: bounds.width, height: bounds.height)
        let drawn = bounds.insetBy(dx: margin, dy: margin)
        guard drawn.width > 0, drawn.height > 0 else { return nil }

        // All four corners, not two: with the view turned, the corners of the
        // rectangle on screen are not the corners of the area underneath it.
        let corners = [
            CGPoint(x: drawn.minX, y: drawn.minY), CGPoint(x: drawn.maxX, y: drawn.minY),
            CGPoint(x: drawn.maxX, y: drawn.maxY), CGPoint(x: drawn.minX, y: drawn.maxY),
        ]
        .map { scene.projection.unproject(transform.screenToWorld($0)) }

        let lons = corners.map(\.lon)
        let lats = corners.map(\.lat)
        guard let minLon = lons.min(), let maxLon = lons.max(),
              let minLat = lats.min(), let maxLat = lats.max()
        else {
            return nil
        }
        return BoundingBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
    }

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
