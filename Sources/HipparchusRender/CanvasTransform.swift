import CoreGraphics
import Foundation
import HipparchusGeometry

/// How world coordinates land on the canvas, and how to get back.
///
/// Ported from `SkiaRenderer.fit_metrics` / `world_to_screen` / `screen_to_world`.
///
/// **One source of truth, deliberately.** Both directions of the mapping *and* the
/// drawing code read this same type. In the Python, labels and geometry once
/// computed the transform separately, and a rotated map left its labels behind —
/// nothing was wrong with either calculation, they simply disagreed. Extracting
/// the transform is what fixed it, and it is also what makes the canvas usable as
/// an input device: modifier-drag to draw a new area needs `screenToWorld` to be
/// the exact inverse of what was drawn.
public struct CanvasTransform: Sendable, Equatable {
    /// World-units-to-points, before the viewport zoom.
    public let fitScale: Double
    public let offsetX: Double
    public let offsetY: Double
    public let worldMinX: Double
    public let worldMaxY: Double
    public let viewport: ViewportState
    /// The point the viewport turns and scales about — the middle of the canvas,
    /// which is also where `offsetX`/`offsetY` put the middle of the map. Zooming
    /// and rotating about the origin instead walked the map out of the window.
    public let pivotX: Double
    public let pivotY: Double

    /// Points of breathing room around the map, so linework does not run to the
    /// very edge of the canvas.
    public static func margin(width: Double, height: Double) -> Double {
        max(16.0, min(width, height) * 0.06)
    }

    public init?(contentBounds: Bounds?, size: CGSize, viewport: ViewportState = ViewportState()) {
        guard let bounds = contentBounds, size.width > 0, size.height > 0 else { return nil }

        let spanX = max(bounds.width, 1e-9)
        let spanY = max(bounds.height, 1e-9)
        let margin = Self.margin(width: size.width, height: size.height)
        let availableWidth = max(1.0, size.width - 2.0 * margin)
        let availableHeight = max(1.0, size.height - 2.0 * margin)

        fitScale = max(1e-6, min(min(availableWidth / spanX, availableHeight / spanY), 1e6))
        offsetX = (size.width - spanX * fitScale) * 0.5
        offsetY = (size.height - spanY * fitScale) * 0.5
        worldMinX = bounds.minX
        worldMaxY = bounds.maxY
        pivotX = size.width * 0.5
        pivotY = size.height * 0.5
        self.viewport = viewport
    }

    /// World (projected) coordinates to canvas points.
    ///
    /// Y is flipped here: world y increases north, canvas y increases downward.
    public func worldToScreen(_ world: Coordinate) -> CGPoint {
        let px = offsetX + (world.x - worldMinX) * fitScale
        let py = offsetY + (worldMaxY - world.y) * fitScale
        // Turned and scaled about the middle of the canvas. About the origin — as
        // this did — a map at zoom 3 lands three times its own offset down and
        // right, and a map at 90° leaves the window altogether.
        let dx = px - pivotX
        let dy = py - pivotY
        let radians = viewport.rotation * .pi / 180.0
        let cosR = cos(radians)
        let sinR = sin(radians)
        let rx = dx * cosR - dy * sinR
        let ry = dx * sinR + dy * cosR
        return CGPoint(
            x: viewport.panX + pivotX + rx * viewport.zoom,
            y: viewport.panY + pivotY + ry * viewport.zoom
        )
    }

    /// Canvas points back to world (projected) coordinates.
    ///
    /// The exact inverse of `worldToScreen`, which is what lets the canvas be used
    /// as an input device rather than only as a picture.
    public func screenToWorld(_ point: CGPoint) -> Coordinate {
        let zoom = viewport.zoom == 0 ? 1.0 : viewport.zoom
        let rx = (point.x - viewport.panX - pivotX) / zoom
        let ry = (point.y - viewport.panY - pivotY) / zoom
        let radians = viewport.rotation * .pi / 180.0
        let cosR = cos(radians)
        let sinR = sin(radians)
        let px = rx * cosR + ry * sinR + pivotX
        let py = -rx * sinR + ry * cosR + pivotY
        return Coordinate(
            x: worldMinX + (px - offsetX) / fitScale,
            y: worldMaxY - (py - offsetY) / fitScale
        )
    }

    /// Stroke widths are specified in points on the page, so they are divided by
    /// the fit scale before being handed to a context that is drawing in world
    /// units. Without this a wide area draws hairlines and a small one draws slabs.
    public func strokeWidth(_ points: Double) -> Double {
        max(0.0001, points) / fitScale
    }

    /// The world-space rectangle a canvas of `size` is currently showing,
    /// accounting for pan, zoom and rotation.
    ///
    /// This is what "Update map" reads instead of whatever was last typed:
    /// zoom and pan are view state, kept deliberately out of the requested
    /// area, so without this a zoomed-out view and a freshly re-fetched one
    /// disagree — the button re-fetches the old area, the screen still shows
    /// the wider one, and nothing looks like it happened.
    ///
    /// All four corners are used, not two opposite ones. A rotated viewport's
    /// visible region is a rotated rectangle, and its true axis-aligned bounds
    /// need the full corner set — at 90° two diagonal corners alone would
    /// report the canvas's own width and height transposed onto the wrong
    /// axes rather than the ground actually spanned.
    public func visibleWorldBounds(canvasSize size: CGSize) -> Bounds {
        let corners = [
            CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
            CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height),
        ].map(screenToWorld)
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return Bounds(
            minX: xs.min() ?? 0, minY: ys.min() ?? 0,
            maxX: xs.max() ?? 0, maxY: ys.max() ?? 0
        )
    }
}
