import Foundation

/// What a sheet owes the people whose data drew it.
///
/// **This existed as prose in one window, and prose does not survive a new
/// source.** The About panel listed its credits in a hand-written paragraph, and
/// every source added since was one somebody had to remember to type there. Four
/// marine sources arrived in a day; the paragraph did not gain a line for any of
/// them, and NOAA's two were simply missing — which is a licence breach nobody
/// notices until somebody else does.
///
/// So attribution becomes data keyed by the source that owes it, and the panel
/// renders the registry rather than the registry living in the panel.
///
/// **The second half matters more than the first.** The About panel said the
/// attributions "travel with anything you publish", and nothing travelled — no
/// export carried a credit of any kind. A registry that only feeds a window
/// leaves that sentence false. `AttributionRegistry.statement(forSources:)` is
/// what goes into the exported file, and it names only the sources that actually
/// drew *that* sheet: a map of Everest does not owe EMODnet a line, and padding
/// it with credits it did not use is its own kind of dishonesty.
public struct Attribution: Sendable, Equatable, Codable {
    /// The provider ID that owes this, matching `SourceID` and the `source`
    /// every `FeatureCollection` records.
    public let sourceID: String
    /// What to call it in a list.
    public let name: String
    /// The line the licence asks for, verbatim enough to satisfy it.
    public let statement: String
    /// The licence itself, named rather than quoted.
    public let licence: String
    public let url: String

    public init(sourceID: String, name: String, statement: String, licence: String, url: String) {
        self.sourceID = sourceID
        self.name = name
        self.statement = statement
        self.licence = licence
        self.url = url
    }
}

public enum AttributionRegistry {

    /// Every source this application can fetch from, and what each is owed.
    ///
    /// Ordered as a reader would want to read it — the data that draws the land
    /// first, then the sea, then the sky — rather than alphabetically or by the
    /// order the providers happened to be written.
    public static let all: [Attribution] = [
        Attribution(
            sourceID: SourceID.overpass,
            name: "OpenStreetMap",
            statement: "Map data © OpenStreetMap contributors",
            licence: "Open Database License (ODbL)",
            url: "https://www.openstreetmap.org/copyright"
        ),
        Attribution(
            sourceID: SourceID.terrainTiles,
            name: "Terrain Tiles",
            statement: "Elevation from Mapzen / AWS Terrain Tiles",
            licence: "public domain and ODbL, by tile source",
            url: "https://registry.opendata.aws/terrain-tiles/"
        ),
        Attribution(
            sourceID: emodnetBathymetrySourceID,
            name: "EMODnet Bathymetry",
            statement: "Bathymetry in European seas from EMODnet Bathymetry",
            licence: "free to use with attribution",
            url: "https://emodnet.ec.europa.eu/en/bathymetry"
        ),
        Attribution(
            sourceID: SourceID.seaTemperature,
            name: "NOAA CoastWatch ERDDAP",
            statement: "Sea surface temperature from NASA JPL MUR, served by NOAA CoastWatch ERDDAP",
            licence: "public domain (U.S. Government work)",
            url: "https://coastwatch.pfeg.noaa.gov/erddap/"
        ),
        Attribution(
            sourceID: SourceID.currents,
            name: "NOAA CoastWatch ERDDAP",
            statement: "Geostrophic surface currents from NOAA/NESDIS sea surface height, served by NOAA CoastWatch ERDDAP",
            licence: "public domain (U.S. Government work)",
            url: "https://coastwatch.pfeg.noaa.gov/erddap/"
        ),
        Attribution(
            sourceID: SourceID.gibsImagery,
            name: "NASA GIBS",
            statement: "Imagery from NASA Global Imagery Browse Services (GIBS)",
            licence: "free to use with attribution",
            url: "https://nasa-gibs.github.io/gibs-api-docs/"
        ),
        Attribution(
            sourceID: SourceID.usgsEarthquakes,
            name: "USGS",
            statement: "Earthquakes from the U.S. Geological Survey",
            licence: "public domain (U.S. Government work)",
            url: "https://earthquake.usgs.gov/"
        ),
        Attribution(
            sourceID: SourceID.satelliteTracks,
            name: "CelesTrak",
            statement: "Satellite orbital elements from CelesTrak",
            licence: "free to use with attribution",
            url: "https://celestrak.org/"
        ),
    ]

    /// Sources that owe nothing, and why — so that "no attribution" is a
    /// recorded decision rather than an omission that looks like one.
    ///
    /// A generated field is this application's own arithmetic, and a file the
    /// user opened is the user's own data. Neither has anybody to credit, and
    /// both would otherwise fail the completeness check below and tempt somebody
    /// into inventing a line for them.
    public static let exempt: Set<String> = [
        SourceID.simulatedTerrain,
        SourceID.localOSMPBF,
        SourceID.vectorTiles,
        SourceID.naturalEarth,
        SourceID.overture,
    ]

    /// Credits owed by the drawing rather than by the data.
    ///
    /// Kept apart because they are true of every sheet and belong to no source,
    /// so they never vary with what was fetched — which means they belong in the
    /// window and not in the exported file's source list.
    public static let tools: [Attribution] = [
        Attribution(
            sourceID: "geos",
            name: "GEOS",
            statement: "Geometry operations by GEOS",
            licence: "LGPL 2.1",
            url: "https://libgeos.org/"
        ),
        Attribution(
            sourceID: "apple_mapkit",
            name: "Apple MapKit",
            statement: "Geocoding by Nominatim and Apple MapKit; Locator basemap © Apple",
            licence: "per Apple's terms",
            url: "https://developer.apple.com/maps/"
        ),
    ]

    public static func attribution(forSource sourceID: String) -> Attribution? {
        all.first { $0.sourceID == sourceID }
    }

    /// What a particular sheet owes, in registry order and without repeats.
    ///
    /// The two ERDDAP datasets share a statement in everything but their first
    /// clause, so a sheet carrying both would otherwise credit NOAA twice.
    /// Unknown sources are dropped rather than guessed at: a credit invented for
    /// something is worse than no credit, because it is wrong on purpose.
    public static func attributions(forSources sources: [String]) -> [Attribution] {
        let wanted = Set(sources)
        var seen = Set<String>()
        return all
            .filter { wanted.contains($0.sourceID) }
            .filter { seen.insert($0.statement).inserted }
    }

    /// The one line that goes into an exported file.
    ///
    /// Empty when nothing is owed, so a caller can tell "nothing to say" from
    /// "something went wrong" — a sheet drawn from a generated field genuinely
    /// owes nobody anything.
    public static func statement(forSources sources: [String]) -> String {
        attributions(forSources: sources)
            .map(\.statement)
            .joined(separator: ". ")
    }

    /// Every source this application ships a provider for, whether or not it
    /// owes a credit.
    ///
    /// This is the list the completeness check reads. **It is written by hand on
    /// purpose**: a provider ID discovered by reflection would quietly grow when
    /// a new provider appeared, which is exactly the failure the registry exists
    /// to stop. Adding a provider means adding it here, and then either giving
    /// it an attribution or declaring it exempt.
    public static let shippedSources: Set<String> = [
        SourceID.overpass,
        SourceID.terrainTiles,
        emodnetBathymetrySourceID,
        SourceID.seaTemperature,
        SourceID.currents,
        SourceID.gibsImagery,
        SourceID.usgsEarthquakes,
        SourceID.satelliteTracks,
        SourceID.simulatedTerrain,
        SourceID.localOSMPBF,
        SourceID.vectorTiles,
        SourceID.naturalEarth,
        SourceID.overture,
    ]
}

/// EMODnet is blended into the elevation grid rather than fetched as its own
/// source, so it has no provider ID of its own — but it is the one source here
/// whose licence explicitly requires a line, so it needs a name to be owed
/// under.
public let emodnetBathymetrySourceID = "emodnet_bathymetry"
