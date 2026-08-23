import CoreGraphics
import Foundation
import HipparchusData
import HipparchusGeometry
import HipparchusRender
import ImageIO

/// Headless fetch → render → export.
///
/// The point of this is verification against reality. Rendering is visual and a
/// screenshot cannot be asserted on, but elevation ranges can: Santorini's caldera
/// floor is −79 m and its rim 525 m whatever the drawing looks like. This fetches a
/// real area, prints what came back, and writes the files so the output can be
/// looked at as well as measured.
///
/// It is also the only thing that exercises the network path, since no test does.

// MARK: - Named places, for checking output against known ground

struct Place {
    let name: String
    let bbox: BoundingBox
    /// What the elevation range should be, from the Python's own reference values.
    let expected: String
}

let places: [String: Place] = [
    "santorini": Place(
        name: "Santorini",
        bbox: BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48),
        expected: "-79 m caldera floor, 525 m rim"
    ),
    "athens": Place(
        name: "Athens",
        bbox: BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136),
        expected: "-4 m to 1091 m; Hymettus east, Parnitha north-west, Penteli north-east"
    ),
    "sanfrancisco": Place(
        name: "San Francisco",
        bbox: BoundingBox(minLon: -122.53, minLat: 37.70, maxLon: -122.35, maxLat: 37.84),
        expected: "tops at 284 m; Twin Peaks is 282 m"
    ),
    "addisababa": Place(
        name: "Addis Ababa",
        bbox: BoundingBox(minLon: 38.65, minLat: 8.90, maxLon: 38.88, maxLat: 9.10),
        expected: "never below 2,075 m"
    ),
    "everest": Place(
        name: "Everest",
        bbox: BoundingBox(minLon: 86.85, minLat: 27.93, maxLon: 87.05, maxLat: 28.06),
        expected: "5,060 m to 8,746 m"
    ),
    "myrtoan": Place(
        name: "Myrtoan Sea",
        bbox: BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1),
        expected: "reaches -1,310 m"
    ),
]

// MARK: - Arguments

func usage() -> Never {
    let names = places.keys.sorted().joined(separator: ", ")
    print("""
    hipparchus-cli - fetch elevation for an area, render it, and export it.

    Usage:
      hipparchus-cli <place>            \(names)
      hipparchus-cli --bbox w,s,e,n     an arbitrary area, in degrees
      hipparchus-cli --all              every named place above

    Options:
      --out <dir>        where to write files (default: ./out)
      --pixels <n>       sampling width to aim for (default: 1200)
      --streets          stack OpenStreetMap onto the elevation: roads,
                         buildings, water and land cover. Slow, and it is the
                         area that decides — a city block answers, a county does
                         not. Overpass is shared hardware run on donations.
      --hillshade        shade the relief, banded into filled polygons
      --sun <az,alt>     where the light comes from (default: 315,45)
      --exaggeration <x> stretch the relief before lighting it (default: 1)
      --shade-bands <n>  tones between shadow and light (default: 7)
      --relief-on-top    draw the shading over the buildings rather than under
                         them, for a city dense enough to bury it
      --sea-temperature  stack sea surface temperature over the elevation, as
                         isotherms and filled bands, from NOAA ERDDAP
      --currents         surface currents as streamlines, thickening where the
                         water runs faster. Wants a sea-sized frame: the field
                         is 0.25 deg, so a bay is four cells across.
      --natural-earth <path>
                         stack Natural Earth on top: coastlines, borders,
                         rivers, lakes and place names, from a downloaded
                         shapefile or a folder of them. What OpenStreetMap
                         cannot answer for at continental scale.
      --simulated        a generated field instead of measured elevation. Needs
                         no network and is not a measurement of anywhere.
      --preset <name>    style preset (default: \(SceneBuilder.Options().preset.name))
      --quality <key>    \(Quality.keys.joined(separator: ", "))
      --list-presets     print the preset names and exit
      --plugins <dir>    also load style packs from a plugin folder, so their
                         presets and places can be named like the built-in ones
      --paper <name>     sheet for every export: \(PaperSize.names.joined(separator: ", "))
      --dpi <n>          resolution for the raster and the SVG viewport
      --line-weight <x>  multiply every stroke (default: 1)
      --palette <name>   recolour the preset without restyling it
      --list-palettes    print the palette names and exit
      --portrait         turn the sheet (default: landscape)
      --furniture        title, scale bar, north arrow and legend on the SVG, A4
      --no-files         measure only, write nothing

    Writes <name>.png, <name>.svg, <name>.pdf and <name>.diagnostics.json.
    """)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { usage() }

/// Parsed command line. Passed to `run` rather than read from it: top-level
/// variables in a `main.swift` are main-actor isolated, and `run` is not.
struct Options {
    var outputDirectory = URL(fileURLWithPath: "out")
    var targetPixels = 1200
    var writeFiles = true
    var preset = SceneBuilder.Options().preset
    var quality = Quality.default
    var furniture = false
    var page = PageSpec()
    var lineWeight = 1.0
    var palette: Palette?
    var hillshade = false
    var reliefOnTop = false
    var currents = false
    var seaTemperature = false
    var simulated = false
    var streets = false
    var sun = SunPosition()
    var exaggeration = 1.0
    var shadeBands = TerrainTileSettings().hillshadeBandCount
    var naturalEarth: URL?
}

/// Style packs, loaded before anything else is parsed.
///
/// A pre-pass rather than another `case` in the loop below, because loading a
/// pack changes what `--preset` and a bare place name are allowed to mean, and
/// arguments do not have to arrive in a helpful order. The same `PluginLoader`
/// the app uses, so a pack that the app refuses is refused here too, out loud.
func loadPacks(from arguments: [String]) -> (presets: [String: ArtisticPreset], places: [String: Place]) {
    guard let flag = arguments.firstIndex(of: "--plugins"), flag + 1 < arguments.count else {
        return ([:], [:])
    }
    let directory = URL(fileURLWithPath: arguments[flag + 1])
    let loader = PluginLoader(userPluginDirectory: directory, reservedPlaceNames: Set(places.values.map(\.name)))
    let registry = loader.loadAll()

    for error in loader.loadErrors { print("warning: \(error)") }
    if !loader.loadedPlugins.isEmpty {
        print("loaded \(loader.loadedPlugins.count) pack(s): \(loader.loadedPlugins.map(\.name).joined(separator: ", "))")
    }

    let presets = Dictionary(
        registry.presets.map { ($0.name.lowercased(), $0) },
        uniquingKeysWith: { first, _ in first }
    )
    let packPlaces = Dictionary(
        registry.places.map {
            ($0.name.lowercased(), Place(name: $0.name, bbox: $0.bbox, expected: "from a style pack"))
        },
        uniquingKeysWith: { first, _ in first }
    )
    return (presets, packPlaces)
}

let packs = loadPacks(from: arguments)

var options = Options()
var requested: [Place] = []

var argumentIndex = 0
while argumentIndex < arguments.count {
    switch arguments[argumentIndex] {
    case "--out":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        options.outputDirectory = URL(fileURLWithPath: arguments[argumentIndex])
    case "--pixels":
        argumentIndex += 1
        guard argumentIndex < arguments.count, let value = Int(arguments[argumentIndex]) else { usage() }
        options.targetPixels = value
    case "--no-files":
        options.writeFiles = false
    case "--paper":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let requested = arguments[argumentIndex]
        // An unknown sheet silently becomes Canvas, which is a 2400-pixel file
        // where a poster was asked for. Say so.
        guard PaperSize.names.contains(requested) else {
            print("error: no paper '\(requested)'. One of: \(PaperSize.names.joined(separator: ", "))")
            exit(2)
        }
        options.page.paperName = requested
    case "--dpi":
        argumentIndex += 1
        guard argumentIndex < arguments.count, let value = Double(arguments[argumentIndex]), value > 0 else { usage() }
        options.page.dpi = value
    case "--portrait":
        options.page.orientation = "Portrait"
    case "--list-palettes":
        for name in Palette.names { print(name) }
        exit(0)
    case "--palette":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let wanted = arguments[argumentIndex]
        guard wanted != Palette.presetOwnName else { break }
        guard let found = Palette.named(wanted) else {
            print("error: no palette '\(wanted)'. One of: \(Palette.names.joined(separator: ", "))")
            exit(2)
        }
        options.palette = found
    case "--line-weight":
        argumentIndex += 1
        guard argumentIndex < arguments.count,
              let value = Double(arguments[argumentIndex]), value > 0 else { usage() }
        options.lineWeight = value
    case "--streets":
        options.streets = true
    case "--hillshade":
        options.hillshade = true
    case "--relief-on-top":
        options.reliefOnTop = true
        options.hillshade = true
    case "--currents":
        options.currents = true
    case "--sea-temperature":
        options.seaTemperature = true
    case "--natural-earth":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        options.naturalEarth = URL(fileURLWithPath: arguments[argumentIndex])
    case "--simulated":
        options.simulated = true
    case "--sun":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let parts = arguments[argumentIndex]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else {
            print("error: --sun needs two numbers: azimuth,altitude")
            exit(2)
        }
        options.sun = SunPosition(azimuthDegrees: parts[0], altitudeDegrees: parts[1])
        options.hillshade = true
    case "--exaggeration":
        argumentIndex += 1
        guard argumentIndex < arguments.count, let value = Double(arguments[argumentIndex]) else { usage() }
        options.exaggeration = value
        options.hillshade = true
    case "--shade-bands":
        argumentIndex += 1
        guard argumentIndex < arguments.count, let value = Int(arguments[argumentIndex]) else { usage() }
        options.shadeBands = value
        options.hillshade = true
    case "--furniture":
        // Everything on at once, because this flag exists to look at the result:
        // the title block, the scale bar, the north arrow and the legend, framed
        // for A4. The app offers the same pieces one by one in its Page section.
        options.furniture = true
    case "--plugins":
        // Already read by the pre-pass; skip its argument.
        argumentIndex += 1
    case "--list-presets":
        for name in Presets.names { print(name) }
        for preset in packs.presets.values.map(\.name).sorted() { print(preset) }
        exit(0)
    case "--preset":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let requestedName = arguments[argumentIndex]
        let cleaned = requestedName.trimmingCharacters(in: .whitespaces).lowercased()
        // A pack's preset wins over the fallback, but never over a built-in of
        // the same name — that is the rule `PluginRegistry` already enforces.
        if !Presets.names.contains(where: { $0.lowercased() == cleaned }),
           let fromPack = packs.presets[cleaned] {
            options.preset = fromPack
            argumentIndex += 1
            continue
        }
        let resolved = Presets.resolveName(requestedName)
        // Say so rather than silently drawing something else. A preset name that
        // fell back without a word is how you end up debugging the renderer for a
        // look the preset never had.
        if resolved.lowercased() != cleaned {
            print("warning: no preset '\(requestedName)'; using '\(resolved)'")
        }
        options.preset = Presets.preset(resolved)
    case "--quality":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        options.quality = Quality.profile(arguments[argumentIndex])
    case "--all":
        requested = places.keys.sorted().compactMap { places[$0] }
    case "--bbox":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let parts = arguments[argumentIndex]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            print("error: --bbox needs four numbers: west,south,east,north")
            exit(2)
        }
        requested.append(Place(
            name: "custom",
            bbox: BoundingBox(minLon: parts[0], minLat: parts[1], maxLon: parts[2], maxLat: parts[3]),
            expected: "unknown"
        ))
    case "--help", "-h":
        usage()
    default:
        let name = arguments[argumentIndex].lowercased()
        guard let place = places[name] ?? packs.places[name] else {
            print("error: unknown place '\(arguments[argumentIndex])'")
            usage()
        }
        requested.append(place)
    }
    argumentIndex += 1
}

guard !requested.isEmpty else { usage() }

// MARK: - Run

func slug(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: " ", with: "-")
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CLIError.couldNotWrite(url)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CLIError.couldNotWrite(url)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case couldNotWrite(URL)

    var description: String {
        switch self {
        case .couldNotWrite(let url): return "could not write \(url.path)"
        }
    }
}

func run(_ place: Place, options: Options) async throws {
    var settings = TerrainTileSettings()
    settings.targetPixels = options.targetPixels
    settings.emitHillshade = options.hillshade
    settings.sun = options.sun
    settings.hillshadeExaggeration = options.exaggeration
    settings.hillshadeBandCount = options.shadeBands

    print("\(place.name)  \(place.bbox.minLon), \(place.bbox.minLat) -> \(place.bbox.maxLon), \(place.bbox.maxLat)")
    print("  expected: \(place.expected)")

    let started = ContinuousClock.now
    let terrain = TerrainTileProvider(settings: settings)
    // Stacked onto whatever else is being drawn rather than replacing it, which
    // is how the sidebar treats every source: ticking Natural Earth adds
    // coastlines and borders to a relief sheet, it does not throw the relief
    // away.
    let atlas: [any MapProvider] = options.naturalEarth
        .map { [FileSourceProvider.naturalEarth(path: $0)] } ?? []
    let atlasIDs = atlas.map(\.providerID)
    let collection: FeatureCollection
    if options.simulated {
        // Nothing measured, and nothing fetched. The one source that can draw a
        // mountain on a train.
        var field = TerrainFieldSettings()
        field.emitHillshade = options.hillshade
        field.sun = options.sun
        field.hillshadeExaggeration = options.exaggeration
        field.hillshadeBandCount = options.shadeBands
        collection = try await SimulatedFieldProvider(settings: field).fetch(BBoxQuery(bbox: place.bbox))
    } else if options.currents {
        let manager = DataSourceManager(providers: [terrain, CurrentsProvider()] + atlas)
        collection = try await manager.fetch(
            BBoxQuery(bbox: place.bbox),
            plan: FetchPlan(base: SourceID.terrainTiles, extras: [currentsProviderID] + atlasIDs)
        )
        if let failures = collection.metadata["provider_errors"]?.stringValue {
            print("  some sources failed: \(failures)")
        }
    } else if options.seaTemperature {
        // The same manager the app fetches through, so the merge and the
        // weakest-provenance rule are the shipped ones. Stacked on the
        // elevation, because a temperature field over a blank sheet says
        // nothing about where it is.
        let manager = DataSourceManager(providers: [terrain, ERDDAPProvider()] + atlas)
        collection = try await manager.fetch(
            BBoxQuery(bbox: place.bbox),
            plan: FetchPlan(base: SourceID.terrainTiles, extras: [SourceID.seaTemperature] + atlasIDs)
        )
        if let failures = collection.metadata["provider_errors"]?.stringValue {
            print("  some sources failed: \(failures)")
        }
    } else if options.streets {
        // The same manager the app fetches through, so the merge, the layer
        // precedence and the weakest-provenance-wins rule are the shipped ones
        // rather than a second implementation written for a flag.
        let manager = DataSourceManager(providers: [terrain, OverpassProvider()] + atlas)
        collection = try await manager.fetch(
            BBoxQuery(bbox: place.bbox),
            plan: FetchPlan(base: SourceID.overpass, extras: [SourceID.terrainTiles] + atlasIDs)
        )
        // Said out loud. A city that came back with no roads and no explanation
        // is how you end up blaming the renderer.
        if let failures = collection.metadata["provider_errors"]?.stringValue {
            print("  provider errors: \(failures)")
        }
    } else if !atlas.isEmpty {
        let manager = DataSourceManager(providers: [terrain] + atlas)
        collection = try await manager.fetch(
            BBoxQuery(bbox: place.bbox),
            plan: FetchPlan(base: SourceID.terrainTiles, extras: atlasIDs)
        )
        if let failures = collection.metadata["provider_errors"]?.stringValue {
            print("  some sources failed: \(failures)")
        }
    } else {
        collection = try await terrain.fetch(BBoxQuery(bbox: place.bbox))
    }
    let fetched = ContinuousClock.now - started

    /// A merged fetch keeps each provider's metadata under its own name, so that
    /// two sources reporting a `zoom` cannot overwrite each other. A single
    /// fetch does not. Read both rather than only the one this run happens to
    /// produce.
    func terrainMetadata(_ key: String) -> Double? {
        collection.metadata[key]?.doubleValue
            ?? collection.metadata["\(terrainTilesProviderID).\(key)"]?.doubleValue
    }

    let low = terrainMetadata("elevation_min_metres") ?? .nan
    let high = terrainMetadata("elevation_max_metres") ?? .nan
    let interval = terrainMetadata("contour_interval_metres") ?? .nan
    let zoom = terrainMetadata("zoom") ?? .nan
    let columns = terrainMetadata("grid_columns") ?? .nan
    let rows = terrainMetadata("grid_rows") ?? .nan

    print(String(
        format: "  measured: %.0f m to %.0f m   interval %.0f m   zoom %.0f   grid %.0fx%.0f   %@",
        low, high, interval, zoom, columns, rows, collection.provenance?.rawValue ?? "unknown"
    ))

    let built = try SceneBuilder(options: SceneBuilder.Options(
        preset: options.preset.recoloured(with: options.palette), quality: options.quality
    )).build(from: collection).scalingLineWeights(by: options.lineWeight)
    let scene = options.reliefOnTop ? built.raisingReliefOverTheBuiltEnvironment() : built
    print("  \(scene.summary)   fetched in \(fetched.formattedSeconds)")
    print("  \(options.preset.name) · \(options.quality.label)")
    if options.hillshade {
        print(String(
            format: "  sun %.0f° at %.0f° · exaggeration %.2g · %.0f tones",
            options.sun.azimuthDegrees, options.sun.altitudeDegrees, options.exaggeration,
            terrainMetadata("hillshade_band_count") ?? 0
        ))
    }
    for layer in scene.layers {
        let count = layer.featureCount
        // Illumination turns one contour into several runs, so the drawn count and
        // the fetched count are different numbers and both are worth seeing.
        let drawn = count > 0 ? spacedThousands(count) : "none here"
        let suffix = count != layer.rawFeatureCount && layer.rawFeatureCount > 0
            ? "  (from \(spacedThousands(layer.rawFeatureCount)) fetched)"
            : ""
        print("    \(layer.name.padded(to: 24)) \(drawn)\(suffix)")
    }

    // The longest contour, because kickoff detail 9 is about long paths surviving.
    let longest = scene.layers
        .flatMap(\.geometries)
        .flatMap(\.lineStrings)
        .map(\.coordinates.count)
        .max() ?? 0
    if longest > 0 {
        print("    longest contour:         \(spacedThousands(longest)) vertices")
    }

    guard options.writeFiles else { return }

    try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
    let base = options.outputDirectory.appendingPathComponent(slug(place.name))

    // Canvas keeps the 1600 × 1200 these runs have always written; a named sheet
    // is inches × dpi, and is the same sheet in all three formats below.
    let raster = options.page.pixelSize(canvasWidth: 1600, canvasHeight: 1200)
    let cost = options.page.bitmapCost(canvasWidth: 1600, canvasHeight: 1200)
    if options.page.exceedsBitmapLimit(canvasWidth: 1600, canvasHeight: 1200) {
        print(String(format: "  skipping PNG: %d x %d is %.0f MP (%.1f GB)",
                     raster.width, raster.height, cost.megapixels, cost.megabytes / 1000.0))
    } else {
        let started = ContinuousClock.now
        if let image = CoreGraphicsRenderer().image(
            of: scene, size: CGSize(width: raster.width, height: raster.height)
        ) {
            try writePNG(image, to: base.appendingPathExtension("png"))
            if cost.megapixels > 8 {
                print(String(format: "  PNG %d x %d  %.0f MP  drawn in %@",
                             raster.width, raster.height, cost.megapixels,
                             (ContinuousClock.now - started).formattedSeconds))
            }
        } else {
            print(String(format: "  PNG failed: %d x %d (%.0f MB) could not be allocated",
                         raster.width, raster.height, cost.megabytes))
        }
    }
    var svgOptions = SVGExporter.Options()
    svgOptions.precision = options.quality.svgPrecision
    let svgSize = options.page.pixelSize(canvasWidth: svgOptions.width, canvasHeight: svgOptions.height)
    svgOptions.width = svgSize.width
    svgOptions.height = svgSize.height
    svgOptions.composition.paperPreset = options.page.paperName
    svgOptions.composition.orientation = options.page.orientation
    if options.furniture {
        svgOptions.composition.title = place.name == "custom" ? "Hipparchus" : place.name.capitalized
        svgOptions.composition.subtitle = String(
            format: "%.2f, %.2f → %.2f, %.2f",
            place.bbox.minLon, place.bbox.minLat, place.bbox.maxLon, place.bbox.maxLat
        )
        svgOptions.composition.includeTitle = true
        svgOptions.composition.includeScaleBar = true
        svgOptions.composition.includeNorthArrow = true
        svgOptions.composition.includeLegend = true
        svgOptions.composition.paperPreset = "A4"
        let size = svgOptions.composition.exportSize(
            canvasWidth: svgOptions.width, canvasHeight: svgOptions.height
        )
        svgOptions.width = size.width
        svgOptions.height = size.height
    }
    let diagnostics = try SVGExporter(options: svgOptions).write(scene, to: base.appendingPathExtension("svg"))
    var pdfOptions = PDFExporter.Options()
    let points = options.page.pointSize(canvasWidth: 1600, canvasHeight: 1200)
    pdfOptions.width = points.width
    pdfOptions.height = points.height
    try PDFExporter(options: pdfOptions).write(scene, to: base.appendingPathExtension("pdf"))
    try diagnostics.jsonData().write(to: base.appendingPathExtension("diagnostics.json"))

    print("  wrote \(slug(place.name)).{png,svg,pdf,diagnostics.json} into \(options.outputDirectory.path)")
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

extension Duration {
    var formattedSeconds: String {
        String(format: "%.2f s", Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}

var failures = 0
for place in requested {
    do {
        try await run(place, options: options)
    } catch {
        failures += 1
        print("  FAILED: \(error)")
    }
    print("")
}
exit(failures == 0 ? 0 : 1)
