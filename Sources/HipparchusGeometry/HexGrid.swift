import Foundation

/// A hexagonal grid over an area.
///
/// Ported from `geometry/hex_grid.py`. Generating the hexagons is pure arithmetic
/// and lives here; clipping them to a boundary needs an engine and lives in
/// `HipparchusGEOS`.
public struct HexGridOptions: Sendable, Equatable {
    public var radius: Double
    /// Trim hexagons to the boundary. Off keeps whole hexagons wherever one touches,
    /// which reads as a grid laid *over* the map rather than cut out of it.
    public var clipToBoundary: Bool

    public init(radius: Double, clipToBoundary: Bool = true) {
        self.radius = radius
        self.clipToBoundary = clipToBoundary
    }
}

public enum HexGrid {

    /// Pointy-top hexagons covering `bounds`, with a ring of overlap so the grid
    /// runs past the edge rather than stopping short of it.
    ///
    /// Pointy-top, not flat-top: the vertex at 90° is what makes rows interlock at
    /// three quarters of the height, and it is the layout the Python draws.
    public static func hexagons(covering bounds: Bounds, radius: Double) -> [Polygon] {
        guard radius > 0, bounds.width.isFinite, bounds.height.isFinite else { return [] }

        // Width between neighbouring centres on a row, and the vertical step between
        // rows — three quarters of the full height, which is what interlocks them.
        let width = 3.0.squareRoot() * radius
        let verticalStep = 1.5 * radius

        // A guard against a radius so small relative to the area that the grid would
        // be millions of shapes nobody asked for.
        let estimated = (bounds.width / width + 2) * (bounds.height / verticalStep + 2)
        guard estimated.isFinite, estimated <= 200_000 else { return [] }

        var hexagons: [Polygon] = []
        var row = 0
        var y = bounds.minY - radius
        while y <= bounds.maxY + radius {
            // Every other row is offset by half a width; that is the interlock.
            let offset = row.isMultiple(of: 2) ? 0 : width / 2
            var x = bounds.minX - width + offset
            while x <= bounds.maxX + width {
                hexagons.append(hexagon(centre: Coordinate(x: x, y: y), radius: radius))
                x += width
            }
            y += verticalStep
            row += 1
        }
        return hexagons
    }

    public static func hexagon(centre: Coordinate, radius: Double) -> Polygon {
        let corners = (0..<6).map { step -> Coordinate in
            let angle = (60.0 * Double(step) - 30.0) * .pi / 180
            return Coordinate(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
        return Polygon(exterior: corners)
    }
}
