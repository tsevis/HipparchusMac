import CoreGraphics
import Foundation

/// The room a label takes on the canvas: a rectangle around its type, turned
/// with it.
///
/// Screen space, y down, and turned the way both renderers turn a label — the
/// SVG's `rotate(θ)` and Core Graphics' `rotate(by:)` on its flipped canvas
/// agree — so a street name's box lies along the street like its letters do.
struct LabelBox {
    let centre: CGPoint
    let halfWidth: Double
    let halfHeight: Double
    /// Radians.
    let angle: Double

    /// The four corners, in order around the box.
    var corners: [CGPoint] {
        let (cosine, sine) = (cos(angle), sin(angle))
        return [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { sx, sy in
            let x = sx * halfWidth, y = sy * halfHeight
            return CGPoint(x: centre.x + x * cosine - y * sine, y: centre.y + x * sine + y * cosine)
        }
    }

    /// The upright rectangle that holds it: what the spatial index files it under.
    var bounds: CGRect {
        let points = corners
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(
            x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!
        )
    }

    /// Whether the whole box lies on the canvas.
    func fits(in canvas: CGRect) -> Bool {
        corners.allSatisfy(canvas.contains)
    }

    /// Whether two boxes share any room.
    ///
    /// Separating axes: two rectangles are apart exactly when, along one of
    /// their four edge directions, their shadows do not meet. The upright
    /// bounds alone would make a diagonal street name claim the whole square
    /// around it and drop every name beside it.
    func overlaps(_ other: LabelBox) -> Bool {
        guard bounds.intersects(other.bounds) else { return false }
        let (mine, theirs) = (corners, other.corners)
        let axes = [angle, angle + .pi / 2, other.angle, other.angle + .pi / 2]
        return !axes.contains { axis in
            let direction = (x: cos(axis), y: sin(axis))
            func shadow(_ points: [CGPoint]) -> (min: Double, max: Double) {
                let lengths = points.map { $0.x * direction.x + $0.y * direction.y }
                return (lengths.min()!, lengths.max()!)
            }
            let (a, b) = (shadow(mine), shadow(theirs))
            return a.max < b.min || b.max < a.min
        }
    }
}
