import Foundation

/// Composable map sources.
///
/// Ported from `application/source_stack.py`.
///
/// This is the single most important idea in the interface: **a map is built from
/// sources, and sources stack**. Ticking Elevation onto a street map adds contours
/// to it; it never throws the streets away. It replaced four overlapping ideas —
/// Model, Source Library, Map Sources and a one-off Relief toggle — and a model
/// dropdown that silently discarded the rest of the map.
///
/// The rules worth testing are all here, and none of them need a display to
/// exercise. The views bind to this; they do not reimplement it.
///
/// **One deliberate departure from the Python.** There, `plan()` resolves the
/// ticked sources into a legacy "map model id plus extra providers" pair, through a
/// lookup table mapping each source onto a single-provider model — an indirection
/// the module's own docstring attributes to what the data-source manager happened
/// to accept. That manager is being written here rather than inherited, so the plan
/// names the sources directly. The rule the table encoded is kept exactly:
/// OpenStreetMap becomes the base whenever it is ticked, otherwise the first ticked
/// source does.

/// What a source is, as the sidebar describes it.
///
/// Deliberately not `Provenance`, which is what a *feature* claims. The two
/// vocabularies overlap but are not the same, and the Python keeps them apart for
/// the same reason: `live` says the source is a database queried at fetch time,
/// which is a statement about the pipe rather than about the ground. The features
/// that arrive through it still claim `measured`.
public enum SourceProvenance: String, Sendable, Equatable, CaseIterable {
    case live
    case measured
    case synthetic
    case uncalibrated
    case approximate
}

/// One knob belonging to a source, shown inline under it in the sidebar.
public struct SourceSetting: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case number
        case choice
    }

    /// Deliberately narrow. A setting is a number or one of a few strings; anything
    /// richer belongs in the provider's own settings type rather than on a knob.
    public enum Value: Sendable, Equatable {
        case number(Double)
        case integer(Int)
        case text(String)

        public var doubleValue: Double? {
            switch self {
            case .number(let value): value
            case .integer(let value): Double(value)
            case .text: nil
            }
        }

        public var intValue: Int? {
            switch self {
            case .number(let value): Int(value)
            case .integer(let value): value
            case .text: nil
            }
        }

        public var stringValue: String? {
            if case .text(let value) = self { return value }
            return nil
        }
    }

    public let key: String
    public let label: String
    public let kind: Kind
    public let value: Value
    public let choices: [Value]
    public let suffix: String
    /// Where this lands on the provider's settings object. Empty means `key` is
    /// already the field name.
    public let attribute: String

    public var id: String { key }

    /// The provider field this setting writes to.
    public var target: String { attribute.isEmpty ? key : attribute }

    public init(
        _ key: String,
        _ label: String,
        _ kind: Kind,
        _ value: Value,
        choices: [Value] = [],
        suffix: String = "",
        attribute: String = ""
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.value = value
        self.choices = choices
        self.suffix = suffix
        self.attribute = attribute
    }

    public func withValue(_ value: Value) -> SourceSetting {
        SourceSetting(key, label, kind, value, choices: choices, suffix: suffix, attribute: attribute)
    }

    /// What the sidebar shows. A whole number reads as `20 m`, not `20.0 m`.
    public var display: String {
        let shown: String = switch value {
        case .number(let number):
            number == number.rounded() ? String(Int(number)) : String(number)
        case .integer(let number): String(number)
        case .text(let text): text
        }
        return suffix.isEmpty ? shown : "\(shown) \(suffix)"
    }
}

/// A source the map can be built from.
public struct SourceDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let subtitle: String
    public let provenance: SourceProvenance
    public let settings: [SourceSetting]
    /// Sources needing a file on disk stay listed but cannot be ticked until one is
    /// chosen, so the stack shows the whole menu rather than hiding what is missing.
    public let needsPath: Bool
    public let defaultEnabled: Bool

    public init(
        id: String,
        label: String,
        subtitle: String,
        provenance: SourceProvenance,
        settings: [SourceSetting] = [],
        needsPath: Bool = false,
        defaultEnabled: Bool = false
    ) {
        self.id = id
        self.label = label
        self.subtitle = subtitle
        self.provenance = provenance
        self.settings = settings
        self.needsPath = needsPath
        self.defaultEnabled = defaultEnabled
    }

    public func setting(_ key: String) -> SourceSetting? {
        settings.first { $0.key == key }
    }
}

/// What the data-source manager should be asked for.
public struct FetchPlan: Sendable, Equatable {
    /// The source the rest stack onto.
    public let base: String
    public let extras: [String]

    public init(base: String, extras: [String] = []) {
        self.base = base
        self.extras = extras
    }

    /// Every source to fetch, base first.
    public var sourceIDs: [String] { [base] + extras }
}

public enum SourceID {
    public static let overpass = "overpass"
    public static let terrainTiles = "terrain_tiles"
    public static let gibsImagery = "gibs_imagery"
    public static let usgsEarthquakes = "usgs_earthquakes"
    public static let satelliteTracks = "satellite_tracks"
    public static let simulatedTerrain = "simulated_terrain"
    public static let localOSMPBF = "local_osm_pbf"
    public static let vectorTiles = "vector_tiles"
    public static let naturalEarth = "natural_earth"
    public static let overture = "overture"
}

/// Which sources are ticked, and what to fetch as a result.
public struct SourceStack: Sendable, Equatable {

    /// The stack as it appears in the sidebar, top to bottom.
    public static let defaultDefinitions: [SourceDefinition] = [
        SourceDefinition(
            id: SourceID.overpass,
            label: "OpenStreetMap",
            subtitle: "streets · places · water",
            provenance: .live,
            defaultEnabled: true
        ),
        SourceDefinition(
            id: SourceID.terrainTiles,
            label: "Elevation",
            subtitle: "contours · bands · summits",
            provenance: .measured,
            settings: [
                // Zero means "choose a round interval from the relief actually in
                // view", which is kickoff detail 7. A fixed interval empties a small
                // window and floods a large one.
                SourceSetting("interval", "Interval", .number, .number(0), suffix: "m",
                              attribute: "contourIntervalMetres"),
                SourceSetting("bands", "Bands", .number, .integer(10),
                              attribute: "elevationBandCount"),
            ]
        ),
        SourceDefinition(
            id: SourceID.gibsImagery,
            label: "Night lights",
            subtitle: "NASA GIBS",
            provenance: .uncalibrated,
            settings: [
                SourceSetting("layer", "Layer", .choice, .text("VIIRS_Black_Marble"),
                              choices: [.text("VIIRS_Black_Marble")], attribute: "layer"),
            ]
        ),
        SourceDefinition(
            id: SourceID.usgsEarthquakes,
            label: "Earthquakes",
            subtitle: "USGS event catalogue",
            provenance: .measured,
            settings: [
                SourceSetting("days", "Window", .number, .integer(1825), suffix: "days",
                              attribute: "days"),
                SourceSetting("magnitude", "Minimum", .number, .number(2.5), suffix: "M",
                              attribute: "minMagnitude"),
            ]
        ),
        SourceDefinition(
            id: SourceID.satelliteTracks,
            label: "Satellite tracks",
            subtitle: "Celestrak elements",
            provenance: .approximate,
            settings: [
                SourceSetting("satellites", "Show", .number, .integer(12),
                              attribute: "maxSatellites"),
                SourceSetting("window", "Ahead", .number, .number(200), suffix: "min",
                              attribute: "windowMinutes"),
            ]
        ),
        SourceDefinition(
            id: SourceID.simulatedTerrain,
            label: "Simulated terrain",
            subtitle: "generated field, offline",
            provenance: .synthetic,
            settings: [
                SourceSetting("seed", "Seed", .number, .integer(1729), attribute: "seed"),
            ]
        ),
        SourceDefinition(
            id: SourceID.localOSMPBF,
            label: "Local OSM extract",
            subtitle: "offline .osm.pbf",
            provenance: .live,
            needsPath: true
        ),
        SourceDefinition(
            id: SourceID.vectorTiles,
            label: "Vector tiles",
            subtitle: "PMTiles / MBTiles",
            provenance: .live,
            needsPath: true
        ),
        SourceDefinition(
            id: SourceID.naturalEarth,
            label: "Natural Earth",
            subtitle: "world atlas shapes",
            provenance: .measured,
            needsPath: true
        ),
        SourceDefinition(
            id: SourceID.overture,
            label: "Overture",
            subtitle: "places · buildings",
            provenance: .measured,
            needsPath: true
        ),
    ]

    public let definitions: [SourceDefinition]
    private var enabled: [String]
    private var paths: [String: String]
    private var overrides: [String: [String: SourceSetting.Value]]

    public init(definitions: [SourceDefinition] = SourceStack.defaultDefinitions) {
        self.definitions = definitions
        self.enabled = definitions.filter(\.defaultEnabled).map(\.id)
        self.paths = [:]
        self.overrides = [:]
    }

    // MARK: - Membership

    public func definition(_ id: String) -> SourceDefinition? {
        definitions.first { $0.id == id }
    }

    public func isEnabled(_ id: String) -> Bool { enabled.contains(id) }

    /// A source needing a file is only usable once one is configured.
    public func isAvailable(_ id: String) -> Bool {
        guard let definition = definition(id) else { return false }
        return definition.needsPath ? !(paths[id] ?? "").isEmpty : true
    }

    /// Ticked sources, in sidebar order rather than click order — so the same set of
    /// ticks always fetches in the same order, whichever way it was assembled.
    public var enabledIDs: [String] {
        let order = Dictionary(uniqueKeysWithValues: definitions.enumerated().map { ($1.id, $0) })
        return enabled.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
    }

    public mutating func setEnabled(_ id: String, _ isEnabled: Bool) {
        guard definition(id) != nil else { return }
        // Ticking a source with no file would fetch nothing and report an error;
        // refusing quietly keeps the stack honest.
        if isEnabled, !isAvailable(id) { return }
        if isEnabled {
            if !enabled.contains(id) { enabled.append(id) }
        } else {
            enabled.removeAll { $0 == id }
        }
    }

    @discardableResult
    public mutating func toggle(_ id: String) -> Bool {
        setEnabled(id, !isEnabled(id))
        return isEnabled(id)
    }

    // MARK: - Per-source configuration

    public mutating func setPath(_ id: String, _ path: String) {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            paths.removeValue(forKey: id)
            // A source that lost its file cannot stay ticked.
            setEnabled(id, false)
        } else {
            paths[id] = cleaned
        }
    }

    public func path(_ id: String) -> String { paths[id] ?? "" }

    public mutating func setSetting(_ id: String, _ key: String, _ value: SourceSetting.Value) {
        guard let definition = definition(id), definition.setting(key) != nil else { return }
        overrides[id, default: [:]][key] = value
    }

    /// Declared settings with any override applied.
    public func settings(for id: String) -> [SourceSetting] {
        guard let definition = definition(id) else { return [] }
        let applied = overrides[id] ?? [:]
        return definition.settings.map { setting in
            applied[setting.key].map(setting.withValue) ?? setting
        }
    }

    /// Only what the user actually changed, keyed by the provider field it targets.
    ///
    /// Deliberately not every setting: a provider's own defaults are the better
    /// answer for anything untouched, and sending all of them would freeze today's
    /// defaults into every fetch.
    public func providerOverrides(for id: String) -> [String: SourceSetting.Value] {
        guard let changed = overrides[id] else { return [:] }
        var result: [String: SourceSetting.Value] = [:]
        for setting in settings(for: id) where changed[setting.key] != nil {
            result[setting.target] = setting.value
        }
        return result
    }

    // MARK: - Resolution

    /// Resolve the ticked sources into a base plus everything stacked onto it.
    ///
    /// OpenStreetMap becomes the base whenever it is ticked, because the rest of the
    /// app is built around its layers. Otherwise the first ticked source supplies the
    /// base and everything else rides along. Nothing ticked means there is nothing to
    /// fetch, which the caller should treat as a prompt rather than an error.
    public var plan: FetchPlan? {
        let enabled = enabledIDs
        guard !enabled.isEmpty else { return nil }
        let base = enabled.contains(SourceID.overpass) ? SourceID.overpass : enabled[0]
        return FetchPlan(base: base, extras: enabled.filter { $0 != base })
    }

    /// One line for the status bar: what this map is made of.
    public var summary: String {
        let labels = definitions.filter { enabled.contains($0.id) }.map(\.label)
        guard let last = labels.last else { return "No sources selected" }
        guard labels.count > 1 else { return last }
        return "\(labels.dropLast().joined(separator: ", ")) + \(last)"
    }
}
