import Foundation

/// The marine layer of OpenStreetMap, which this application has been ignoring.
///
/// **No Python counterpart.** Neither codebase has ever asked Overpass for a
/// `seamark:*` tag, so every buoy, beacon, light, harbour and restricted area in
/// OSM has been invisible to both — on a coastal sheet drawn by an application
/// that ships a preset called `Coastal Survey`, a palette called `Admiralty` and
/// a style pack called `Nautical`.
///
/// The tags follow the S-57 object model, which is the same vocabulary the
/// official electronic charts use, so the reading below is a reading of a
/// published standard rather than of a folksonomy. `seamark:type` carries the
/// object class and the rest of the namespace carries its attributes:
///
///     seamark:type=buoy_lateral
///     seamark:buoy_lateral:category=port
///     seamark:buoy_lateral:colour=red
///     seamark:light:character=Fl
///     seamark:light:period=5
///
/// **Six layers, not sixty.** S-57 has well over a hundred object classes and a
/// sheet cannot carry a hundred layers a person is expected to reason about. The
/// grouping below is by what a reader does with the thing — a light is looked
/// for at night, a hazard is avoided, an area is a rule — rather than by the
/// standard's own taxonomy, which is organised for encoding and not for reading.
///
/// **Coverage is uneven and that is a fact about the data.** OSM's seamarks are
/// dense in Northern Europe and thin in the Eastern Mediterranean. A sheet drawn
/// from them is not a chart and must not be read as one; see the provenance the
/// features carry, which is `measured` — surveyed ground, community-maintained,
/// unvalidated — exactly as the rest of OSM is.
public enum Seamarks {

    /// The layer a `seamark:type` value lands in.
    ///
    /// Grouped by what the reader does with it:
    ///
    /// - **lights** are looked for, and carry a character and a period
    /// - **buoys** float and move with the tide
    /// - **beacons** are fixed to the ground
    /// - **hazards** are avoided
    /// - **harbours** are where a vessel goes
    /// - **areas** are rules rather than objects
    public static let lights = "seamark_lights"
    public static let buoys = "seamark_buoys"
    public static let beacons = "seamark_beacons"
    public static let hazards = "seamark_hazards"
    public static let harbours = "seamark_harbours"
    public static let areas = "seamark_areas"

    /// Every layer this produces, in the order they read on a chart: the rules
    /// underneath, then the places, then the things that are actually out there.
    public static let allLayers = [areas, harbours, hazards, beacons, buoys, lights]

    /// The OSM tag that says a feature is a seamark at all.
    public static let typeKey = "seamark:type"

    /// `seamark:type` values, by the layer they belong to.
    ///
    /// Prefix matches rather than an exhaustive list where the standard is open:
    /// `buoy_lateral`, `buoy_cardinal`, `buoy_safe_water` and the rest all begin
    /// `buoy_`, and a value this table has never heard of still belongs with the
    /// buoys. An exhaustive list would silently drop whatever OSM adds next.
    static let prefixes: [(prefix: String, layer: String)] = [
        ("buoy_", buoys),
        ("beacon_", beacons),
        ("light", lights),
        ("separation_", areas),
    ]

    /// Exact `seamark:type` values, for the ones that are not a family.
    static let exact: [String: String] = [
        // Lights. `landmark` is here rather than with the structures because in
        // OSM it is overwhelmingly a lighthouse: the tag is what a mariner takes
        // a bearing on.
        "landmark": lights,

        // Buoys and moorings. A mooring buoy floats and is picked up, which is
        // what puts it here rather than with the fixed marks.
        "mooring": buoys,

        // Fixed marks.
        "daymark": beacons,
        "pile": beacons,
        "cairn": beacons,
        "topmark": beacons,

        // Hazards.
        "wreck": hazards,
        "rock": hazards,
        "obstruction": hazards,
        "foul_ground": hazards,
        "cable_submarine": hazards,
        "pipeline_submarine": hazards,

        // Where a vessel goes.
        "harbour": harbours,
        "harbour_basin": harbours,
        "anchorage": harbours,
        "anchor_berth": harbours,
        "berth": harbours,
        "mooring_area": harbours,
        "pilot_boarding_place": harbours,
        "small_craft_facility": harbours,
        "distance_mark": harbours,

        // Rules drawn as ground.
        "restricted_area": areas,
        "caution_area": areas,
        "precautionary_area": areas,
        "military_area": areas,
        "cable_area": areas,
        "pipeline_area": areas,
        "dredged_area": areas,
        "fairway": areas,
        "navigation_line": areas,
        "recommended_track": areas,
        "deep_water_route": areas,
        "inshore_traffic_zone": areas,
    ]

    /// Which layer these tags belong to, or `nil` if they are not a seamark.
    ///
    /// A value the tables have never seen still lands in `seamark_areas` when it
    /// is plainly a seamark, because the alternative is dropping a charted
    /// object on the floor because OSM added a word. That is the same argument
    /// as the unstyled-layer fallback: showing something unexpected beats
    /// showing nothing and saying nothing.
    public static func layer(forType type: String) -> String? {
        let value = type.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return nil }

        if let known = exact[value] { return known }
        for (prefix, layer) in prefixes where value.hasPrefix(prefix) { return layer }
        return areas
    }

    /// The seamark layer for a set of OSM tags, or `nil` for anything else.
    public static func layer(forTags tags: [String: Any]) -> String? {
        guard let type = tags[typeKey] else { return nil }
        return layer(forType: (type as? String) ?? "\(type)")
    }
}
