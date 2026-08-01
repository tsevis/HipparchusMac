import Foundation
import HipparchusGeometry

/// Plugins: capabilities added to the app without changing the app.
///
/// Ported from `plugins/loader.py` and `plugins/interfaces.py`, with one
/// deliberate and unavoidable departure.
///
/// **The Python imports code; this does not.** There, a plugin is a Python
/// module with a `create_plugin()` factory, discovered with `pkgutil` and
/// imported at runtime. A sandboxed, hardened-runtime macOS app cannot do the
/// equivalent: library validation refuses to load code that is not signed by
/// the same team, so a user-supplied bundle would fail on every machine
/// including this one. Pretending otherwise would mean shipping a feature that
/// cannot work.
///
/// So a *user* plugin here is declarative — a folder with a `plugin.json` that
/// contributes presets, in the same format `PresetStore` reads, which makes a
/// plugin a shareable pack of styles. A *built-in* plugin is a Swift type, and
/// those are the ones that can contribute behaviour, exactly as the Python's
/// built-ins are the ones shipped inside the package.
///
/// Little is lost by this. The Python's plugin protocol has one implementation
/// and its `register()` returns `None`: what exists there is the wiring and
/// the fault isolation, and both are reproduced here exactly.

/// What a plugin adds to the app.
///
/// Deliberately a value handed to `register` rather than a global registry the
/// way the Python describes it: a plugin that fails half-way through
/// registering must not leave its first half behind, and a value that is only
/// committed on success cannot.
public struct PluginRegistry: Sendable {
    /// Styles contributed by plugins, on top of the sixteen built in.
    public private(set) var presets: [ArtisticPreset] = []
    /// Areas contributed by plugins, on top of the ones built in.
    ///
    /// A pack of places is the other obvious thing to hand round — "the Greek
    /// islands", "European capitals" — and it needs no new machinery: the
    /// loader, the fault isolation and the name checking are already here.
    public private(set) var places: [SavedPlace] = []

    public init() {}

    /// Refuses a name already taken, on the same grounds as a preset: two
    /// plugins fighting over one name is worse than one of them not loading.
    public mutating func add(_ place: SavedPlace, reservedNames: Set<String>) throws {
        guard !reservedNames.contains(place.name) else {
            throw PluginError.placeNameTaken(place.name, by: "a built-in place")
        }
        guard !places.contains(where: { $0.name == place.name }) else {
            throw PluginError.placeNameTaken(place.name, by: "another plugin")
        }
        places.append(place)
    }

    /// Refuses a name already taken. A plugin silently redefining a built-in
    /// style is how a map comes to look different for a reason nobody can
    /// find, and two plugins fighting over one name is worse.
    public mutating func add(_ preset: ArtisticPreset) throws {
        guard !Presets.names.contains(preset.name) else {
            throw PluginError.presetNameTaken(preset.name, by: "a built-in preset")
        }
        guard !presets.contains(where: { $0.name == preset.name }) else {
            throw PluginError.presetNameTaken(preset.name, by: "another plugin")
        }
        presets.append(preset)
    }
}

/// An area worth returning to, by name.
///
/// Deliberately not the app's own `Place`: that lives beside the window, and
/// a plugin is read down here where there is no window.
public struct SavedPlace: Sendable, Equatable, Identifiable {
    public let name: String
    public let bbox: BoundingBox

    public var id: String { name }

    public init(name: String, bbox: BoundingBox) {
        self.name = name
        self.bbox = bbox
    }
}

public protocol Plugin: Sendable {
    var id: String { get }
    var name: String { get }
    /// Add whatever this plugin offers. Throwing is how a plugin refuses to
    /// load; the loader catches it and carries on with the others.
    func register(into registry: inout PluginRegistry) throws
}

/// A plugin that loaded, and where it came from.
public struct LoadedPlugin: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// `built-in`, or the folder a user plugin was read from. The Python calls
    /// this the module; a path is this port's equivalent answer to the same
    /// question — *which one of these is it?*
    public let origin: String

    public init(id: String, name: String, origin: String) {
        self.id = id
        self.name = name
        self.origin = origin
    }
}

public enum PluginError: Error, CustomStringConvertible {
    case noManifest(String)
    case noIdentifier
    case duplicateIdentifier(String)
    case presetNameTaken(String, by: String)
    case placeNameTaken(String, by: String)
    case notAnArea(String)

    public var description: String {
        switch self {
        case .noManifest(let name): "no plugin.json in \(name)"
        case .noIdentifier: "the manifest has no id"
        case .duplicateIdentifier(let id): "another plugin already claims the id \(id)"
        case .presetNameTaken(let name, let holder): "the preset name “\(name)” is already used by \(holder)"
        case .placeNameTaken(let name, let holder): "the place name “\(name)” is already used by \(holder)"
        case .notAnArea(let name): "“\(name)” is not an area: west must be less than east, south less than north"
        }
    }
}

/// Finds plugins, registers them, and keeps going when one of them fails.
///
/// Fault isolation is the whole job. One broken plugin must cost exactly
/// itself: it is named in `loadErrors` and everything else still loads. That
/// is the Python's behaviour and the only property of this worth having.
public final class PluginLoader: @unchecked Sendable {
    public let builtins: [any Plugin]
    public let userPluginDirectory: URL

    public private(set) var loadedPlugins: [LoadedPlugin] = []
    public private(set) var loadErrors: [String] = []

    /// - Parameter reservedPlaceNames: the areas the app already ships, so a
    ///   plugin adding one of those names is refused rather than shadowing it.
    public init(
        builtins: [any Plugin] = PluginLoader.defaultBuiltins,
        userPluginDirectory: URL,
        reservedPlaceNames: Set<String> = []
    ) {
        self.builtins = builtins
        self.userPluginDirectory = userPluginDirectory
        self.reservedPlaceNames = reservedPlaceNames
    }

    public let reservedPlaceNames: Set<String>

    /// Where a user drops a plugin folder. Beside the presets and the session,
    /// for the same reason: somewhere findable in Finder.
    public static func defaultUserPluginDirectory(subdirectory: String = "Hipparchus") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent(subdirectory).appendingPathComponent("Plugins")
    }

    /// The plugins compiled in. The Python ships one that registers nothing,
    /// to prove the wiring; this ships none, because the wiring is proved by
    /// the tests instead and an inert entry in a user-visible list is furniture.
    public static let defaultBuiltins: [any Plugin] = []

    @discardableResult
    public func loadAll() -> PluginRegistry {
        loadedPlugins = []
        loadErrors = []
        var registry = PluginRegistry()
        var claimed: Set<String> = []

        for plugin in builtins {
            load(plugin, origin: "built-in", into: &registry, claimed: &claimed)
        }
        for outcome in userManifests() {
            switch outcome {
            case .loaded(let plugin):
                load(plugin, origin: plugin.origin, into: &registry, claimed: &claimed)
            case .failed(let note):
                loadErrors.append(note)
            }
        }
        return registry
    }

    /// Register one plugin, or record why not. Registration happens against a
    /// copy, so a plugin that throws part-way leaves nothing behind.
    private func load(
        _ plugin: any Plugin, origin: String, into registry: inout PluginRegistry, claimed: inout Set<String>
    ) {
        let identifier = plugin.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            loadErrors.append("\(origin): \(PluginError.noIdentifier)")
            return
        }
        // Named by id *and* where it came from, because either alone leaves a
        // question: several built-ins share the origin "built-in", and a folder
        // name is not what the plugin calls itself.
        let label = "\(identifier) (\(origin))"

        guard !claimed.contains(identifier) else {
            loadErrors.append("\(label): \(PluginError.duplicateIdentifier(identifier))")
            return
        }

        var candidate = registry
        do {
            try plugin.register(into: &candidate)
        } catch {
            loadErrors.append("\(label): \(error)")
            return
        }
        registry = candidate
        claimed.insert(identifier)
        loadedPlugins.append(
            LoadedPlugin(id: identifier, name: plugin.name, origin: origin)
        )
    }

    // MARK: - User plugins on disk

    /// Every folder in the plugin directory, read in a fixed order.
    ///
    /// Sorted by folder name so the same set of plugins always loads in the
    /// same order — which is what makes "two plugins claim one id" resolve to
    /// the same winner every launch rather than to whichever the filesystem
    /// happened to name first.
    private func userManifests() -> [ManifestOutcome] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: userPluginDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let children = try? manager.contentsOfDirectory(
                  at: userPluginDirectory, includingPropertiesForKeys: [.isDirectoryKey]
              )
        else {
            // No plugin folder is the normal state, not a fault.
            return []
        }

        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(read)
    }

    private func read(_ folder: URL) -> ManifestOutcome {
        let name = folder.lastPathComponent
        let manifest = folder.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            return .failed("\(name): \(PluginError.noManifest(name))")
        }
        do {
            let decoded = try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: manifest))
            return .loaded(ManifestPlugin(
                manifest: decoded, origin: folder.path, reservedPlaceNames: reservedPlaceNames
            ))
        } catch {
            return .failed("\(name): \(error.localizedDescription)")
        }
    }
}

// MARK: - A plugin described by a file rather than written in code

/// A folder either produced a plugin or a reason it did not. Not `Result`,
/// whose failure has to be an `Error`, and the reason here is a sentence meant
/// for the person looking at the plugin list.
private enum ManifestOutcome {
    case loaded(ManifestPlugin)
    case failed(String)
}

private struct Manifest: Decodable {
    let id: String
    let name: String?
    /// `StoredPreset` — the very shape `PresetStore` writes. Shared rather than
    /// re-declared, so a style saved from the app can be dropped into a plugin
    /// folder unchanged, and so the two readers cannot drift apart.
    let presets: [StoredPreset]?
    let places: [StoredPlace]?
}

/// One area as a plugin states it — the same four numbers, in the same order,
/// as this app's own `--bbox` and every saved session.
private struct StoredPlace: Decodable {
    let name: String
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    /// `nil` when the numbers do not describe an area. Refused rather than
    /// corrected: a box with west east of east is a mistake in the file, and
    /// silently swapping them hides whatever produced it.
    var place: SavedPlace? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, west < east, south < north,
              (-180...180).contains(west), (-180...180).contains(east),
              (-90...90).contains(south), (-90...90).contains(north)
        else {
            return nil
        }
        return SavedPlace(
            name: trimmed,
            bbox: BoundingBox(minLon: west, minLat: south, maxLon: east, maxLat: north)
        )
    }
}

private struct ManifestPlugin: Plugin {
    let manifest: Manifest
    let origin: String
    /// Names the app already uses, so a plugin cannot quietly redefine one.
    let reservedPlaceNames: Set<String>

    var id: String { manifest.id }
    var name: String { manifest.name ?? manifest.id }

    func register(into registry: inout PluginRegistry) throws {
        for stored in manifest.presets ?? [] {
            guard let preset = stored.preset else { continue }
            try registry.add(preset)
        }
        for stored in manifest.places ?? [] {
            guard let place = stored.place else {
                throw PluginError.notAnArea(stored.name)
            }
            try registry.add(place, reservedNames: reservedPlaceNames)
        }
    }
}
