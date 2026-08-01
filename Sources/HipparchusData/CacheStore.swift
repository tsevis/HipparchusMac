import CryptoKit
import Foundation

/// Somewhere to keep a provider's raw response.
///
/// Ported from `cache/store.py`.
///
/// Caching matters most for Overpass, where a re-fetch of an area already looked at
/// costs minutes rather than milliseconds. The raw response is stored rather than
/// the decoded features, so a change to the decoder takes effect on the next render
/// without invalidating anything.
public protocol CacheStoring: Sendable {
    func data(for key: String) async -> Data?
    func store(_ data: Data, for key: String) async
    func remove(_ key: String) async
    func removeAll() async
}

/// An in-memory cache, bounded and least-recently-used.
///
/// The default, because a cache that outlives the process is a decision the app
/// should make on purpose rather than inherit.
public actor MemoryCacheStore: CacheStoring {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit: Int

    public init(limit: Int = 32) {
        self.limit = Swift.max(1, limit)
    }

    public func data(for key: String) -> Data? {
        guard let data = entries[key] else { return nil }
        touch(key)
        return data
    }

    public func store(_ data: Data, for key: String) {
        entries[key] = data
        touch(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    public func remove(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    public func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    public var count: Int { entries.count }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// A cache on disk, one file per key.
///
/// Keys are hashed rather than used as filenames: an Overpass key carries commas,
/// colons and a signed longitude, none of which belong in a path.
public actor DiskCacheStore: CacheStoring {
    private let directory: URL
    private let maximumAge: TimeInterval

    /// - Parameter maximumAge: entries older than this are treated as absent. A week
    ///   by default: OSM changes slowly enough that a stale street map is a far
    ///   smaller problem than a five-minute wait, but not so slowly that a map should
    ///   be a year out of date without asking.
    public init(directory: URL, maximumAge: TimeInterval = 7 * 24 * 60 * 60) {
        self.directory = directory
        self.maximumAge = maximumAge
    }

    /// The default location: the user's cache directory, which the system is free to
    /// purge under pressure — exactly right for something rebuildable from the network.
    public static func defaultDirectory(subdirectory: String = "Hipparchus") -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(subdirectory, isDirectory: true)
    }

    private func url(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("cache")
    }

    public func data(for key: String) -> Data? {
        let url = url(for: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        guard Date().timeIntervalSince(modified) <= maximumAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    public func store(_ data: Data, for key: String) {
        // A cache that cannot be written is a slow app, not a broken one, so every
        // failure here is swallowed on purpose.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(_ key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// How large the cache may get before the oldest entries are dropped.
    ///
    /// A gigabyte: several sessions of large areas, and small enough to be a
    /// limit. Expiry alone was never one — an entry is only checked for
    /// staleness when it is *asked for*, so anything never wanted again stayed
    /// for ever, and the cache only ever grew.
    public static let defaultMaximumBytes = 1_073_741_824

    /// Drop the oldest entries until the cache fits, and say how many went.
    ///
    /// Ported from `cache/housekeeping.py`'s `enforce_size_limit`. Oldest
    /// first by modification time, stopping the moment it is under the limit
    /// rather than clearing wholesale — the point is to bound the cache, not
    /// to throw away work that still fits.
    @discardableResult
    public func enforceSizeLimit(maximumBytes: Int = DiskCacheStore.defaultMaximumBytes) -> Int {
        // A nonsense limit must not become a way to silently delete
        // everything; zero is a real answer and means "keep nothing".
        guard maximumBytes >= 0 else { return 0 }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else {
            // No cache directory yet is not a fault.
            return 0
        }

        let entries = contents
            .compactMap { url -> (url: URL, size: Int, modified: Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      let size = values.fileSize,
                      let modified = values.contentModificationDate
                else { return nil }
                return (url, size, modified)
            }
            .sorted { $0.modified < $1.modified }

        var total = entries.reduce(0) { $0 + $1.size }
        var removed = 0
        for entry in entries {
            guard total > maximumBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            removed += 1
        }
        return removed
    }

    /// What the cache is costing, for the interface to show and offer to clear.
    public func totalBytes() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
