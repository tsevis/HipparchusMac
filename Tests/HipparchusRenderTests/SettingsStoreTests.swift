import XCTest
@testable import HipparchusRender

/// The handful of preferences that are neither part of a map nor part of a
/// session.
///
/// Ported from `core/settings_store.py`. The file is the Python's, key for
/// key, for the same reason the preset file is: the two applications are the
/// same application.
final class SettingsStoreTests: XCTestCase {

    private var directory: URL!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(url: directory.appendingPathComponent("settings.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Defaults

    func testNothingSavedGivesThePythonsOwnDefaults() {
        let settings = store.load()
        XCTAssertEqual(settings.themeMode, "light")
        XCTAssertEqual(settings.performancePreviewTolerance, 1.5, accuracy: 1e-9)
        // A deliberate divergence: the Python's own default is 4096 MB, and
        // four gigabytes is a few sessions of real work here — OpenStreetMap
        // over a dense city is tens of megabytes a fetch and a terrain mosaic
        // is sixty-four tiles. Evicting an area about to be asked for again
        // costs a round trip to a service run on donations.
        XCTAssertEqual(settings.cacheSizeLimitMB, 8192)
        XCTAssertEqual(settings.providerRPSLimit, 1.0, accuracy: 1e-9)
    }

    // MARK: - Round trip

    func testEveryFieldSurvivesTheRoundTrip() throws {
        var settings = UserSettings()
        settings.themeMode = "dark"
        settings.performancePreviewTolerance = 0.75
        settings.cacheSizeLimitMB = 512
        settings.providerRPSLimit = 2.5
        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testTheFileUsesThePythonsOwnKeys() throws {
        try store.save(UserSettings())
        let text = try String(contentsOf: store.url, encoding: .utf8)
        for key in [
            "theme_mode", "performance_preview_tolerance",
            "cache_size_limit_mb", "provider_rps_limit",
        ] {
            XCTAssertTrue(text.contains("\"\(key)\""), "missing \(key)")
        }
    }

    func testTheDirectoryIsCreatedIfMissing() throws {
        let nested = SettingsStore(
            url: directory.appendingPathComponent("a/b/settings.json")
        )
        try nested.save(UserSettings())
        XCTAssertEqual(nested.load().cacheSizeLimitMB, 8192)
    }

    // MARK: - Files that are not what they should be

    func testAFileWrittenBeforeAFieldExistedStillLoads() throws {
        try #"{"cache_size_limit_mb": 256}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        let settings = store.load()
        XCTAssertEqual(settings.cacheSizeLimitMB, 256)
        // The rest fall back rather than the whole file failing.
        XCTAssertEqual(settings.themeMode, "light")
        XCTAssertEqual(settings.providerRPSLimit, 1.0, accuracy: 1e-9)
    }

    func testRubbishReadsAsTheDefaultsRatherThanThrowing() throws {
        try "not json at all".write(to: store.url, atomically: true, encoding: .utf8)
        // Deliberately not an error: settings are preferences, and a corrupt
        // preference file must never be a reason the app will not open.
        XCTAssertEqual(store.load(), UserSettings())
    }

    // MARK: - Values that would do damage if believed

    func testANonsenseCacheLimitFallsBackRatherThanEmptyingTheCache() throws {
        try #"{"cache_size_limit_mb": -5}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        // A negative limit read literally would mean "keep nothing".
        XCTAssertEqual(store.load().cacheSizeLimitMB, UserSettings().cacheSizeLimitMB)
    }

    func testANonsenseRateLimitFallsBack() throws {
        try #"{"provider_rps_limit": 0}"#
            .write(to: store.url, atomically: true, encoding: .utf8)
        // Zero requests per second is not a rate, it is a hang.
        XCTAssertEqual(store.load().providerRPSLimit, 1.0, accuracy: 1e-9)
    }

    func testTheCacheLimitIsOfferedInBytesBecauseThatIsWhatTheCacheSpeaks() {
        var settings = UserSettings()
        settings.cacheSizeLimitMB = 2
        XCTAssertEqual(settings.cacheSizeLimitBytes, 2 * 1024 * 1024)
    }
}
