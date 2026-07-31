/// A point in whatever plane the surrounding geometry is in.
///
/// For geographic geometry `x` is longitude and `y` is latitude, the same order
/// GeoJSON and GEOS use. For grid-index geometry `x` is the column and `y` the
/// row — the one place the port has to be careful, because the contour tracer
/// works in `(row, column)` and everything downstream works in `(x, y)`.
public struct Coordinate: Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Geographic spelling of the same thing, so call sites read as what they mean.
    public init(lon: Double, lat: Double) {
        self.x = lon
        self.y = lat
    }

    public var lon: Double { x }
    public var lat: Double { y }

    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// An axis-aligned extent. Empty geometry has no bounds, hence the optionals
/// returned by `Geometry.bounds`.
public struct Bounds: Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public init?(_ coordinates: some Sequence<Coordinate>) {
        var minX = Double.infinity
        var minY = Double.infinity
        var maxX = -Double.infinity
        var maxY = -Double.infinity
        var seen = false
        for coordinate in coordinates where coordinate.isFinite {
            seen = true
            minX = Swift.min(minX, coordinate.x)
            minY = Swift.min(minY, coordinate.y)
            maxX = Swift.max(maxX, coordinate.x)
            maxY = Swift.max(maxY, coordinate.y)
        }
        guard seen else { return nil }
        self.init(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var center: Coordinate { Coordinate(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }

    /// Do two boxes overlap? Touching edges count, which is what label thinning
    /// wants: two labels sharing a boundary are still on top of each other.
    public func intersects(_ other: Bounds) -> Bool {
        !(maxX < other.minX || minX > other.maxX || maxY < other.minY || minY > other.maxY)
    }

    public func union(_ other: Bounds) -> Bounds {
        Bounds(
            minX: Swift.min(minX, other.minX),
            minY: Swift.min(minY, other.minY),
            maxX: Swift.max(maxX, other.maxX),
            maxY: Swift.max(maxY, other.maxY)
        )
    }

    public func contains(_ coordinate: Coordinate) -> Bool {
        coordinate.x >= minX && coordinate.x <= maxX && coordinate.y >= minY && coordinate.y <= maxY
    }
}

/// A geographic bounding box, in the order the whole app passes it around:
/// west, south, east, north.
public struct BoundingBox: Sendable, Hashable {
    public var minLon: Double
    public var minLat: Double
    public var maxLon: Double
    public var maxLat: Double

    public init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon
        self.minLat = minLat
        self.maxLon = maxLon
        self.maxLat = maxLat
    }

    /// From a centre point and a span, in degrees — the shape a live locator
    /// map reports after every pan and zoom, and MapKit's own region carries
    /// as `center`/`span`. Expressed in plain numbers rather than against
    /// MapKit's type, so this is testable without importing MapKit here, and
    /// so a locator is not the only thing that could ever produce one.
    ///
    /// Clamped to real coordinates rather than left to overflow: a locator
    /// that starts at world scale, or is zoomed out past it, can report a
    /// span wider than the world itself.
    public init(centerLat: Double, centerLon: Double, latSpan: Double, lonSpan: Double) {
        let halfLat = Swift.min(Swift.abs(latSpan), 180) / 2
        let halfLon = Swift.min(Swift.abs(lonSpan), 360) / 2
        self.minLat = Swift.max(centerLat - halfLat, -90)
        self.maxLat = Swift.min(centerLat + halfLat, 90)
        self.minLon = Swift.max(centerLon - halfLon, -180)
        self.maxLon = Swift.min(centerLon + halfLon, 180)
    }

    public var lonSpan: Double { maxLon - minLon }
    public var latSpan: Double { maxLat - minLat }
    public var bounds: Bounds {
        Bounds(minX: minLon, minY: minLat, maxX: maxLon, maxY: maxLat)
    }
}
