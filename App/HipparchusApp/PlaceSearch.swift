import HipparchusGeometry
import MapKit

/// Find an area by name instead of by four numbers.
///
/// Typing "Santorini" is how anyone actually starts a map. The coordinate boxes stay
/// — they are how you say *exactly* which frame you want — but they are a poor way
/// to begin, and the design puts them one disclosure away for that reason.
///
/// Uses MapKit's own search rather than a geocoding API: no key, no account, and it
/// is already linked for the locator.
struct PlaceSearch: Sendable {

    /// One place the search found, with the frame it suggests.
    struct Result: Identifiable, Sendable, Equatable {
        let id = UUID()
        let name: String
        /// Where it is, spelled out — "Santorini, Greece" rather than "Santorini",
        /// because a list of five identical names is not a choice.
        let detail: String
        let bbox: BoundingBox

        static func == (lhs: Result, rhs: Result) -> Bool { lhs.id == rhs.id }
    }

    /// A place with no stated extent. Big enough to hold a town, which is the
    /// commonest thing to search for and the size a map of one wants.
    static let defaultRadiusMetres = 6_000.0

    /// The least anything gets. A place search asks for a *map*, and MapKit's own
    /// extent is sometimes far too tight to be one: it answers "Everest" with a
    /// 141-metre radius, which frames a patch of rock rather than a mountain.
    static let minimumRadiusMetres = 2_000.0

    /// The most anything gets: searching for a country should frame the country,
    /// not ask Overpass for a continent.
    static let maximumRadiusMetres = 120_000.0

    func search(_ query: String) async throws -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Addresses and points of interest both; a search for "Everest" should find
        // the mountain, and one for "Syntagma" the square.
        request.resultTypes = [.address, .pointOfInterest]

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.prefix(8).compactMap {
            Self.result(for: $0, within: response.boundingRegion)
        }
    }

    static func result(for item: MKMapItem, within response: MKCoordinateRegion?) -> Result? {
        let placemark = item.placemark
        let centre = placemark.coordinate
        guard CLLocationCoordinate2DIsValid(centre) else { return nil }

        let name = item.name ?? placemark.name ?? "Unnamed place"
        return Result(
            name: name,
            detail: Self.detail(for: placemark, excluding: name),
            bbox: Self.bbox(centre: centre, radiusMetres: Self.radius(for: placemark, within: response))
        )
    }

    /// How wide a frame this place wants.
    ///
    /// A placemark's own region wins whenever it has one: it describes *this* place,
    /// where the region covering the whole response describes all of them, and using
    /// that would frame a single café in San Francisco as the whole of San Francisco
    /// because a second café matched across town.
    ///
    /// The region covering the response is the fallback for a placemark with no
    /// extent at all, which is how a mountain arrives — and it is the difference
    /// between framing Everest and framing a patch of rock. The floor catches what
    /// is left: MapKit answers some landmarks with a 141-metre radius.
    static func radius(for placemark: CLPlacemark, within response: MKCoordinateRegion?) -> Double {
        if let stated = (placemark.region as? CLCircularRegion)?.radius, stated > 0 {
            return stated
        }
        guard let region = response else { return defaultRadiusMetres }

        // Half the span, in metres, taking the longer side.
        let latitude = region.span.latitudeDelta * 111_320.0
        let cosine = Swift.max(0.02, cos(region.center.latitude * .pi / 180))
        let longitude = region.span.longitudeDelta * 111_320.0 * cosine
        let spanned = Swift.max(latitude, longitude) / 2

        return spanned > 0 ? spanned : defaultRadiusMetres
    }

    /// "Thira, Greece" — enough to tell two places of the same name apart.
    static func detail(for placemark: CLPlacemark, excluding name: String) -> String {
        [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .filter { $0 != name }
            .reduce(into: [String]()) { result, part in
                if !result.contains(part) { result.append(part) }
            }
            .joined(separator: ", ")
    }

    /// A square frame around a point, in degrees.
    ///
    /// Longitude is corrected for latitude, or a search for Reykjavík would frame
    /// something twice as wide as it is tall.
    static func bbox(centre: CLLocationCoordinate2D, radiusMetres: Double) -> BoundingBox {
        let radius = Swift.min(Swift.max(radiusMetres, minimumRadiusMetres), maximumRadiusMetres)

        let latitudeDegrees = radius / 111_320.0
        let cosine = Swift.max(0.02, cos(centre.latitude * .pi / 180))
        let longitudeDegrees = radius / (111_320.0 * cosine)

        return BoundingBox(
            minLon: Swift.max(centre.longitude - longitudeDegrees, -180),
            minLat: Swift.max(centre.latitude - latitudeDegrees, -90),
            maxLon: Swift.min(centre.longitude + longitudeDegrees, 180),
            maxLat: Swift.min(centre.latitude + latitudeDegrees, 90)
        )
    }
}
