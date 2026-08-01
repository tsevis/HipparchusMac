import Foundation
import HipparchusData
import HipparchusGeometry

/// What the app was doing, so it can be doing it again next time.
///
/// Ported from `core/settings_store.py` and `core/project_state.py`, which the
/// Python keeps apart — one for preferences, one for a saved project. They hold
/// the same shape of thing and are saved at the same moments, so they are one type
/// here, and "the session" and "a saved project" become the same file written to
/// two places.
///
/// Deliberately *not* `UserDefaults`: a project has to be openable from a path and
/// diffable by a person, and a settings file that can be read in a text editor is
/// worth more than one that cannot when something goes wrong.
public struct Session: Codable, Sendable, Equatable {

    /// The area, as four numbers rather than a `BoundingBox`, so a half-typed
    /// coordinate can be saved and restored the way it was left.
    public struct Area: Codable, Sendable, Equatable {
        public var west: Double
        public var south: Double
        public var east: Double
        public var north: Double

        public init(west: Double, south: Double, east: Double, north: Double) {
            self.west = west
            self.south = south
            self.east = east
            self.north = north
        }

        public init(_ bbox: BoundingBox) {
            self.init(west: bbox.minLon, south: bbox.minLat, east: bbox.maxLon, north: bbox.maxLat)
        }

        /// `nil` rather than a silently corrected box: a saved file with west east of
        /// east is wrong, and quietly swapping them hides whatever produced it.
        public var bbox: BoundingBox? {
            guard west < east, south < north,
                  (-180...180).contains(west), (-180...180).contains(east),
                  (-90...90).contains(south), (-90...90).contains(north)
            else {
                return nil
            }
            return BoundingBox(minLon: west, minLat: south, maxLon: east, maxLat: north)
        }
    }

    public var area: Area
    public var placeName: String
    /// Ticked sources, by id.
    public var enabledSources: [String]
    /// Per-source file paths, for the file-backed sources.
    public var sourcePaths: [String: String]
    /// Per-source security-scoped bookmarks, base64. The app is sandboxed, so
    /// a path alone is only permission to read the file during the run in
    /// which it was chosen; this is what carries that permission forward.
    /// Base64 because this file is meant to be readable, and raw `Data` in
    /// JSON is neither readable nor smaller.
    public var sourceBookmarks: [String: String] = [:]
    /// Per-source setting overrides, as `sourceID.settingKey` → value. Flattened
    /// because a nested dictionary of an enum is a lot of `Codable` for a file whose
    /// whole job is to be readable.
    public var sourceSettings: [String: Double]
    public var sourceChoices: [String: String]
    public var presetName: String
    /// Colour, chosen apart from the preset. `Palette.presetOwnName` — the
    /// default, and what every session written before palettes existed decodes
    /// to — means the preset's own colours.
    public var paletteName: String
    /// One multiplier over every stroke. Remembered because it is a property of
    /// the medium you are drawing for — screen or paper — and that does not
    /// change between launches the way a title block does.
    public var lineWeight: Double
    /// Whether relief shading is drawn over the built environment or under it.
    public var reliefOverBuildings: Bool
    public var qualityKey: String
    public var hiddenLayers: [String]

    /// Decoded field by field with a default for anything absent, so a file from
    /// an older version — one written before a field existed — costs nothing but
    /// that field. The synthesised decoder would throw the whole session away.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Session()
        self.area = try container.decodeIfPresent(Area.self, forKey: .area) ?? defaults.area
        self.placeName = try container.decodeIfPresent(String.self, forKey: .placeName) ?? defaults.placeName
        self.enabledSources = try container.decodeIfPresent([String].self, forKey: .enabledSources) ?? defaults.enabledSources
        self.sourcePaths = try container.decodeIfPresent([String: String].self, forKey: .sourcePaths) ?? [:]
        // Absent in every session written before bookmarks existed, which is
        // simply a session whose files must be chosen again.
        self.sourceBookmarks = try container.decodeIfPresent([String: String].self, forKey: .sourceBookmarks) ?? [:]
        self.sourceSettings = try container.decodeIfPresent([String: Double].self, forKey: .sourceSettings) ?? [:]
        self.sourceChoices = try container.decodeIfPresent([String: String].self, forKey: .sourceChoices) ?? [:]
        self.presetName = try container.decodeIfPresent(String.self, forKey: .presetName) ?? defaults.presetName
        self.paletteName = try container.decodeIfPresent(String.self, forKey: .paletteName) ?? defaults.paletteName
        // A session written before these existed simply gets the defaults: the
        // preset's own weights, and relief under the buildings where it belongs.
        self.lineWeight = try container.decodeIfPresent(Double.self, forKey: .lineWeight) ?? defaults.lineWeight
        self.reliefOverBuildings = try container
            .decodeIfPresent(Bool.self, forKey: .reliefOverBuildings) ?? defaults.reliefOverBuildings
        self.qualityKey = try container.decodeIfPresent(String.self, forKey: .qualityKey) ?? defaults.qualityKey
        self.hiddenLayers = try container.decodeIfPresent([String].self, forKey: .hiddenLayers) ?? []
    }

    public init(
        // The whole earth, and Elevation rather than OpenStreetMap to draw
        // it with. A first launch should open on the world and be able to
        // render it: Overpass refuses anything this size — rightly, it is a
        // shared service — while terrain tiles are tiled and bounded, so the
        // first Render map produces a world relief map rather than a refusal.
        // ±85° because that is where Mercator stops, not where the world does.
        area: Area = Area(west: -180, south: -85, east: 180, north: 85),
        placeName: String = "",
        enabledSources: [String] = [SourceID.terrainTiles],
        sourcePaths: [String: String] = [:],
        sourceBookmarks: [String: String] = [:],
        sourceSettings: [String: Double] = [:],
        sourceChoices: [String: String] = [:],
        presetName: String = "Hypsometric Relief",
        paletteName: String = Palette.presetOwnName,
        lineWeight: Double = 1.0,
        reliefOverBuildings: Bool = false,
        qualityKey: String = Quality.default.key,
        hiddenLayers: [String] = [],
    ) {
        self.area = area
        self.placeName = placeName
        self.enabledSources = enabledSources
        self.sourcePaths = sourcePaths
        self.sourceBookmarks = sourceBookmarks
        self.sourceSettings = sourceSettings
        self.sourceChoices = sourceChoices
        self.presetName = presetName
        self.paletteName = paletteName
        self.lineWeight = lineWeight
        self.reliefOverBuildings = reliefOverBuildings
        self.qualityKey = qualityKey
        self.hiddenLayers = hiddenLayers
    }

    // MARK: - The source stack

    /// Capture a stack, keeping only what the user actually changed.
    public init(
        stack: SourceStack, area: Area, placeName: String, preset: String,
        palette: String = Palette.presetOwnName,
        lineWeight: Double = 1.0,
        reliefOverBuildings: Bool = false,
        quality: String, hiddenLayers: [String]
    ) {
        var paths: [String: String] = [:]
        var bookmarks: [String: String] = [:]
        var numbers: [String: Double] = [:]
        var choices: [String: String] = [:]

        for definition in stack.definitions {
            let path = stack.path(definition.id)
            if !path.isEmpty { paths[definition.id] = path }
            if let bookmark = stack.bookmark(definition.id) {
                bookmarks[definition.id] = bookmark.base64EncodedString()
            }

            // By setting key, not by provider target: this file is read back through
            // `setSetting`, which speaks keys.
            for (key, value) in stack.changedSettings(for: definition.id) {
                let field = "\(definition.id).\(key)"
                if let text = value.stringValue {
                    choices[field] = text
                } else if let number = value.doubleValue {
                    numbers[field] = number
                }
            }
        }

        self.init(
            area: area,
            placeName: placeName,
            enabledSources: stack.enabledIDs,
            sourcePaths: paths,
            sourceBookmarks: bookmarks,
            sourceSettings: numbers,
            sourceChoices: choices,
            presetName: preset,
            paletteName: palette,
            lineWeight: lineWeight,
            reliefOverBuildings: reliefOverBuildings,
            qualityKey: quality,
            hiddenLayers: hiddenLayers,
        )
    }

    /// Rebuild a stack from what was saved.
    ///
    /// Paths go on before ticks, or a file-backed source would refuse the tick it
    /// was saved with — the stack will not enable a source whose file it cannot see
    /// yet, which is the right rule and the wrong order to apply it in.
    public func stack() -> SourceStack {
        var stack = SourceStack()

        for (id, path) in sourcePaths {
            stack.setPath(id, path, bookmark: sourceBookmarks[id].flatMap { Data(base64Encoded: $0) })
        }

        for definition in stack.definitions {
            stack.setEnabled(definition.id, enabledSources.contains(definition.id))
        }

        for (field, value) in sourceSettings {
            guard let (id, key) = Self.split(field), let setting = stack.definition(id)?.setting(key) else {
                continue
            }
            // Keep the declared shape: a band count is an integer, a magnitude is not.
            if case .integer = setting.value {
                stack.setSetting(id, key, .integer(Int(value)))
            } else {
                stack.setSetting(id, key, .number(value))
            }
        }
        for (field, value) in sourceChoices {
            guard let (id, key) = Self.split(field) else { continue }
            stack.setSetting(id, key, .text(value))
        }
        return stack
    }

    private static func split(_ field: String) -> (id: String, key: String)? {
        // Split on the last dot: a source id may not contain one, but this is the
        // side that must be right if one ever does.
        guard let dot = field.lastIndex(of: ".") else { return nil }
        return (String(field[field.startIndex..<dot]), String(field[field.index(after: dot)...]))
    }

    // MARK: - On disk

    /// Where the session lives between launches.
    ///
    /// Application Support, not Caches: this is the user's own state and losing it
    /// would be a bug, where losing a cached tile is a slow morning.
    public static func defaultURL(subdirectory: String = "Hipparchus") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent("session.json")
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Read a session, or the defaults.
    ///
    /// A settings file that cannot be read must not stop the app opening — the
    /// worst it should cost is the settings. The same goes for one written by a
    /// newer version with fields this one does not know.
    public static func read(from url: URL) -> Session {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Session.self, from: data)
        else {
            return Session()
        }
        return session
    }
}
