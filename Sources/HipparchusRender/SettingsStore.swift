import Foundation

/// The handful of preferences that belong to neither a map nor a session.
///
/// Ported from `core/settings_store.py`, fields and file format alike.
///
/// Small on purpose. Everything that describes *a map* is in the session, and
/// everything that describes *a style* is in a preset; what is left is a few
/// numbers about how the application should behave, which is exactly what the
/// Python keeps here.
public struct UserSettings: Sendable, Equatable {
    /// Kept for the file's sake rather than acted on: macOS applications
    /// follow the system appearance, and an app-level light/dark switch that
    /// disagreed with it would be a bug rather than a feature. Round-tripped
    /// so that a settings file shared with the Python app is not damaged by
    /// being opened here.
    public var themeMode: String = "light"
    public var performancePreviewTolerance: Double = 1.5
    /// The Python's default, and now this one's. The cache is bounded after
    /// every fetch — see `DiskCacheStore.enforceSizeLimit`.
    public var cacheSizeLimitMB: Int = 4096
    public var providerRPSLimit: Double = 1.0

    public init() {}

    /// What `DiskCacheStore` actually speaks.
    public var cacheSizeLimitBytes: Int { cacheSizeLimitMB * 1024 * 1024 }
}

/// Reads and writes `settings.json`.
///
/// Every failure is swallowed into the defaults. These are preferences: a
/// corrupt preferences file must never be the reason an application will not
/// open, and the worst case of ignoring one is a few numbers back where they
/// started.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Beside the session and the presets, for the same reason.
    public static func defaultURL(subdirectory: String = "Hipparchus") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent(subdirectory).appendingPathComponent("settings.json")
    }

    public func load() -> UserSettings {
        var settings = UserSettings()
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredSettings.self, from: data)
        else {
            return settings
        }

        if let theme = stored.themeMode, !theme.isEmpty { settings.themeMode = theme }
        // Each value is checked before it is believed. A hand-edited file is
        // the normal way these change, and a nonsense number here would
        // otherwise be acted on: a negative cache limit means "keep nothing",
        // and nought requests a second is not a rate but a hang.
        if let tolerance = stored.performancePreviewTolerance, tolerance > 0 {
            settings.performancePreviewTolerance = tolerance
        }
        if let limit = stored.cacheSizeLimitMB, limit > 0 {
            settings.cacheSizeLimitMB = limit
        }
        if let rate = stored.providerRPSLimit, rate > 0 {
            settings.providerRPSLimit = rate
        }
        return settings
    }

    public func save(_ settings: UserSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(StoredSettings(settings)).write(to: url, options: .atomic)
    }
}

/// The file's own shape — the Python's keys, and every field optional so a
/// file written before one existed still reads.
private struct StoredSettings: Codable {
    var themeMode: String?
    var performancePreviewTolerance: Double?
    var cacheSizeLimitMB: Int?
    var providerRPSLimit: Double?

    enum CodingKeys: String, CodingKey {
        case themeMode = "theme_mode"
        case performancePreviewTolerance = "performance_preview_tolerance"
        case cacheSizeLimitMB = "cache_size_limit_mb"
        case providerRPSLimit = "provider_rps_limit"
    }

    init(_ settings: UserSettings) {
        themeMode = settings.themeMode
        performancePreviewTolerance = settings.performancePreviewTolerance
        cacheSizeLimitMB = settings.cacheSizeLimitMB
        providerRPSLimit = settings.providerRPSLimit
    }
}
