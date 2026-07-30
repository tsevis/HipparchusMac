import AppKit
import HipparchusData
import HipparchusGeometry
import HipparchusRender
import SwiftUI
import UniformTypeIdentifiers

/// Everything the window needs to know, and nothing about how it looks.
///
/// The rules all live below this in the package — `SourceStack` decides what a set
/// of ticks means, `DataSourceManager` fetches it, `SceneBuilder` draws it,
/// `LayerInventory` describes it. This holds them together and exposes the result
/// to SwiftUI. Views bind to it; they do not reimplement any of it.
@MainActor
@Observable
final class MapModel {

    // MARK: - The area

    struct Place: Identifiable, Sendable {
        let name: String
        let bbox: BoundingBox
        var id: String { name }
    }

    /// The areas with known answers, from the kickoff. They double as the saved
    /// places list and as the way to check output against reality without typing
    /// four numbers.
    static let places: [Place] = [
        Place(name: "Santorini", bbox: BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)),
        Place(name: "Athens", bbox: BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136)),
        Place(name: "San Francisco", bbox: BoundingBox(minLon: -122.53, minLat: 37.70, maxLon: -122.35, maxLat: 37.84)),
        Place(name: "Addis Ababa", bbox: BoundingBox(minLon: 38.65, minLat: 8.90, maxLon: 38.88, maxLat: 9.10)),
        Place(name: "Everest", bbox: BoundingBox(minLon: 86.85, minLat: 27.93, maxLon: 87.05, maxLat: 28.06)),
        Place(name: "Myrtoan Sea", bbox: BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)),
    ]

    var west = "25.32"
    var south = "36.33"
    var east = "25.50"
    var north = "36.48"
    var placeName = "Santorini"

    /// The area currently drawn, which is not the area in the boxes until Update map
    /// is pressed. Keeping them apart is what lets the boxes be edited without the
    /// map flickering through half-typed coordinates.
    private(set) var drawnBBox: BoundingBox?

    var bbox: BoundingBox? {
        guard
            let west = Double(west.trimmingCharacters(in: .whitespaces)),
            let south = Double(south.trimmingCharacters(in: .whitespaces)),
            let east = Double(east.trimmingCharacters(in: .whitespaces)),
            let north = Double(north.trimmingCharacters(in: .whitespaces)),
            west < east, south < north,
            (-180...180).contains(west), (-180...180).contains(east),
            (-90...90).contains(south), (-90...90).contains(north)
        else {
            return nil
        }
        return BoundingBox(minLon: west, minLat: south, maxLon: east, maxLat: north)
    }

    /// `0.32° × 0.32° · 1:50 000` — what the toolbar shows beside the area.
    var areaDescription: String {
        guard let bbox else { return "—" }
        return String(format: "%.2f° × %.2f°", abs(bbox.lonSpan), abs(bbox.latSpan))
    }

    // MARK: - What the map is made of

    var stack = SourceStack()
    var preset = Presets.preset("Hypsometric Relief")
    var quality = Quality.default

    /// Which derived layers to invent on top of the map.
    ///
    /// Held apart from the preset because no preset enables one — all sixteen style
    /// the four derived layers and three tune their sizes, but every switch is off,
    /// here and in the Python. This is the switch.
    var derivations = GeometryPipelineProfile()

    var derivesAnything: Bool {
        derivations.deriveVoronoi || derivations.deriveDelaunay
            || derivations.deriveHexGrid || derivations.deriveCirclePacking
    }

    /// Layers the user has hidden by hand. Kept separately from the scene so a
    /// re-fetch does not silently turn hidden layers back on.
    var hiddenLayers: Set<String> = []

    // MARK: - The result

    private(set) var scene: RenderScene?
    private(set) var progress = FetchProgress()
    private(set) var isFetching = false
    private(set) var status = "Pick an area and press Update map."
    private(set) var isError = false
    private(set) var provenance: String?
    private(set) var cacheSummary = ""

    /// Shown before a fetch that will take minutes rather than seconds.
    var pendingWarning: String?

    var layerRows: [(group: String, rows: [LayerInventory.Entry])] {
        scene.map { LayerInventory.grouped(for: $0) } ?? []
    }

    /// The scene with the user's own visibility choices applied.
    var visibleScene: RenderScene? {
        guard var scene else { return nil }
        for index in scene.layers.indices where hiddenLayers.contains(scene.layers[index].name) {
            scene.layers[index].style.visible = false
        }
        return scene
    }

    private var task: Task<Void, Never>?
    private let cache = DiskCacheStore(directory: DiskCacheStore.defaultDirectory())
    private let sessionURL = Session.defaultURL()

    // MARK: - Remembering

    /// Restore what the app was doing last time.
    ///
    /// Only the choices, never the map: a saved session says which sources were
    /// ticked and where you were looking, and pressing Update map is left to you.
    /// Re-fetching on launch would mean opening the app could cost five minutes of
    /// Overpass time nobody asked for.
    func restore() {
        let session = Session.read(from: sessionURL)
        stack = session.stack()
        preset = Presets.preset(session.presetName)
        quality = Quality.profile(session.qualityKey)
        hiddenLayers = Set(session.hiddenLayers)
        placeName = session.placeName
        west = String(session.area.west)
        south = String(session.area.south)
        east = String(session.area.east)
        north = String(session.area.north)
    }

    /// A failure to save is worth nothing more than the settings: it must never
    /// interrupt what the user was doing.
    func save() {
        guard let bbox else { return }
        try? Session(
            stack: stack,
            area: Session.Area(bbox),
            placeName: placeName,
            preset: preset.name,
            quality: quality.key,
            hiddenLayers: hiddenLayers.sorted()
        ).write(to: sessionURL)
    }

    // MARK: - Actions

    func select(_ name: String) {
        guard let place = Self.places.first(where: { $0.name == name }) else { return }
        placeName = name
        west = String(place.bbox.minLon)
        south = String(place.bbox.minLat)
        east = String(place.bbox.maxLon)
        north = String(place.bbox.maxLat)
    }

    /// Set the area from a rectangle drawn on the canvas.
    func setArea(_ bbox: BoundingBox) {
        west = String(format: "%.5f", bbox.minLon)
        south = String(format: "%.5f", bbox.minLat)
        east = String(format: "%.5f", bbox.maxLon)
        north = String(format: "%.5f", bbox.maxLat)
        // A hand-drawn area is not one of the saved places any more.
        placeName = ""
    }

    func toggleLayer(_ layerID: String) {
        if hiddenLayers.contains(layerID) {
            hiddenLayers.remove(layerID)
        } else {
            hiddenLayers.insert(layerID)
        }
    }

    /// Ask before an expensive fetch rather than during it.
    ///
    /// Kickoff detail 13: a 0.32° area with every OpenStreetMap layer took 331 s, of
    /// which 325 s was Overpass. A five-minute wait nobody agreed to reads as a
    /// hang.
    func update() {
        guard let bbox else {
            isError = true
            status = "Those coordinates do not make an area. West must be less than east, south less than north."
            return
        }
        if stack.isEnabled(SourceID.overpass),
           FetchCost.shouldWarn(bbox: bbox, layers: []),
           pendingWarning == nil {
            pendingWarning = FetchCost.warning(bbox: bbox)
            return
        }
        pendingWarning = nil
        fetch()
    }

    func fetch() {
        guard let bbox else { return }
        guard let plan = stack.plan else {
            isError = true
            status = "No sources selected. Tick at least one to build a map from."
            return
        }

        task?.cancel()
        isFetching = true
        isError = false
        progress = FetchProgress()
        status = "Fetching…"

        let manager = self.manager()
        let reporter = FetchReporter()
        let preset = self.preset
        let quality = self.quality
        let derivations = derivesAnything ? self.derivations : nil

        task = Task { [weak self] in
            // Watch the reporter so the status bar fills in as each source answers,
            // rather than jumping from empty to complete.
            let watcher = Task { [weak self] in
                for await snapshot in await reporter.updates() {
                    await MainActor.run { self?.progress = snapshot }
                }
            }
            defer { watcher.cancel() }

            do {
                let collection = try await manager.fetch(BBoxQuery(bbox: bbox), plan: plan, reporter: reporter)
                let built = try SceneBuilder(options: SceneBuilder.Options(
                    preset: preset, quality: quality, derivations: derivations
                )).build(from: collection)

                await MainActor.run {
                    guard let self else { return }
                    self.scene = built
                    self.drawnBBox = bbox
                    self.provenance = collection.provenance?.label
                    self.status = self.describe(built, collection: collection)
                    self.isError = false
                }
            } catch is FetchCancelled {
                // Cancel cannot pull a request out of its socket. It skips sources
                // that have not started, stops those that check between requests,
                // and discards the result rather than drawing it. The map already on
                // screen stays, which is the point.
                await MainActor.run {
                    self?.status = "Cancelled. The map on screen is the previous fetch."
                }
            } catch {
                await MainActor.run {
                    self?.isError = true
                    self?.status = "\(error)"
                }
            }

            await reporter.finish()
            await MainActor.run {
                self?.isFetching = false
                // Saved on completion rather than on every keystroke: this is the
                // moment the choices are known to describe a map that exists.
                self?.save()
            }
            await self?.refreshCacheSummary()
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func describe(_ scene: RenderScene, collection: FeatureCollection) -> String {
        var parts = [LayerInventory.summary(for: scene)]
        if let low = collection.metadata["elevation_min_metres"]?.doubleValue,
           let high = collection.metadata["elevation_max_metres"]?.doubleValue {
            parts.append(String(format: "%.0f m to %.0f m", low, high))
        }
        if let interval = collection.metadata["contour_interval_metres"]?.doubleValue {
            parts.append(String(format: "%.0f m interval", interval))
        }
        if collection.metadata["cancelled"]?.boolValue == true {
            parts.append("incomplete — the fetch was cancelled")
        }
        if let errors = collection.metadata["provider_errors"]?.stringValue {
            parts.append(errors)
        }
        return parts.joined(separator: " · ")
    }

    /// Build the providers for the ticked sources, applying their inline settings.
    private func manager() -> DataSourceManager {
        var providers: [any MapProvider] = []

        for id in stack.enabledIDs {
            let overrides = stack.providerOverrides(for: id)
            switch id {
            case SourceID.overpass:
                providers.append(OverpassProvider(cache: cache))

            case SourceID.terrainTiles:
                var settings = TerrainTileSettings()
                if let interval = overrides["contourIntervalMetres"]?.doubleValue, interval > 0 {
                    settings.contourIntervalMetres = interval
                }
                if let bands = overrides["elevationBandCount"]?.intValue {
                    settings.elevationBandCount = bands
                }
                providers.append(TerrainTileProvider(settings: settings))

            case SourceID.usgsEarthquakes:
                var settings = SeismicitySettings()
                if let days = overrides["days"]?.intValue { settings.days = days }
                if let magnitude = overrides["minMagnitude"]?.doubleValue {
                    settings.minMagnitude = magnitude
                }
                providers.append(USGSEarthquakeProvider(settings: settings))

            case SourceID.satelliteTracks:
                var settings = SatelliteTrackSettings()
                if let count = overrides["maxSatellites"]?.intValue { settings.maxSatellites = count }
                if let window = overrides["windowMinutes"]?.doubleValue {
                    settings.windowMinutes = window
                }
                providers.append(SatelliteTrackProvider(settings: settings, cache: cache))

            case SourceID.gibsImagery:
                var settings = SatelliteImagerySettings()
                if let layer = overrides["layer"]?.stringValue { settings.layer = layer }
                providers.append(GIBSImageryProvider(settings: settings))

            default:
                // A source with no provider yet is reported by the manager as "not
                // registered" rather than silently doing nothing.
                continue
            }
        }
        return DataSourceManager(providers: providers)
    }

    private func refreshCacheSummary() async {
        let bytes = await cache.totalBytes()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        await MainActor.run {
            cacheSummary = bytes > 0 ? "cached · \(formatter.string(fromByteCount: Int64(bytes)))" : ""
        }
    }

    func clearCache() {
        Task {
            await cache.removeAll()
            await refreshCacheSummary()
        }
    }

    // MARK: - Launch

    /// Open straight onto an area given on the command line:
    ///
    ///     Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48
    ///
    /// Useful on its own, and it is the only way to exercise the window's own draw
    /// path without a human clicking the button — driving the UI from a script needs
    /// accessibility permission this process has not been granted.
    func startIfRequestedOnLaunch() {
        restore()
        Task { await refreshCacheSummary() }

        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--preset"), flag + 1 < arguments.count {
            preset = Presets.preset(Presets.resolveName(arguments[flag + 1]))
        }
        // Tick extra sources on launch, so the composition can be checked from a
        // terminal: `--sources terrain_tiles` must *add* contours to the streets
        // rather than replace them.
        if let flag = arguments.firstIndex(of: "--sources"), flag + 1 < arguments.count {
            for id in arguments[flag + 1].split(separator: ",") {
                stack.setEnabled(String(id).trimmingCharacters(in: .whitespaces), true)
            }
        }
        // `--derive voronoi,hex` — the derived layers are off in every preset, so
        // without a switch there would be no way to look at one.
        if let flag = arguments.firstIndex(of: "--derive"), flag + 1 < arguments.count {
            for name in arguments[flag + 1].split(separator: ",") {
                switch name.trimmingCharacters(in: .whitespaces).lowercased() {
                case "voronoi": derivations.deriveVoronoi = true
                case "delaunay": derivations.deriveDelaunay = true
                case "hex", "hexgrid": derivations.deriveHexGrid = true
                case "circles", "packing": derivations.deriveCirclePacking = true
                default: continue
                }
            }
        }
        if let flag = arguments.firstIndex(of: "--bbox"), flag + 1 < arguments.count {
            let parts = arguments[flag + 1]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else {
                status = "--bbox needs four numbers: west,south,east,north"
                isError = true
                return
            }
            setArea(BoundingBox(minLon: parts[0], minLat: parts[1], maxLon: parts[2], maxLat: parts[3]))
            placeName = Self.places.first { $0.bbox == bbox }?.name ?? ""
        }

        guard let flag = arguments.firstIndex(of: "--render-to"), flag + 1 < arguments.count else {
            // No area asked for and nothing to render: open on the restored session
            // and wait to be told what to do.
            if arguments.contains("--bbox") {
                // An area on the command line is an explicit instruction, so it
                // skips the size warning.
                fetch()
            }
            return
        }

        fetch()
        renderWhenReady(to: URL(fileURLWithPath: arguments[flag + 1]))
    }

    /// Render the app's own scene to a PNG and quit.
    ///
    ///     Hipparchus.app/Contents/MacOS/Hipparchus --bbox … --render-to out.png
    ///
    /// This exists because a GUI cannot be asserted on. It exercises the path the
    /// window uses — this model's stack, manager, scene builder and renderer — and
    /// leaves a file that can be looked at, which is as close to "did the window
    /// draw?" as anything headless gets. It does **not** prove the SwiftUI layout is
    /// right; only a person looking at the window can say that.
    private func renderWhenReady(to url: URL) {
        Task { [weak self] in
            // Generous: a debug build contours roughly thirty times slower than a
            // release one, which is the difference between six seconds and three
            // minutes.
            for _ in 0..<3000 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                if !self.isFetching, self.scene != nil { break }
            }
            guard let self, let scene = self.visibleScene else {
                let why = self?.status ?? "the model went away"
                FileHandle.standardError.write(Data("nothing was drawn: \(why)\n".utf8))
                exit(1)
            }

            let status = self.status
            guard let image = CoreGraphicsRenderer().image(
                of: scene, size: CGSize(width: 1600, height: 1200)
            ) else {
                FileHandle.standardError.write(Data("the scene produced no image\n".utf8))
                exit(1)
            }

            // The app is sandboxed, so it may only write where the user has pointed
            // it — the save panel, or its own container. A path given here is
            // resolved into the container's Documents directory rather than taken
            // literally, because taking it literally fails silently-looking with a
            // permission error that reads like a rendering bug.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let destinationURL = documents.appendingPathComponent(url.lastPathComponent)

            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL, "public.png" as CFString, 1, nil
            ) else {
                FileHandle.standardError.write(
                    Data("could not write \(destinationURL.path)\n".utf8)
                )
                exit(1)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                FileHandle.standardError.write(Data("could not finalise the PNG\n".utf8))
                exit(1)
            }
            print("\(status)\nwrote \(destinationURL.path)")
            exit(0)
        }
    }

    // MARK: - Export

    func exportSVG() {
        export(type: .svg, extension: "svg") { scene, url in
            _ = try SVGExporter().write(scene, to: url)
        }
    }

    func exportPDF() {
        export(type: .pdf, extension: "pdf") { scene, url in
            try PDFExporter().write(scene, to: url)
        }
    }

    func exportPNG() {
        export(type: .png, extension: "png") { scene, url in
            guard let image = CoreGraphicsRenderer().image(
                of: scene, size: CGSize(width: 2400, height: 1800)
            ) else {
                throw ExportFailure.couldNotRender
            }
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil
            ) else {
                throw ExportFailure.couldNotRender
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ExportFailure.couldNotRender }
        }
    }

    enum ExportFailure: Error { case couldNotRender }

    private func export(
        type: UTType,
        extension suffix: String,
        write: (RenderScene, URL) throws -> Void
    ) {
        // Export what is on screen, hidden layers and all: what you see is what you
        // get, and a hidden layer reappearing in the file is a nasty surprise.
        guard let scene = visibleScene else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(placeName.isEmpty ? "map" : placeName.lowercased()).\(suffix)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try write(scene, url)
            status = "Exported \(url.lastPathComponent)."
            isError = false
        } catch {
            isError = true
            status = "Export failed: \(error)"
        }
    }
}
