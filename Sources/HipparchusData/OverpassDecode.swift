import Foundation
import HipparchusGeometry

/// Turn an Overpass JSON payload into layer-separated features.
///
/// Ported from `data_sources/overpass_geojson.py`.
///
/// Overpass answers with a flat list of elements carrying OSM tags; the layers this
/// app draws are a reading of those tags. That reading is the whole of this file,
/// and its order matters: a park that is also tagged `landuse` must land in `parks`,
/// not in the generic `landuse` bucket, so the specific tests come first.
public enum OverpassDecode {

    /// Every layer the decoder can produce, whether or not anything landed in it.
    ///
    /// Empty layers are kept so the layer panel can say "none here" rather than
    /// silently omitting a layer that was asked for and genuinely had nothing —
    /// an empty map should explain itself.
    ///
    /// **Not the same list as `OverpassQuery.supportedLayers`**, and that is new:
    /// what can be *asked for* and what can be *produced* used to be one list.
    /// Seamarks are one request — a single clause on `seamark:type` answers for
    /// all of them — and six layers, because a buoy and a restricted area are
    /// not one thing to a reader even though they are one query.
    public static let layers = OverpassQuery.supportedLayers.flatMap { requested in
        requested == OverpassQuery.seamarks ? Seamarks.allLayers : [requested]
    }

    public static func featureCollection(
        from data: Data,
        bbox: BoundingBox? = nil
    ) throws -> FeatureCollection {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OverpassDecodeError.notAnObject
        }
        return featureCollection(from: payload, bbox: bbox)
    }

    public static func featureCollection(
        from payload: [String: Any],
        bbox: BoundingBox? = nil
    ) -> FeatureCollection {
        let elements = payload["elements"] as? [[String: Any]] ?? []

        var featuresByLayer: [String: [Feature]] = [:]
        for layer in layers { featuresByLayer[layer] = [] }

        for element in elements {
            let tags = element["tags"] as? [String: Any] ?? [:]
            guard let layer = classify(tags: tags) else { continue }
            guard let geometry = geometry(for: element, tags: tags) else { continue }

            let type = element["type"] as? String ?? "element"
            let identifier = element["id"].map { "\($0)" } ?? "unknown"

            featuresByLayer[layer, default: []].append(Feature(
                id: "\(type)/\(identifier)",
                layer: layer,
                source: "overpass",
                geometry: geometry,
                // OSM is surveyed ground, whatever the pipe that carried it here.
                provenance: .measured,
                properties: properties(from: tags)
            ))
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string("overpass"),
                "raw_element_count": .int(elements.count),
            ],
            bbox: bbox,
            provenance: .measured
        )
    }

    // MARK: - Classification

    /// Which layer a set of OSM tags belongs to, or `nil` for something we do not
    /// draw. Order is significant: the first match wins.
    static func classify(tags: [String: Any]) -> String? {
        func tag(_ key: String) -> String {
            (tags[key] as? String) ?? (tags[key].map { "\($0)" } ?? "")
        }

        // Transport and structures are unambiguous, and cheap to decide.
        if tags["railway"] != nil { return "railways" }
        if tags["highway"] != nil { return "roads" }
        if tags["building"] != nil { return "buildings" }

        // Named shops and amenities are worth labelling, so they get their own
        // layers before the generic land-cover tests can claim them.
        if tags["shop"] != nil { return "shops" }
        if tags["amenity"] != nil { return "amenities" }

        let natural = tag("natural")
        let landuse = tag("landuse")
        let leisure = tag("leisure")
        let place = tag("place")
        let name = tag("name")

        if natural == "coastline" { return "coastline" }
        if place == "sea" || place == "ocean" { return "coastline" }

        // Before the generic tests, and this is the whole reason seamarks were
        // worth a file of their own. A lighthouse is `seamark:type=light_major`
        // *and* `man_made=lighthouse` *and* named; a marina is a seamark and a
        // `leisure` facility; a wreck is a seamark and `historic`. Every one of
        // them would be claimed by the named-place test below, and the chart
        // layers would come back empty from a fetch that looked like it worked.
        //
        // After the coastline, though: a coastline way carrying a seamark tag is
        // still the shape of the land, and it is the only thing on the sheet
        // that the sea inference reads.
        if let seamark = Seamarks.layer(forTags: tags) { return seamark }

        // A shipping lane is not a body of water, and this has to be asked *before*
        // the water tests: OSM tags the Piraeus–Serifos ferry `waterway=seaway`, and
        // any rule keyed on the presence of a `waterway` tag would otherwise draw an
        // 80-kilometre ferry crossing as if it were a river.
        //
        // A deliberate divergence from the Python, which reads the same tag the same
        // way and puts the route in `water`. Narrow on purpose: streams, canals,
        // rivers, ditches and drains are watercourses and stay where they were.
        if isRoute(tags: tags) { return "ferry_routes" }

        if natural == "water" || tags["waterway"] != nil || tags["water"] != nil { return "water" }
        if landuse == "reservoir" || landuse == "basin" { return "water" }

        if !place.isEmpty { return "places" }
        if !name.isEmpty { return "places" }

        if ["park", "garden", "nature_reserve", "playground", "sports_centre", "pitch"].contains(leisure) {
            return "parks"
        }
        if ["grass", "recreation_ground", "village_green", "park", "allotments"].contains(landuse) {
            return "parks"
        }

        if landuse == "forest" || natural == "wood" || natural == "tree_row" { return "forests" }

        if ["farmland", "meadow", "orchard", "vineyard", "farmyard", "greenhouse_horticulture"]
            .contains(landuse) {
            return "fields"
        }

        if ["beach", "cliff", "scrub", "heath", "wetland", "grassland", "fell", "moor"].contains(natural) {
            return "natural"
        }
        if landuse == "brownfield" || landuse == "quarry" { return "natural" }

        if !tag("barrier").isEmpty { return "barriers" }
        if !tag("power").isEmpty { return "power" }
        if !landuse.isEmpty { return "landuse" }

        return nil
    }

    /// A way across water that is a *route*, not water.
    ///
    /// `route=ferry` is the definitive tag. `seaway` and `fairway` are the two
    /// `waterway` values that mark navigation rather than a watercourse — they say
    /// where vessels go, the way a shipping lane on a chart does.
    static func isRoute(tags: [String: Any]) -> Bool {
        if (tags["route"] as? String) == "ferry" { return true }
        if let waterway = tags["waterway"] as? String {
            return waterway == "seaway" || waterway == "fairway"
        }
        return false
    }

    // MARK: - Geometry

    static func geometry(for element: [String: Any], tags: [String: Any]) -> Geometry? {
        if element["type"] as? String == "node",
           let lon = element["lon"] as? Double, let lat = element["lat"] as? Double {
            return .point(Coordinate(lon: lon, lat: lat))
        }

        if element["type"] as? String == "relation" {
            return relationGeometry(element, tags: tags)
        }

        // `out geom` attaches the resolved vertices to each way; without it a way is
        // only a list of node ids and nothing here could draw it.
        let nodes = (element["geometry"] as? [[String: Any]]) ?? (element["nodes"] as? [[String: Any]])
        guard let nodes else { return nil }

        let coordinates = nodes.compactMap { node -> Coordinate? in
            guard let lon = node["lon"] as? Double, let lat = node["lat"] as? Double else { return nil }
            return Coordinate(lon: lon, lat: lat)
        }
        guard coordinates.count >= 2 else { return nil }

        // A closed way is only an area if its tags say it encloses something. A
        // roundabout is a closed way and is emphatically not a polygon.
        if isClosedRing(coordinates), canBePolygon(tags: tags) {
            return .polygon(Polygon(exterior: coordinates))
        }
        return .lineString(LineString(coordinates))
    }

    /// Assemble a relation's member ways into a polygon.
    ///
    /// A relation is a *list of ways*, in arbitrary order and arbitrary direction,
    /// and `out geom` resolves each member's vertices without joining any of them
    /// up. Until they are stitched there is no ring, and until there is a ring there
    /// is no area — which is why relations used to be dropped outright, taking 1 097
    /// features out of an Athens fetch, most of them buildings with courtyards.
    ///
    /// Members with no role count as outer. That is what the OSM data model says,
    /// and a relation whose roles were never filled in is common enough that
    /// treating a blank as "not outer" would lose real shapes.
    static func relationGeometry(_ element: [String: Any], tags: [String: Any]) -> Geometry? {
        guard let members = element["members"] as? [[String: Any]] else { return nil }

        var outerFragments: [[Coordinate]] = []
        var innerFragments: [[Coordinate]] = []

        for member in members {
            guard member["type"] as? String == "way",
                  let nodes = member["geometry"] as? [[String: Any]]
            else {
                continue
            }
            let coordinates = nodes.compactMap { node -> Coordinate? in
                guard let lon = node["lon"] as? Double, let lat = node["lat"] as? Double else {
                    return nil
                }
                return Coordinate(lon: lon, lat: lat)
            }
            guard coordinates.count >= 2 else { continue }

            switch member["role"] as? String ?? "" {
            case "inner": innerFragments.append(coordinates)
            case "outer", "": outerFragments.append(coordinates)
            default: continue
            }
        }

        let outer = RingAssembly.rings(from: outerFragments)
        let inner = RingAssembly.rings(from: innerFragments)
        let polygons = RingAssembly.polygons(outer: outer.rings, inner: inner.rings)

        if !polygons.isEmpty {
            return Geometry.polygons(polygons)
        }

        // Nothing closed. Rather than drop the feature, keep what the relation
        // does describe — a set of lines — so a broken multipolygon still draws
        // its edges instead of vanishing. Only an area style would have filled it,
        // and an open line is never filled.
        let lines = (outer.unclosed + inner.unclosed)
            .filter { $0.count >= 2 }
            .map { LineString($0) }
        guard !lines.isEmpty else { return nil }
        return lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines)
    }

    static func isClosedRing(_ coordinates: [Coordinate]) -> Bool {
        guard coordinates.count >= 4, let first = coordinates.first, let last = coordinates.last else {
            return false
        }
        return first == last
    }

    static func canBePolygon(tags: [String: Any]) -> Bool {
        ["building", "landuse", "leisure", "natural", "water", "area"].contains { tags[$0] != nil }
    }

    // MARK: - Properties

    /// OSM tags are strings; keep them as strings rather than guessing at numbers.
    /// The one exception is `name`, which everything downstream reads.
    static func properties(from tags: [String: Any]) -> [String: PropertyValue] {
        var properties: [String: PropertyValue] = [:]
        for (key, value) in tags {
            if let text = value as? String {
                properties[key] = .string(text)
            } else if let number = value as? Int {
                properties[key] = .int(number)
            } else if let number = value as? Double {
                properties[key] = .double(number)
            } else {
                properties[key] = .string("\(value)")
            }
        }
        return properties
    }
}

public enum OverpassDecodeError: Error, CustomStringConvertible {
    case notAnObject

    public var description: String {
        switch self {
        case .notAnObject: "the Overpass response was not a JSON object"
        }
    }
}
