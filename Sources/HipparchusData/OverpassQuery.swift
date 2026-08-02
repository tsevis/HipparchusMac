import Foundation

/// Build Overpass QL queries for bbox requests.
///
/// Ported from `data_sources/overpass_query.py`.
///
/// Overpass dominates fetch time — a 0.32° area with every layer took 331 s in the
/// Python, of which 325 s was this one source and 5 s was elevation. Asking for
/// fewer layers is the only lever that matters, which is why the query is built from
/// the layers actually requested rather than always asking for everything.
public enum OverpassQuery {

    /// One request, six layers. The marine namespace is a single tag key, so
    /// asking for `seamark:type` once answers for buoys, beacons, lights,
    /// hazards, harbours and areas together — six clauses would be six copies of
    /// the same query. `Seamarks` does the sorting afterwards.
    public static let seamarks = "seamarks"

    /// The layers this provider knows how to ask for, in the order the query lists
    /// them.
    ///
    /// A *request* name, which since seamarks is no longer the same thing as a
    /// layer the decoder emits — see `OverpassDecode.layers`.
    public static let supportedLayers = [
        "roads", "buildings", "water", "parks", "railways",
        "forests", "fields", "natural", "coastline", "places",
        "shops", "amenities", "landuse", "barriers", "power",
        "ferry_routes", seamarks,
    ]

    /// One layer's Overpass clauses. `{bbox}` is substituted with `s,w,n,e`.
    ///
    /// Note the order: Overpass bbox filters are `south,west,north,east` — latitude
    /// first. This is the same trap as WMS 1.3.0 with EPSG:4326 (kickoff detail 1),
    /// and getting it backwards returns a valid map of somewhere else rather than an
    /// error.
    static let clauses: [String: [String]] = [
        "roads": [
            #"way["highway"]({bbox});"#,
        ],
        "buildings": [
            #"way["building"]({bbox});"#,
            #"relation["building"]({bbox});"#,
        ],
        "water": [
            #"way["natural"="water"]({bbox});"#,
            #"way["waterway"]({bbox});"#,
            #"way["water"]({bbox});"#,
            #"relation["natural"="water"]({bbox});"#,
            #"relation["water"]({bbox});"#,
        ],
        "parks": [
            #"way["leisure"~"park|garden|nature_reserve"]({bbox});"#,
            #"way["landuse"~"grass|recreation_ground|village_green|park"]({bbox});"#,
            #"relation["leisure"~"park|garden|nature_reserve"]({bbox});"#,
            #"relation["landuse"~"grass|recreation_ground|village_green|park"]({bbox});"#,
        ],
        "railways": [
            #"way["railway"]({bbox});"#,
        ],
        "forests": [
            #"way["landuse"="forest"]({bbox});"#,
            #"way["natural"="wood"]({bbox});"#,
            #"relation["landuse"="forest"]({bbox});"#,
            #"relation["natural"="wood"]({bbox});"#,
        ],
        "fields": [
            #"way["landuse"="farmland"]({bbox});"#,
            #"way["landuse"="meadow"]({bbox});"#,
            #"way["landuse"="orchard"]({bbox});"#,
            #"way["landuse"="vineyard"]({bbox});"#,
            #"relation["landuse"="farmland"]({bbox});"#,
            #"relation["landuse"="meadow"]({bbox});"#,
            #"relation["landuse"="orchard"]({bbox});"#,
            #"relation["landuse"="vineyard"]({bbox});"#,
        ],
        "natural": [
            #"way["natural"~"beach|cliff|scrub|heath|wetland|grassland"]({bbox});"#,
            #"way["landuse"="brownfield"]({bbox});"#,
            #"relation["natural"~"beach|cliff|scrub|heath|wetland|grassland"]({bbox});"#,
        ],
        "coastline": [
            #"way["natural"="coastline"]({bbox});"#,
            #"relation["place"="sea"]({bbox});"#,
            #"relation["place"="ocean"]({bbox});"#,
            #"way["place"="sea"]({bbox});"#,
            #"way["place"="ocean"]({bbox});"#,
        ],
        "places": [
            #"node["place"]({bbox});"#,
            #"node["name"]["place"]({bbox});"#,
        ],
        "shops": [
            #"node["shop"]({bbox});"#,
            #"way["shop"]({bbox});"#,
            #"node["name"]["shop"]({bbox});"#,
            #"way["name"]["shop"]({bbox});"#,
        ],
        "amenities": [
            #"node["amenity"]({bbox});"#,
            #"way["amenity"]({bbox});"#,
            #"node["name"]["amenity"]({bbox});"#,
            #"way["name"]["amenity"]({bbox});"#,
        ],
        "landuse": [
            #"way["landuse"]({bbox});"#,
            #"relation["landuse"]({bbox});"#,
        ],
        "barriers": [
            #"way["barrier"]({bbox});"#,
            #"node["barrier"]({bbox});"#,
        ],
        "power": [
            #"way["power"]({bbox});"#,
            #"node["power"]({bbox});"#,
        ],
        // Asked for in its own right rather than arriving as a by-product of the
        // water query: a ferry route tagged only `route=ferry`, with no `waterway`
        // at all, would otherwise never be fetched.
        "ferry_routes": [
            #"way["route"="ferry"]({bbox});"#,
            #"relation["route"="ferry"]({bbox});"#,
            #"way["waterway"~"seaway|fairway"]({bbox});"#,
        ],
        // The whole marine namespace in three clauses, because it hangs off one
        // key. A buoy is a node, a restricted area is a way or a relation, and
        // `seamark:type` is on all of them — so asking for the key rather than
        // for each of its hundred-odd values is both shorter and proof against
        // whatever OSM adds next.
        //
        // Cheap despite the breadth: this is one tag, absent from everything
        // inland, and an Overpass tag index answers it without scanning.
        seamarks: [
            #"node["seamark:type"]({bbox});"#,
            #"way["seamark:type"]({bbox});"#,
            #"relation["seamark:type"]({bbox});"#,
        ],
    ]

    /// Create an Overpass QL query for the supported layers in a bbox.
    ///
    /// A request naming no supported layer asks for all of them, which is what makes
    /// an unfiltered fetch work at all — but it is also the expensive path, so the
    /// caller should narrow it whenever it can.
    public static func build(_ query: BBoxQuery, timeoutSeconds: Int = 60) -> String {
        var requested = supportedLayers.filter(query.layers.contains)
        if requested.isEmpty { requested = supportedLayers }

        let bbox = "\(query.bbox.minLat),\(query.bbox.minLon),\(query.bbox.maxLat),\(query.bbox.maxLon)"
        let body = requested
            .flatMap { clauses[$0] ?? [] }
            .map { $0.replacingOccurrences(of: "{bbox}", with: bbox) }
            .joined(separator: "\n    ")

        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
            \(body)
        );
        out body geom;
        """
    }
}
