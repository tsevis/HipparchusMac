import HipparchusGeometry

/// The saved places as a tree rather than a flat run of rows: the featured
/// cities, the regions — World, the continents and the Mediterranean — and
/// every country grouped by its continent. The Mac twin of the Python app's
/// `places.py` grouping, so the two rails cannot drift apart.
///
/// A `List` this long is a wall; a cascade is a menu. The frame panel renders
/// each group as a `Menu`, its subgroups as nested menus, so two hundred
/// countries live one continent away rather than all at once.
struct PlaceGroup: Identifiable {
    let name: String
    let places: [MapModel.Place]
    let subgroups: [PlaceGroup]
    var id: String { name }

    init(_ name: String, places: [MapModel.Place] = [], subgroups: [PlaceGroup] = []) {
        self.name = name
        self.places = places
        self.subgroups = subgroups
    }
}

enum SavedPlaces {
    /// The continents, the Mediterranean and the whole world. Coarse boxes,
    /// curated rather than derived: a continent's box is where a reader expects
    /// it to sit, not the union of its countries' — Russia's would drag Europe
    /// to the antimeridian. Equal Earth is reached for automatically at this
    /// size, so the aspect need not be fussed here.
    static let regions: [MapModel.Place] = [
        MapModel.Place(name: "World", bbox: BoundingBox(minLon: -180, minLat: -60, maxLon: 180, maxLat: 84)),
        MapModel.Place(name: "Africa", bbox: BoundingBox(minLon: -18, minLat: -35, maxLon: 52, maxLat: 38)),
        MapModel.Place(name: "Asia", bbox: BoundingBox(minLon: 26, minLat: -11, maxLon: 180, maxLat: 78)),
        MapModel.Place(name: "Europe", bbox: BoundingBox(minLon: -25, minLat: 34, maxLon: 45, maxLat: 72)),
        MapModel.Place(name: "North America", bbox: BoundingBox(minLon: -168, minLat: 7, maxLon: -52, maxLat: 84)),
        MapModel.Place(name: "Oceania", bbox: BoundingBox(minLon: 112, minLat: -48, maxLon: 180, maxLat: 0)),
        MapModel.Place(name: "South America", bbox: BoundingBox(minLon: -82, minLat: -56, maxLon: -34, maxLat: 13)),
        MapModel.Place(name: "Antarctica", bbox: BoundingBox(minLon: -180, minLat: -85, maxLon: 180, maxLat: -60)),
        MapModel.Place(name: "Mediterranean", bbox: BoundingBox(minLon: -6, minLat: 30, maxLon: 37, maxLat: 46)),
    ]

    /// The order the continent submenus appear in under Countries.
    static let continentOrder = ["Africa", "Asia", "Europe", "North America", "Oceania", "South America"]

    /// One submenu per continent, its countries already sorted by name.
    static let countryGroups: [PlaceGroup] = {
        var byContinent: [String: [MapModel.Place]] = [:]
        for country in CountryBoxes.all {
            byContinent[country.continent, default: []].append(
                MapModel.Place(name: country.name, bbox: country.bbox)
            )
        }
        return continentOrder.compactMap { continent in
            guard let places = byContinent[continent], !places.isEmpty else { return nil }
            return PlaceGroup(continent, places: places)
        }
    }()

    /// The tree the frame panel renders: the featured cities as passed in, then
    /// the regions, then the countries by continent.
    static func groups(featured: [MapModel.Place]) -> [PlaceGroup] {
        [
            PlaceGroup("Cities", places: featured),
            PlaceGroup("Regions", places: regions),
            PlaceGroup("Countries", subgroups: countryGroups),
        ]
    }
}
