import HipparchusGeometry

/// Combine two geocoders into one list of candidates.
///
/// Neither source alone is enough. Nominatim knows real boundaries but not every
/// landmark or business a person might type; MapKit knows landmarks and
/// businesses well but has no reliable way to tell a place apart from anything
/// that merely shares its name. Merged, a real boundary reads first and a decoy
/// cannot bury it — but two genuinely different places that happen to share a
/// name must both survive, which is why the rule below dedupes on name *and*
/// distance together, never one alone.
public enum PlaceSearchMerge {

    /// Two results close enough, in degrees, to plausibly be the same place.
    /// Generous on purpose: Nominatim and MapKit centre a large area like an
    /// island slightly differently, and this only has to be tight enough to
    /// keep two same-named places on opposite sides of a country apart.
    static let sameNameProximityDegrees = 0.5

    public static func merge(
        nominatim: [GeocodedPlace],
        mapKit: [GeocodedPlace],
        limit: Int = 8
    ) -> [GeocodedPlace] {
        // Boundary matches first — they answer "a map of this place" reliably —
        // then everything else in the order each source returned it.
        let ranked = nominatim.filter(\.isBoundary) + nominatim.filter { !$0.isBoundary } + mapKit

        var accepted: [GeocodedPlace] = []
        for candidate in ranked {
            guard accepted.count < limit else { break }
            guard !accepted.contains(where: { isSamePlace($0, candidate) }) else { continue }
            accepted.append(candidate)
        }
        return accepted
    }

    private static func isSamePlace(_ a: GeocodedPlace, _ b: GeocodedPlace) -> Bool {
        normalized(a.name) == normalized(b.name) && centresAreClose(a.bbox, b.bbox)
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private static func centresAreClose(_ a: BoundingBox, _ b: BoundingBox) -> Bool {
        let ax = (a.minLon + a.maxLon) / 2, ay = (a.minLat + a.maxLat) / 2
        let bx = (b.minLon + b.maxLon) / 2, by = (b.minLat + b.maxLat) / 2
        return abs(ax - bx) < sameNameProximityDegrees && abs(ay - by) < sameNameProximityDegrees
    }
}
