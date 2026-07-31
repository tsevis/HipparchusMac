import Foundation
import HipparchusGeometry

/// A real place, found by name, from OpenStreetMap's own geocoder.
///
/// MapKit's local search is a places-and-businesses index — asked for "Lesvos"
/// it can answer with a taverna in Athens called "Ouzeri Lesvos", because that
/// is what its index actually contains a great deal of. Nominatim indexes OSM's
/// own boundary polygons, so the same query comes back as the island, correctly
/// sized. `isBoundary` is the signal MapKit's own results do not carry: whether
/// this is a real administrative or geographic area rather than a business or
/// address that merely shares its name.
public struct GeocodedPlace: Sendable, Equatable, Identifiable {
    public let name: String
    /// "Aegean, Greece" — enough to tell two places of the same name apart.
    public let detail: String
    public let bbox: BoundingBox
    public let isBoundary: Bool

    public var id: String {
        "\(name)|\(bbox.minLon),\(bbox.minLat),\(bbox.maxLon),\(bbox.maxLat)"
    }

    public init(name: String, detail: String, bbox: BoundingBox, isBoundary: Bool) {
        self.name = name
        self.detail = detail
        self.bbox = bbox
        self.isBoundary = isBoundary
    }
}

public struct NominatimSettings: Sendable {
    public var endpoint = "https://nominatim.openstreetmap.org/search"
    public var maxResults = 5
    public var requestsPerSecond = 1.0
    public var timeoutSeconds: TimeInterval = 10

    public init() {}
}

public struct NominatimGeocodeError: Error, CustomStringConvertible {
    public let underlying: String
    public var description: String { "Nominatim search failed: \(underlying)" }
}

/// Resolves a place name to a real geographic extent.
///
/// No key, no account — the same property MapKit's search was chosen for — but
/// the service asks in return for an identifying User-Agent (`URLSessionFetcher`
/// already sends one) and at most one request a second, which is what
/// `RateLimiter` enforces across every call made on one instance. Hold on to one
/// instance for the app's lifetime rather than making a fresh one per search, or
/// the limiter resets and enforces nothing.
public struct NominatimGeocoder: Sendable {
    public let settings: NominatimSettings
    private let http: any HTTPFetching
    private let limiter: RateLimiter

    public init(settings: NominatimSettings = NominatimSettings(), http: any HTTPFetching = URLSessionFetcher()) {
        self.settings = settings
        self.http = http
        self.limiter = RateLimiter(requestsPerSecond: settings.requestsPerSecond)
    }

    public func search(_ query: String) async throws -> [GeocodedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        guard let url = requestURL(for: trimmed) else {
            throw NominatimGeocodeError(underlying: "could not build the request URL")
        }

        await limiter.waitTurn()
        let data: Data
        do {
            data = try await http.data(from: url, timeout: settings.timeoutSeconds)
        } catch {
            throw NominatimGeocodeError(underlying: String(describing: error))
        }

        // An outage page or a proxy notice reads as no results, the same
        // tolerance every other provider here gives a response it cannot parse.
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap(Self.place(from:))
    }

    func requestURL(for query: String) -> URL? {
        var components = URLComponents(string: settings.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "limit", value: String(settings.maxResults)),
            // Otherwise a Greek island comes back named in Greek script, which is
            // correct and useless to someone who typed it in the Latin alphabet.
            URLQueryItem(name: "accept-language", value: "en"),
        ]
        return components?.url
    }

    /// The categories Nominatim uses for a real administrative or geographic
    /// area rather than a point of interest. `place` is what covers an island —
    /// most have no drawn administrative boundary at all, only a point tagged
    /// `place=island`, so restricting this to `boundary` alone would miss them.
    static let boundaryCategories: Set<String> = ["boundary", "place"]

    static func place(from entry: [String: Any]) -> GeocodedPlace? {
        guard let bbox = boundingBox(from: entry) else { return nil }

        let displayName = (entry["display_name"] as? String) ?? ""
        let name = (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? displayName.split(separator: ",").first.map(String.init)
            ?? "Unnamed place"
        let category = (entry["category"] as? String) ?? ""

        return GeocodedPlace(
            name: name,
            detail: detail(displayName, excluding: name),
            bbox: bbox,
            isBoundary: boundaryCategories.contains(category)
        )
    }

    /// Nominatim's own order is `[south, north, west, east]` — not the order
    /// this app's `BoundingBox` uses. Getting this swap wrong silently answers a
    /// query with a box for somewhere else.
    private static func boundingBox(from entry: [String: Any]) -> BoundingBox? {
        guard let raw = entry["boundingbox"] as? [String], raw.count == 4,
              let minLat = Double(raw[0]), let maxLat = Double(raw[1]),
              let minLon = Double(raw[2]), let maxLon = Double(raw[3])
        else {
            return nil
        }
        // A bare point has no span at all; padded rather than left degenerate, or
        // a caller downstream cannot draw a frame around it.
        let padding = 0.001
        return BoundingBox(
            minLon: minLon, minLat: minLat,
            maxLon: maxLon > minLon ? maxLon : minLon + padding,
            maxLat: maxLat > minLat ? maxLat : minLat + padding
        )
    }

    /// "Aegean, Greece" out of "Lesbos, Aegean, Greece" — the parts after the name.
    private static func detail(_ displayName: String, excluding name: String) -> String {
        var parts = displayName.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == name { parts.removeFirst() }
        return parts.joined(separator: ", ")
    }
}
