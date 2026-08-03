import XCTest

/// The application, launched somewhere it cannot do any harm.
///
/// **A UI test run is a second copy of the application**, and until this existed
/// every store in it wrote to the same place the real one does. A test that
/// ticked a source and quit would have replaced the user's saved area, style and
/// layer choices with whatever the test happened to do. `--state-directory`
/// points the session, the preferences, the saved styles and the cache at a
/// throwaway name, and `isIsolated` is asserted before anything else runs — a
/// test suite that silently lost its isolation would eat the user's work on the
/// next run rather than failing.
///
/// It also launches **offline**. A layout test that fetches is a test of
/// somebody else's server: slow, flaky, and capable of failing for reasons that
/// have nothing to do with the window.
enum LaunchedApp {

    /// A directory name unique to this run, so two runs cannot collide and a
    /// left-behind one is obviously junk.
    static func isolatedStateName(function: String = #function) -> String {
        let cleaned = function.prefix(while: { $0 != "(" })
        return "HipparchusUITests-\(cleaned)-\(ProcessInfo.processInfo.processIdentifier)"
    }

    static func launch(stateName: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--state-directory", stateName,
            // The splash is a modal window over everything the tests want to
            // look at, and dismissing it in each test would be testing the
            // splash rather than the layout.
            "-ShowAboutOnLaunch", "NO",
        ]
        // Belt and braces: nothing here should reach the network, and a test
        // that hangs on a fetch fails as a timeout somewhere unrelated.
        app.launchEnvironment["HIPPARCHUS_UI_TESTS"] = "1"
        app.launch()
        return app
    }

    /// Everything a run leaves behind, so a suite does not accumulate junk in
    /// Application Support and Caches.
    static func removeState(named name: String) {
        let manager = FileManager.default
        let roots = [
            manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
        ]
        for root in roots.compactMap({ $0 }) {
            try? manager.removeItem(at: root.appendingPathComponent(name))
        }
    }
}

/// The identifiers, repeated here because a UI test bundle cannot import the
/// application target.
///
/// **Kept in step by a test rather than by discipline** —
/// `testTheIdentifiersMatchTheApplication` in `WindowLayoutTests` asserts that
/// every one of these is actually present in the window, so a rename in
/// `UITestID.swift` that is not mirrored here fails loudly instead of turning
/// every other test into a silent "element does not exist".
enum ID {
    static let framePanel = "frame_panel"
    static let mapColumn = "map_column"
    static let inspector = "inspector"
    static let statusBar = "status_bar"
    static let renderButton = "render_map_button"
    static let locatorButton = "open_locator_button"
    static let exportMenu = "export_menu"
    static let areaDescription = "area_description"

    /// The ones that must be on screen the moment the window opens. `cancel`
    /// is deliberately absent: it exists only while a fetch is running.
    static let alwaysPresent = [
        framePanel, mapColumn, inspector, statusBar,
        renderButton, locatorButton, exportMenu, areaDescription,
    ]
}
