import XCTest
@testable import HipparchusData

/// Keeping the cache from eating the disk.
///
/// Ported from `cache/housekeeping.py`. Until this existed the cache only ever
/// grew: a week's expiry removes an entry when it is *asked for* and found
/// stale, so anything never asked for again stayed for ever. A few sessions of
/// large areas is gigabytes.
final class CacheHousekeepingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// One entry of a known size, with a known age, so eviction order is a
    /// fact rather than a race.
    private func write(_ key: String, bytes: Int, ageInSeconds: TimeInterval) async throws {
        let store = DiskCacheStore(directory: directory)
        await store.store(Data(repeating: 0, count: bytes), for: key)
        let url = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".cache") && !$0.lastPathComponent.isEmpty
                    && (try? Data(contentsOf: $0).count) == bytes }
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageInSeconds)], ofItemAtPath: url.path
        )
    }

    func testNothingIsRemovedWhenTheCacheIsUnderTheLimit() async throws {
        let store = DiskCacheStore(directory: directory)
        await store.store(Data(repeating: 1, count: 1000), for: "a")

        let removed = await store.enforceSizeLimit(maximumBytes: 10_000)
        let kept = await store.data(for: "a")
        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(kept)
    }

    func testTheOldestGoFirst() async throws {
        try await write("old", bytes: 4_000, ageInSeconds: 3600)
        try await write("middle", bytes: 4_000, ageInSeconds: 1800)
        try await write("new", bytes: 4_000, ageInSeconds: 10)

        let store = DiskCacheStore(directory: directory)
        // Room for two of the three.
        let removed = await store.enforceSizeLimit(maximumBytes: 9_000)

        let old = await store.data(for: "old")
        let middle = await store.data(for: "middle")
        let new = await store.data(for: "new")
        XCTAssertEqual(removed, 1)
        XCTAssertNil(old, "the oldest should have gone")
        XCTAssertNotNil(middle)
        XCTAssertNotNil(new)
    }

    func testItStopsAsSoonAsItIsUnderTheLimit() async throws {
        for index in 0..<5 {
            try await write("k\(index)", bytes: 1_000, ageInSeconds: Double(100 - index))
        }
        let store = DiskCacheStore(directory: directory)
        let removed = await store.enforceSizeLimit(maximumBytes: 3_500)

        // 5 × 1000 down to at most 3500 means dropping two, not everything.
        let total = await store.totalBytes()
        XCTAssertEqual(removed, 2)
        XCTAssertLessThanOrEqual(total, 3_500)
    }

    func testAZeroLimitEmptiesTheCache() async throws {
        try await write("a", bytes: 500, ageInSeconds: 10)
        try await write("b", bytes: 500, ageInSeconds: 20)

        let store = DiskCacheStore(directory: directory)
        let removed = await store.enforceSizeLimit(maximumBytes: 0)
        let total = await store.totalBytes()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(total, 0)
    }

    func testANegativeLimitIsRefusedRatherThanTreatedAsZero() async throws {
        try await write("a", bytes: 500, ageInSeconds: 10)
        let store = DiskCacheStore(directory: directory)
        // A nonsense limit must not be a way to silently delete everything.
        let removed = await store.enforceSizeLimit(maximumBytes: -1)
        let kept = await store.data(for: "a")
        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(kept)
    }

    func testAMissingCacheDirectoryIsNotAnError() async throws {
        let store = DiskCacheStore(directory: directory.appendingPathComponent("nope"))
        let removed = await store.enforceSizeLimit(maximumBytes: 1_000)
        XCTAssertEqual(removed, 0)
    }

    func testTheDefaultLimitIsGenerousButFinite() {
        // Big enough that ordinary work never trips it, small enough that it
        // is a limit — the 1.8 GB this was written for was neither.
        XCTAssertGreaterThan(DiskCacheStore.defaultMaximumBytes, 500_000_000)
        XCTAssertLessThan(DiskCacheStore.defaultMaximumBytes, 5_000_000_000)
    }
}
