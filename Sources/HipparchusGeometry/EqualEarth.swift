import Foundation

/// The Equal Earth projection, and the rule for when a frame has outgrown a flat
/// one.
///
/// Nothing here is needed by a city sheet, which is why it did not exist until a
/// world sheet did. The three projections this app had were all written for a
/// frame small enough that the Earth's curvature does not show: Web Mercator is
/// what the tiles arrive in, and `localAzimuthal` is an equirectangular scaled by
/// the cosine of the frame's own latitude, which is exact at the centre and very
/// nearly exact a few degrees either side of it. Asked for a continent, both
/// stop being approximations and start being wrong — Mercator gives Greenland
/// the area of Africa, and the local scaling stretches every east–west distance
/// at the top of the frame by the ratio of two cosines.
///
/// Equal Earth (Šavrič, Patterson and Jenny, 2018) is the pseudocylindrical
/// compromise those authors designed to replace the Gall–Peters argument: equal
/// area exactly, at shapes a reader will accept. The coefficients below are
/// theirs, and `EqualEarthTests` checks the equal-area property against the true
/// spherical area of a graticule cell rather than against a table of numbers
/// copied from the paper, so a transcription error in the constants fails the
/// test rather than passing it.
public enum EqualEarth {

    /// From the paper. A polynomial in the parametric latitude θ, fitted so that
    /// the projection is exactly equal-area and the poles are lines rather than
    /// points.
    static let a1 = 1.340264
    static let a2 = -0.081106
    static let a3 = 0.000893
    static let a4 = 0.003796
    /// sin of the parametric latitude is `m` times sin of the true latitude.
    static let m = (3.0).squareRoot() / 2

    /// dy/dθ. Appears in the forward projection's x, and again as the derivative
    /// Newton's method needs to invert y.
    static func derivative(_ theta: Double) -> Double {
        let squared = theta * theta
        return a1 + 3 * a2 * squared + 7 * a3 * pow(theta, 6) + 9 * a4 * pow(theta, 8)
    }

    static func northing(_ theta: Double) -> Double {
        a1 * theta + a2 * pow(theta, 3) + a3 * pow(theta, 7) + a4 * pow(theta, 9)
    }

    /// Longitude and latitude in degrees, relative to a central meridian, to
    /// metres on a sphere.
    public static func project(
        lon: Double, lat: Double, centralMeridian: Double, radius: Double
    ) -> (x: Double, y: Double) {
        let radians = Double.pi / 180
        // Clamped because `asin` has no answer outside its domain and floating
        // point puts sin(90°) fractionally over it. A latitude past the pole is
        // not a coordinate this has to be polite about.
        let sine = min(max(sin(lat * radians) * m, -1), 1)
        let theta = asin(sine)
        let x = (lon - centralMeridian) * radians * cos(theta) / (m * derivative(theta))
        return (x * radius, northing(theta) * radius)
    }

    /// The inverse, by Newton's method on y.
    ///
    /// The polynomial is monotonic in θ over the whole range, so this converges
    /// from θ = y in a handful of steps for every point on Earth; the iteration
    /// cap is a guard against a non-finite input, not a real limit. It matters
    /// that this exists at all: the canvas turns a click back into a latitude and
    /// longitude through it, so a projection without an inverse would be a map
    /// that cannot be clicked.
    public static func unproject(
        x: Double, y: Double, centralMeridian: Double, radius: Double
    ) -> (lon: Double, lat: Double) {
        let degrees = 180 / Double.pi
        let northing = y / radius
        var theta = northing
        for _ in 0..<12 {
            let delta = (Self.northing(theta) - northing) / derivative(theta)
            theta -= delta
            if abs(delta) < 1e-12 { break }
        }
        let sine = min(max(sin(theta) / m, -1), 1)
        let lat = asin(sine) * degrees
        let cosine = cos(theta)
        // Only reachable exactly at a pole, where every longitude is the same
        // place and the central meridian is as good an answer as any.
        guard abs(cosine) > 1e-12 else { return (centralMeridian, lat) }
        let lon = (x / radius) * m * derivative(theta) / cosine * degrees + centralMeridian
        return (lon, lat)
    }
}

extension ProjectionMode {

    /// How far the meridians may converge across a frame before a flat
    /// projection is no longer telling the truth about it.
    ///
    /// Both of the small-frame projections scale east–west by a single cosine:
    /// `localAzimuthal` by the cosine of the frame's centre, Web Mercator by
    /// stretching north–south with the secant of each latitude. Either way the
    /// error across a frame is the ratio between the cosine at its centre and
    /// the cosine at its furthest edge, and this is how far that ratio may fall
    /// from 1.
    ///
    /// 0.12 is where the worked examples land either side of the line. Santorini
    /// is 0.002 and Greece 0.05, so an island and a small country keep the
    /// projection written for them. France is 0.086 and keeps it too. Europe is
    /// 0.49, the contiguous United States 0.18 and the whole world 0.91: those
    /// are frames where a reader would see the stretch without being told to
    /// look for it.
    static let convergenceTolerance = 0.12

    /// The projection this frame should actually be drawn in.
    ///
    /// An improvement, not an override: `wgs84Raw` means "give me degrees" and is
    /// left alone, and a frame small enough for the projection it asked for keeps
    /// it. Only a frame that has outgrown its projection is moved, and it is
    /// moved to the one projection here that has no size at which it stops
    /// working.
    ///
    /// Deliberately applied to previews as well as exports. The two tiers differ in how
    /// much work they spend, not in what the map is, and a preview that cannot be
    /// trusted to show the shape of the exported sheet is not a preview.
    public func honest(for bbox: BoundingBox?) -> ProjectionMode {
        guard let bbox, self == .webMercator || self == .localAzimuthal else { return self }
        let radians = Double.pi / 180
        let centre = (bbox.minLat + bbox.maxLat) / 2
        let edge = max(abs(bbox.minLat), abs(bbox.maxLat))
        let centreCosine = cos(centre * radians)
        guard centreCosine > 1e-9 else { return .equalEarth }
        let ratio = cos(min(edge, 90) * radians) / centreCosine
        return abs(1 - ratio) > Self.convergenceTolerance ? .equalEarth : self
    }
}
