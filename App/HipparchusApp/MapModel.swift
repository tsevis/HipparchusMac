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

    var west = "25.32" { didSet { record() } }
    var south = "36.33" { didSet { record() } }
    var east = "25.50" { didSet { record() } }
    var north = "36.48" { didSet { record() } }
    var placeName = "Santorini" { didSet { record() } }

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

    var stack = SourceStack() { didSet { record() } }
    var preset = Presets.preset("Hypsometric Relief") {
        didSet {
            guard oldValue.name != preset.name else { return }
            // A preset's tuned derivation sizes come with it — Fragmented Urban
            // means 45-metre hexes, Technical Blueprint 70 — while the switches
            // stay where the user put them. Without this the tables carried
            // sizes nothing could ever read: `derivations` starts at the struct
            // defaults and replaces the preset's profile wholesale.
            adoptDerivationSizes(from: preset)
            record()
        }
    }
    var quality = Quality.default {
        didSet {
            guard oldValue.key != quality.key else { return }
            record()
        }
    }

    /// Which derived layers to invent on top of the map.
    ///
    /// Held apart from the preset because no preset enables one — all sixteen style
    /// the four derived layers and three tune their sizes, but every switch is off,
    /// here and in the Python. This is the switch.
    var derivations = GeometryPipelineProfile() { didSet { record() } }

    var derivesAnything: Bool {
        derivations.deriveVoronoi || derivations.deriveDelaunay
            || derivations.deriveHexGrid || derivations.deriveCirclePacking
    }

    /// Layers the user has hidden by hand. Kept separately from the scene so a
    /// re-fetch does not silently turn hidden layers back on.
    var hiddenLayers: Set<String> = [] { didSet { record() } }

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

    // MARK: - Export composition

    /// Page and furniture for the SVG export. Transient and all off by default,
    /// as the Python keeps them: furniture is asked for per export, not
    /// remembered as map state — which is also why none of this is undoable.
    var svgComposition = SVGExporter.Composition()
    /// Paint the ground in the export. Off gives a transparent SVG for
    /// compositing; dark presets need it on to be legible.
    var svgIncludeBackground = true

    // MARK: - Searching for a place

    var searchQuery = ""
    private(set) var searchResults: [GeocodedPlace] = []
    private(set) var isSearching = false
    private(set) var searchMessage: String?

    private var searchTask: Task<Void, Never>?
    /// Held for the app's lifetime rather than made fresh per search: its rate
    /// limiter only enforces Nominatim's one-request-a-second policy if it
    /// persists across calls.
    private let nominatim = NominatimGeocoder()

    /// Look up whatever is in the box.
    ///
    /// On submit rather than on every keystroke: both searches below are network
    /// calls, and firing one per character is rude to a shared service and
    /// useless to someone half-way through typing "Thessaloniki".
    ///
    /// Two geocoders, not one. MapKit is good at landmarks and addresses and
    /// unreliable at named geographic areas — asked for "Lesvos" it can answer
    /// with a taverna in Athens and never mention the island. Nominatim indexes
    /// OpenStreetMap's own boundaries, so it answers the island reliably but
    /// would miss a specific café. Queried together and merged, a real place
    /// reads first and neither gap shows.
    func searchForPlace() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchMessage = nil

        guard query.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        searchTask = Task { [weak self, nominatim] in
            // Neither search's failure should hide the other's answer: a
            // Nominatim timeout must not erase a MapKit result that arrived
            // fine, and the reverse. Only when *both* fail is this reported as a
            // failure — said plainly, because a search that failed is not a
            // place that does not exist, and the difference matters when the
            // wifi is off.
            async let mapKit = Self.attempt { try await PlaceSearch().search(query) }
            async let osm = Self.attempt { try await nominatim.search(query) }
            let (mapKitResult, osmResult) = await (mapKit, osm)

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isSearching = false
                if case .failure(let error) = mapKitResult, case .failure = osmResult {
                    self.searchResults = []
                    self.searchMessage = "Could not search: \(error.localizedDescription)"
                    return
                }
                let found = PlaceSearchMerge.merge(
                    nominatim: (try? osmResult.get()) ?? [],
                    mapKit: (try? mapKitResult.get()) ?? []
                )
                self.searchResults = found
                self.searchMessage = found.isEmpty ? "Nothing found for “\(query)”." : nil
            }
        }
    }

    /// Run one search, keeping its failure to report rather than throwing it
    /// away — so two geocoders can be tried together without either's error
    /// silently winning over the other's success.
    private static func attempt<T>(_ body: () async throws -> T) async -> Swift.Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Take a found place as the area. Does not fetch — pressing Update map is
    /// still the user's decision, and a search that framed the wrong Springfield
    /// should not have cost a minute of Overpass time.
    func adopt(_ result: GeocodedPlace) {
        pendingAction = ("Choose Place", "area")
        setArea(result.bbox)
        placeName = result.name
        searchQuery = result.name
        searchResults = []
        searchMessage = nil
    }

    func clearSearch() {
        searchTask?.cancel()
        searchResults = []
        searchMessage = nil
        isSearching = false
    }

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

    // MARK: - Undo

    /// The window's undo manager, handed in by the view. ⌘Z and the Edit menu
    /// come through it, but the truth lives in `history` — an `UndoManager`
    /// cannot be inspected or tested, and a value type can.
    weak var undoManager: UndoManager?

    private var history = SessionHistory(initial: Session())

    /// True while a snapshot is being applied, so restoring a state is never
    /// recorded as a fresh action.
    private var isRestoringState = false

    /// Set by an action method to name the boundary its mutations make, consumed
    /// by the first record. "Choose Place" is one intention; without this it
    /// would record as five separate "Change Area"s.
    private var pendingAction: (name: String, key: String?)?

    /// The choices as they stand, or nil while the coordinate boxes hold
    /// something that is not an area yet — a half-typed number is not a state
    /// worth returning to, and coalescing folds it into the keystrokes around it.
    private func currentSession() -> Session? {
        guard let bbox else { return nil }
        return Session(
            stack: stack,
            area: Session.Area(bbox),
            placeName: placeName,
            preset: preset.name,
            quality: quality.key,
            hiddenLayers: hiddenLayers.sorted(),
            derived: Session.Derived(derivations)
        )
    }

    /// Record whatever just changed, named by diffing the session against the
    /// one the history already holds.
    ///
    /// Every property observer calls this and none of them decides anything:
    /// the naming rules are `SessionEdit`, in the package, where they are tested.
    private func record() {
        guard !isRestoringState else {
            pendingAction = nil
            return
        }
        guard let session = currentSession() else { return }

        let named = pendingAction.map { SessionEdit.Description(action: $0.name, coalescingKey: $0.key) }
            ?? SessionEdit.describe(from: history.current.session, to: session)
        pendingAction = nil
        guard let named else { return }

        if history.record(
            session, action: named.action, coalescing: named.coalescingKey,
            at: Date().timeIntervalSinceReferenceDate
        ) {
            registerBoundary(named: named.action)
        }
    }

    /// Take the preset's derivation sizes without making a second undo entry:
    /// changing preset is one action, and the sizes it brings are part of it.
    private func adoptDerivationSizes(from preset: ArtisticPreset) {
        let wasRestoring = isRestoringState
        isRestoringState = true
        defer { isRestoringState = wasRestoring }
        derivations.hexRadius = preset.geometryProfile.hexRadius
        derivations.circleMinRadius = preset.geometryProfile.circleMinRadius
        derivations.circleMaxRadius = preset.geometryProfile.circleMaxRadius
    }


    /// One `UndoManager` registration per history boundary, so ⌘Z steps map one
    /// to one onto intentions.
    private func registerBoundary(named name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.performUndo() }
        }
        undoManager.setActionName(name)
    }

    func performUndo() {
        // The name of what is being taken back becomes the redo title.
        let name = history.undoActionName
        guard let snapshot = history.undo() else { return }
        apply(snapshot)
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.performRedo() }
            }
            if let name { undoManager.setActionName(name) }
        }
    }

    func performRedo() {
        let name = history.redoActionName
        guard let snapshot = history.redo() else { return }
        apply(snapshot)
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.performUndo() }
            }
            if let name { undoManager.setActionName(name) }
        }
    }

    /// Put a snapshot on screen: the choices, and the scene that was drawn under
    /// them. Never fetches — that is the whole point.
    private func apply(_ snapshot: SessionHistory.Snapshot) {
        isRestoringState = true
        defer { isRestoringState = false }

        let session = snapshot.session
        stack = session.stack()
        preset = Presets.preset(session.presetName)
        quality = Quality.profile(session.qualityKey)
        hiddenLayers = Set(session.hiddenLayers)
        session.derived.apply(to: &derivations)
        placeName = session.placeName
        west = String(session.area.west)
        south = String(session.area.south)
        east = String(session.area.east)
        north = String(session.area.north)

        scene = history.scene(for: snapshot.sceneToken)
        drawnBBox = scene?.bbox
        if snapshot.sceneToken != nil, scene == nil {
            // The honest case: the history keeps every choice but only the newest
            // few maps. Saying so beats quietly spending minutes re-fetching.
            status = "That map was let go to save memory. Press Update map to redraw it."
            isError = false
        }
    }

    // MARK: - Remembering

    /// Restore what the app was doing last time.
    ///
    /// Only the choices, never the map: a saved session says which sources were
    /// ticked and where you were looking, and pressing Update map is left to you.
    /// Re-fetching on launch would mean opening the app could cost five minutes of
    /// Overpass time nobody asked for.
    func restore() {
        isRestoringState = true
        defer { isRestoringState = false }

        let session = Session.read(from: sessionURL)
        stack = session.stack()
        preset = Presets.preset(session.presetName)
        quality = Quality.profile(session.qualityKey)
        hiddenLayers = Set(session.hiddenLayers)
        session.derived.apply(to: &derivations)
        placeName = session.placeName
        west = String(session.area.west)
        south = String(session.area.south)
        east = String(session.area.east)
        north = String(session.area.north)

        // History begins here: opening the app is not an action to undo.
        history = SessionHistory(initial: session)
    }

    /// A failure to save is worth nothing more than the settings: it must never
    /// interrupt what the user was doing.
    func save() {
        guard let session = currentSession() else { return }
        try? session.write(to: sessionURL)
    }

    // MARK: - Actions

    func select(_ name: String) {
        guard let place = Self.places.first(where: { $0.name == name }) else { return }
        pendingAction = ("Choose Place", "area")
        placeName = name
        west = String(place.bbox.minLon)
        south = String(place.bbox.minLat)
        east = String(place.bbox.maxLon)
        north = String(place.bbox.maxLat)
    }

    /// Set the area from a rectangle drawn on the canvas.
    func setArea(_ bbox: BoundingBox) {
        // Adopted searches route through here already carrying their own name.
        if pendingAction == nil { pendingAction = ("Draw Area", "area") }
        west = String(format: "%.5f", bbox.minLon)
        south = String(format: "%.5f", bbox.minLat)
        east = String(format: "%.5f", bbox.maxLon)
        north = String(format: "%.5f", bbox.maxLat)
        // A hand-drawn area is not one of the saved places any more.
        placeName = ""
    }

    /// Whether a show-all or hide-all would do anything. The view asks rather
    /// than deciding for itself.
    var hasToggleableLayers: Bool {
        scene.map { !LayerInventory.toggleableLayerIDs(in: $0).isEmpty } ?? false
    }

    /// Show or hide every populated layer at once.
    ///
    /// One action to a person, so one entry in the history — named for what was
    /// asked rather than for whichever layer happened to differ first.
    func setAllLayers(visible: Bool) {
        guard let scene else { return }
        let updated = LayerInventory.hiddenLayers(
            in: scene, settingAllVisible: visible, from: hiddenLayers
        )
        guard updated != hiddenLayers else { return }
        pendingAction = (visible ? "Show All Layers" : "Hide All Layers", nil)
        hiddenLayers = updated
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
                    // A fetch is an action: undo restores the previous scene from
                    // the history's store, and never re-fetches — undo must not
                    // cost minutes to take back something that cost minutes.
                    if let session = self.currentSession() {
                        self.history.recordFetch(
                            session, scene: built, at: Date().timeIntervalSinceReferenceDate
                        )
                        self.registerBoundary(named: "Fetch Map")
                    }
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
        // Whether the answer came off the disk or off the network. The manager
        // namespaces every provider key, so this reads "<source>.cache" rather
        // than "cache" — which is why nothing had been reading it at all.
        let cacheStates = collection.metadata
            .filter { $0.key.hasSuffix(".cache") }
            .compactMap { $0.value.stringValue }
        if !cacheStates.isEmpty, cacheStates.allSatisfy({ $0 == "hit" }) {
            parts.append("from cache")
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
                var settings = OverpassSettings()
                if let timeout = overrides["timeoutSeconds"]?.doubleValue, timeout > 0 {
                    settings.timeoutSeconds = timeout
                }
                if let rate = overrides["requestsPerSecond"]?.doubleValue, rate > 0 {
                    settings.requestsPerSecond = rate
                }
                if let endpoint = overrides["endpoint"]?.stringValue, !endpoint.isEmpty {
                    // Chosen first, the rest still tried after it: a mirror that
                    // is refusing today should not become a dead end.
                    settings.endpoint = endpoint
                }
                providers.append(OverpassProvider(settings: settings, cache: cache))

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

            case SourceID.simulatedTerrain:
                var settings = TerrainFieldSettings()
                if let seed = overrides["seed"]?.intValue { settings.seed = seed }
                providers.append(SimulatedFieldProvider(settings: settings))

            case SourceID.localOSMPBF, SourceID.vectorTiles,
                 SourceID.naturalEarth, SourceID.overture:
                // The stack refuses to tick one of these without a path, so by the
                // time it is enabled there is a file to read.
                let file = stack.path(id)
                guard !file.isEmpty else { continue }
                providers.append(FileSourceProvider(
                    providerID: id,
                    label: stack.definition(id)?.label ?? id,
                    path: URL(fileURLWithPath: file)
                ))

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

        // Launch flags are setup, not actions: nothing done here should land in
        // the undo history, so the flag-driven mutations happen restoring-style
        // and the history is reseeded when they are done.
        isRestoringState = true

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
        if let flag = arguments.firstIndex(of: "--rotate"), flag + 1 < arguments.count {
            renderRotation = Double(arguments[flag + 1]) ?? 0
        }
        if let flag = arguments.firstIndex(of: "--bbox"), flag + 1 < arguments.count {
            let parts = arguments[flag + 1]
                .split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4 else {
                status = "--bbox needs four numbers: west,south,east,north"
                isError = true
                isRestoringState = false
                return
            }
            setArea(BoundingBox(minLon: parts[0], minLat: parts[1], maxLon: parts[2], maxLat: parts[3]))
            placeName = Self.places.first { $0.bbox == bbox }?.name ?? ""
        }

        // Setup is done; from here every change — including a launch fetch when
        // it completes — is the user's history.
        isRestoringState = false
        pendingAction = nil
        if let session = currentSession() {
            history = SessionHistory(initial: session)
        }

        // `--search "Santorini"` — the search is a network call into MapKit, and a
        // window nobody can screenshot is a poor place to find out it does not work.
        if let flag = arguments.firstIndex(of: "--search"), flag + 1 < arguments.count {
            searchAndReport(arguments[flag + 1], thenRenderTo: arguments.firstIndex(of: "--render-to")
                .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil })
            return
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

    /// Search for a place, print what came back, and optionally draw the first hit.
    ///
    ///     Hipparchus.app/Contents/MacOS/Hipparchus --search "Santorini" --render-to s.png
    ///
    /// Exists for the same reason `--render-to` does: this path goes out to the
    /// network from inside a sandbox, and a text field nobody can screenshot is a
    /// poor place to discover it was never entitled to.
    private func searchAndReport(_ query: String, thenRenderTo output: String?) {
        Task { [weak self, nominatim] in
            async let mapKit = Self.attempt { try await PlaceSearch().search(query) }
            async let osm = Self.attempt { try await nominatim.search(query) }
            let (mapKitResult, osmResult) = await (mapKit, osm)

            if case .failure(let error) = mapKitResult, case .failure = osmResult {
                FileHandle.standardError.write(Data("search failed: \(error)\n".utf8))
                exit(1)
            }
            let results = PlaceSearchMerge.merge(
                nominatim: (try? osmResult.get()) ?? [],
                mapKit: (try? mapKitResult.get()) ?? []
            )

            guard let first = results.first else {
                FileHandle.standardError.write(Data("nothing found for \(query)\n".utf8))
                exit(1)
            }

            for result in results {
                let bbox = result.bbox
                print(String(
                    format: "%@%@  %.4f,%.4f → %.4f,%.4f  (%.3f° × %.3f°)",
                    result.name,
                    result.detail.isEmpty ? "" : " — \(result.detail)",
                    bbox.minLon, bbox.minLat, bbox.maxLon, bbox.maxLat,
                    abs(bbox.lonSpan), abs(bbox.latSpan)
                ))
            }

            guard let output else { exit(0) }
            await MainActor.run {
                self?.adopt(first)
                self?.fetch()
            }
            self?.renderWhenReady(to: URL(fileURLWithPath: output))
        }
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
    /// Degrees for `--rotate`, applied to the headless render.
    ///
    /// The rotate controls live on a canvas nobody can screenshot, so without a
    /// flag there is no way to check that a turned map is drawn rather than
    /// merely computed — which is exactly the distinction that caught the
    /// transform turning about the origin.
    private var renderRotation = 0.0

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
                of: scene,
                size: CGSize(width: 1600, height: 1200),
                viewport: ViewportState().rotated(to: self.renderRotation)
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
        var options = SVGExporter.Options()
        options.composition = svgComposition
        options.includeBackground = svgIncludeBackground
        // The quality profile decides coordinate fidelity: Print Export writes
        // six decimals, Clean Export four. Until this was wired the profile made
        // no difference to the file at all.
        options.precision = quality.svgPrecision
        let size = svgComposition.exportSize(
            canvasWidth: options.width, canvasHeight: options.height
        )
        options.width = size.width
        options.height = size.height
        export(type: .svg, extension: "svg") { [weak self] scene, url in
            let diagnostics = try SVGExporter(options: options).write(scene, to: url)
            // The diagnostics belong beside the file, as the Python writes them:
            // a map separated from this conversation should still be able to say
            // what it counted. The sandbox grants access to the file the user
            // named, and a sibling write may be refused — so a failed sidecar
            // must never fail the export that succeeded.
            let sidecar = url.appendingPathExtension("diagnostics.json")
            do {
                try diagnostics.jsonData().write(to: sidecar, options: .atomic)
            } catch {
                self?.sidecarNote = " (diagnostics could not be written beside it)"
            }
        }
    }

    /// Appended to the export message when the sidecar could not be written.
    private var sidecarNote = ""

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
            sidecarNote = ""
            try write(scene, url)
            status = "Exported \(url.lastPathComponent).\(sidecarNote)"
            isError = false
        } catch {
            isError = true
            status = "Export failed: \(error)"
        }
    }
}
