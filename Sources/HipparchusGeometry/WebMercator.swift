import Foundation

/// Slippy-tile Web Mercator, and the projection the renderer draws in.
///
/// Ported from `data_sources/terrain_tiles.py` (the tile maths) and
/// `geometry/projection.py` (the render projection).
///
/// **The bug this exists to prevent:** terrain tiles are Web Mercator, so the
/// rows of a tile are evenly spaced in mercator *y*, not in latitude. Mapping a
/// contour vertex back to lat/lon by interpolating linearly between the north and
/// south edges puts every contour slightly north of where it belongs, and worse
/// the further from the equator. Every vertex goes through
/// ``WebMercator/lonLatForPixel(x:y:zoom:)``, one at a time.
public enum WebMercator {
    /// Tile edge in pixels, for every provider in the slippy-tile scheme.
    public static let tilePixels = 256

    /// The latitude where Web Mercator runs out. Beyond it `tan(φ)` diverges.
    public static let maxLatitude = 85.05112878

    public static let earthRadiusMetres = 6_378_137.0

    /// World size in pixels at a zoom level.
    @inlinable
    public static func worldPixels(zoom: Int) -> Double {
        Double(1 << zoom) * Double(tilePixels)
    }

    /// The tile containing a coordinate, clamped to the world.
    public static func tile(lon: Double, lat: Double, zoom: Int) -> (x: Int, y: Int) {
        let n = 1 << zoom
        let clamped = Swift.min(Swift.max(lat, -maxLatitude), maxLatitude)
        let x = Int((lon + 180.0) / 360.0 * Double(n))
        let y = Int((1.0 - asinh(tan(clamped * .pi / 180.0)) / .pi) / 2.0 * Double(n))
        return (
            Swift.min(Swift.max(x, 0), n - 1),
            Swift.min(Swift.max(y, 0), n - 1)
        )
    }

    /// Fractional global pixel coordinates.
    ///
    /// `asinh(tan(φ))` rather than `ln(tan(π/4 + φ/2))`: the same function, but
    /// the form the tile schemes are specified in and one fewer chance to
    /// transcribe it wrong.
    public static func pixel(lon: Double, lat: Double, zoom: Int) -> (x: Double, y: Double) {
        let world = worldPixels(zoom: zoom)
        let clamped = Swift.min(Swift.max(lat, -maxLatitude), maxLatitude)
        let x = (lon + 180.0) / 360.0 * world
        let y = (1.0 - asinh(tan(clamped * .pi / 180.0)) / .pi) / 2.0 * world
        return (x, y)
    }

    /// The inverse. This is what keeps contours where they belong.
    public static func lonLatForPixel(x: Double, y: Double, zoom: Int) -> Coordinate {
        let world = worldPixels(zoom: zoom)
        let lon = x / world * 360.0 - 180.0
        let lat = atan(sinh(.pi * (1.0 - 2.0 * y / world))) * 180.0 / .pi
        return Coordinate(lon: lon, lat: lat)
    }

    /// How many metres of ground one pixel covers, at a latitude and zoom.
    ///
    /// Mercator is conformal, so this is the same in both directions and one
    /// number will do — but it shrinks with `cos(φ)`, and by a factor of two by
    /// the time you reach Iceland. Anything measuring the real world off a grid
    /// of tile pixels needs it: a slope in metres per pixel is not a slope until
    /// you say how wide a pixel is.
    public static func groundResolution(latitude: Double, zoom: Int) -> Double {
        let clamped = Swift.min(Swift.max(latitude, -maxLatitude), maxLatitude)
        return cos(clamped * .pi / 180.0) * 2.0 * .pi * earthRadiusMetres / worldPixels(zoom: zoom)
    }
}

/// How the scene's geometry is projected before it is drawn.
public enum ProjectionMode: String, Sendable, CaseIterable {
    /// Longitude and latitude used directly as x and y. Stretches away from the
    /// equator, but keeps exported coordinates readable as degrees.
    case wgs84Raw = "wgs84_raw"
    /// EPSG:3857. What web maps look like, and what the tiles are already in.
    case webMercator = "web_mercator"
    /// Equirectangular scaled by the cosine of the frame's own latitude, so a
    /// city-sized frame has no visible distortion at all.
    case localAzimuthal = "local_azimuthal"

    /// Unknown names fall back to Web Mercator rather than failing a render.
    public init(name: String) {
        self = ProjectionMode(rawValue: name) ?? .webMercator
    }
}

/// The projection a scene was built with.
///
/// Carried on the scene so a click on the canvas can be turned back into
/// longitude and latitude without guessing which projection produced the picture.
public struct ProjectionProfile: Sendable, Equatable {
    public let mode: ProjectionMode
    public let centerLon: Double
    public let centerLat: Double

    public init(mode: ProjectionMode = .webMercator, centerLon: Double = 0, centerLat: Double = 0) {
        self.mode = mode
        self.centerLon = centerLon
        self.centerLat = centerLat
    }

    public init(bbox: BoundingBox?, mode: ProjectionMode = .webMercator) {
        let center = bbox?.bounds.center ?? Coordinate(x: 0, y: 0)
        self.init(mode: mode, centerLon: center.x, centerLat: center.y)
    }

    public var sourceCRS: String { "EPSG:4326" }

    public var renderCRS: String {
        switch mode {
        case .wgs84Raw: return "EPSG:4326"
        case .webMercator: return "EPSG:3857"
        case .localAzimuthal: return "LOCAL_AZIMUTHAL_EQUIRECTANGULAR"
        }
    }

    public func project(_ coordinate: Coordinate) -> Coordinate {
        switch mode {
        case .wgs84Raw:
            return coordinate
        case .webMercator:
            let clamped = Swift.min(Swift.max(coordinate.lat, -WebMercator.maxLatitude), WebMercator.maxLatitude)
            let x = WebMercator.earthRadiusMetres * coordinate.lon * .pi / 180.0
            let y = WebMercator.earthRadiusMetres * log(tan(.pi / 4.0 + clamped * .pi / 360.0))
            return Coordinate(x: x, y: y)
        case .localAzimuthal:
            let scale = cos(centerLat * .pi / 180.0)
            let x = (coordinate.lon - centerLon) * scale * .pi / 180.0 * WebMercator.earthRadiusMetres
            let y = (coordinate.lat - centerLat) * .pi / 180.0 * WebMercator.earthRadiusMetres
            return Coordinate(x: x, y: y)
        }
    }

    public func unproject(_ point: Coordinate) -> Coordinate {
        switch mode {
        case .wgs84Raw:
            return point
        case .webMercator:
            let lon = point.x / WebMercator.earthRadiusMetres * 180.0 / .pi
            let lat = (2.0 * atan(exp(point.y / WebMercator.earthRadiusMetres)) - .pi / 2.0) * 180.0 / .pi
            return Coordinate(lon: lon, lat: lat)
        case .localAzimuthal:
            let scale = cos(centerLat * .pi / 180.0)
            let lon = point.x / (WebMercator.earthRadiusMetres * scale) * 180.0 / .pi + centerLon
            let lat = point.y / WebMercator.earthRadiusMetres * 180.0 / .pi + centerLat
            return Coordinate(lon: lon, lat: lat)
        }
    }

    public func project(_ geometry: Geometry) -> Geometry {
        geometry.mapCoordinates(project)
    }

    public func project(_ bbox: BoundingBox) -> Bounds {
        // All four corners, not just two: the projection is not axis-preserving
        // in every mode, and a min/max of the corners is what actually bounds it.
        let corners = [
            Coordinate(lon: bbox.minLon, lat: bbox.minLat),
            Coordinate(lon: bbox.maxLon, lat: bbox.minLat),
            Coordinate(lon: bbox.maxLon, lat: bbox.maxLat),
            Coordinate(lon: bbox.minLon, lat: bbox.maxLat),
        ].map(project)
        return Bounds(corners)!
    }

    /// What goes into the scene metadata and the exported diagnostics.
    public func metadata(bbox: BoundingBox?) -> [String: String] {
        var result = [
            "mode": mode.rawValue,
            "source_crs": sourceCRS,
            "render_crs": renderCRS,
            "center_lon": String(centerLon),
            "center_lat": String(centerLat),
        ]
        if let bbox {
            let bounds = project(bbox)
            result["projected_bounds"] = "\(bounds.minX),\(bounds.minY),\(bounds.maxX),\(bounds.maxY)"
        }
        return result
    }
}

/// Round `range / targetLines` to the nearest 1/2/5 × 10ⁿ step.
///
/// Ported from `simulated_field.nice_interval`. Contour intervals are read off a
/// map, so they have to be numbers a person would write down: 5 m, 20 m, 100 m.
/// Never 23.7 m.
///
/// The nearest candidate is chosen **geometrically** — smallest
/// `|log(candidate / raw)|` — not by absolute difference. Linear nearest would
/// pull towards the larger candidate every time and halve the line count.
///
/// A fixed interval is not an option: it empties a small window and floods a
/// large one, so the interval has to come from the relief actually in view.
public func niceInterval(range: Double, targetLines: Int = 44) -> Double {
    guard range.isFinite, range > 0, targetLines > 0 else { return 1.0 }
    let raw = range / Double(targetLines)
    let exponent = (log10(raw)).rounded(.down)
    let candidates = [1.0, 2.0, 5.0, 10.0].map { $0 * pow(10.0, exponent) }
    return candidates.min { abs(log($0 / raw)) < abs(log($1 / raw)) }!
}
