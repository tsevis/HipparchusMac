import Foundation

/// Turn whatever a person actually has copied into an area.
///
/// Nobody has four numbers ready to type into four separate boxes. They have a
/// bounding box copied from this app's own `--bbox` output, two corners copied
/// from a spreadsheet, a single point copied off a map, or a map link with the
/// coordinates buried in its address bar. This reads whichever of those it can
/// find, rather than insisting on one — but it does not guess at prose: a
/// sentence that happens to contain numbers is not an area.
public enum CoordinateImport {

    /// A bare point has no stated extent. This much room on each side, in
    /// degrees of latitude, is enough to hold a town — the commonest thing a
    /// single coordinate names.
    public static let defaultPadDegrees = 0.05

    public static func parse(_ text: String) -> BoundingBox? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let point = pointFromMapLink(trimmed) {
            return padded(lat: point.lat, lon: point.lon)
        }

        let numbers = decimalNumbers(in: trimmed)
        switch numbers.count {
        case 4:
            return boundingBox(fromFour: numbers)
        case 2:
            guard let point = asLatLon(numbers[0], numbers[1]) else { return nil }
            return padded(lat: point.lat, lon: point.lon)
        default:
            // One number names nothing; three or more than four is prose that
            // happens to contain digits, not a coordinate someone meant to paste.
            return nil
        }
    }

    // MARK: - Four numbers

    /// Two readings are tried, because both are things a person plausibly
    /// pastes: this app's own `west, south, east, north` — the order `--bbox`
    /// and every saved session already use — and two corners, each written
    /// `lat, lon`, which is what copying two points off a map gives you.
    ///
    /// The native reading goes first, since it is what everywhere else in this
    /// app already means by four numbers; the corners reading catches what it
    /// cannot: either because the native reading is not a valid area, or
    /// because a value's own range rules the native reading out — a longitude
    /// beyond ±90 cannot be a latitude, whichever position it sits in.
    private static func boundingBox(fromFour numbers: [Double]) -> BoundingBox? {
        if let native = validArea(
            minLon: numbers[0], minLat: numbers[1], maxLon: numbers[2], maxLat: numbers[3]
        ) {
            return native
        }
        guard let first = asLatLon(numbers[0], numbers[1]),
              let second = asLatLon(numbers[2], numbers[3])
        else {
            return nil
        }
        return validArea(
            minLon: Swift.min(first.lon, second.lon), minLat: Swift.min(first.lat, second.lat),
            maxLon: Swift.max(first.lon, second.lon), maxLat: Swift.max(first.lat, second.lat)
        )
    }

    /// A real area: in range, and wide enough to draw — the same rule
    /// `Session.Area.bbox` already holds every saved area to.
    private static func validArea(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) -> BoundingBox? {
        guard minLon < maxLon, minLat < maxLat,
              (-180...180).contains(minLon), (-180...180).contains(maxLon),
              (-90...90).contains(minLat), (-90...90).contains(maxLat)
        else {
            return nil
        }
        return BoundingBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
    }

    // MARK: - A single point

    /// Which of two numbers is the latitude. A value outside ±90 cannot be
    /// one, whichever position it was written in; when both could be, this
    /// defaults to latitude-first — Google Maps, Apple Maps and every GPS
    /// device all give a copied point that way, and this is the one case
    /// where that convention, not this app's own, is what a person is holding.
    private static func asLatLon(_ a: Double, _ b: Double) -> (lat: Double, lon: Double)? {
        let aCouldBeLat = (-90...90).contains(a)
        let bCouldBeLat = (-90...90).contains(b)
        if aCouldBeLat, !bCouldBeLat, (-180...180).contains(b) { return (a, b) }
        if bCouldBeLat, !aCouldBeLat, (-180...180).contains(a) { return (b, a) }
        guard aCouldBeLat, bCouldBeLat, (-180...180).contains(a), (-180...180).contains(b) else {
            return nil
        }
        return (a, b)
    }

    private static func padded(lat: Double, lon: Double) -> BoundingBox {
        // Longitude is corrected for latitude, or a point near the poles pads
        // into a box far wider than it is tall.
        let cosine = Swift.max(0.02, cos(lat * .pi / 180))
        let lonPad = defaultPadDegrees / cosine
        return BoundingBox(
            minLon: Swift.max(lon - lonPad, -180), minLat: Swift.max(lat - defaultPadDegrees, -90),
            maxLon: Swift.min(lon + lonPad, 180), maxLat: Swift.min(lat + defaultPadDegrees, 90)
        )
    }

    // MARK: - A map link

    /// `@lat,lon` (Google Maps), `q=lat,lon` (Google Maps, and Apple Maps'
    /// generic search) or `ll=lat,lon` (Apple Maps). Tried as whole patterns
    /// before any bare-number extraction, because a Google Maps link also
    /// carries a zoom level as a bare number, which would otherwise be
    /// miscounted as a third coordinate.
    private static let mapLinkPatterns = [
        #"[@?&](?:q|ll)?=?(-?\d+\.\d+),(-?\d+\.\d+)"#,
    ]

    private static func pointFromMapLink(_ text: String) -> (lat: Double, lon: Double)? {
        for pattern in mapLinkPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let latRange = Range(match.range(at: 1), in: text),
                  let lonRange = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latRange]), let lon = Double(text[lonRange])
            else {
                continue
            }
            return (lat, lon)
        }
        return nil
    }

    /// Every signed decimal number in the text, in the order it appears.
    private static func decimalNumbers(in text: String) -> [Double] {
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return Double(text[matchRange])
        }
    }
}
