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
      --hillshade        shade the relief, banded into filled polygons
      --sun <az,alt>     where the light comes from (default: 315,45)
      --exaggeration <x> stretch the relief before lighting it (default: 1)
      --shade-bands <n>  tones between shadow and light (default: 7)
      --preset <name>    style preset (default: \(SceneBuilder.Options().preset.name))
      --quality <key>    \(Quality.keys.joined(separator: ", "))
      --list-presets     print the preset names and exit
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
    var hillshade = false
    var sun = SunPosition()
    var exaggeration = 1.0
    var shadeBands = TerrainTileSettings().hillshadeBandCount
}

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
    case "--hillshade":
        options.hillshade = true
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
    case "--list-presets":
        for name in Presets.names { print(name) }
        exit(0)
    case "--preset":
        argumentIndex += 1
        guard argumentIndex < arguments.count else { usage() }
        let requestedName = arguments[argumentIndex]
        let resolved = Presets.resolveName(requestedName)
        // Say so rather than silently drawing something else. A preset name that
        // fell back without a word is how you end up debugging the renderer for a
        // look the preset never had.
        if resolved.lowercased() != requestedName.trimmingCharacters(in: .whitespaces).lowercased() {
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
        guard let place = places[arguments[argumentIndex].lowercased()] else {
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
    let provider = TerrainTileProvider(settings: settings)
    let collection = try await provider.fetch(BBoxQuery(bbox: place.bbox))
    let fetched = ContinuousClock.now - started

    let low = collection.metadata["elevation_min_metres"]?.doubleValue ?? .nan
    let high = collection.metadata["elevation_max_metres"]?.doubleValue ?? .nan
    let interval = collection.metadata["contour_interval_metres"]?.doubleValue ?? .nan
    let zoom = collection.metadata["zoom"]?.doubleValue ?? .nan
    let columns = collection.metadata["grid_columns"]?.doubleValue ?? .nan
    let rows = collection.metadata["grid_rows"]?.doubleValue ?? .nan

    print(String(
        format: "  measured: %.0f m to %.0f m   interval %.0f m   zoom %.0f   grid %.0fx%.0f   %@",
        low, high, interval, zoom, columns, rows, collection.provenance?.rawValue ?? "unknown"
    ))

    let scene = try SceneBuilder(options: SceneBuilder.Options(
        preset: options.preset, quality: options.quality
    )).build(from: collection)
    print("  \(scene.summary)   fetched in \(fetched.formattedSeconds)")
    print("  \(options.preset.name) · \(options.quality.label)")
    if options.hillshade {
        print(String(
            format: "  sun %.0f° at %.0f° · exaggeration %.2g · %.0f tones",
            options.sun.azimuthDegrees, options.sun.altitudeDegrees, options.exaggeration,
            collection.metadata["hillshade_band_count"]?.doubleValue ?? 0
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

    if let image = CoreGraphicsRenderer().image(of: scene, size: CGSize(width: 1600, height: 1200)) {
        try writePNG(image, to: base.appendingPathExtension("png"))
    }
    var svgOptions = SVGExporter.Options()
    svgOptions.precision = options.quality.svgPrecision
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
    try PDFExporter().write(scene, to: base.appendingPathExtension("pdf"))
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
