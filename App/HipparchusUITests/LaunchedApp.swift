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
/// **It does not launch offline, whatever this used to say.** The wish behind
/// that claim was sound — a layout test that fetches is a test of somebody
/// else's server, slow and flaky and able to fail for reasons that have nothing
/// to do with the window — but the environment variable below was set from the
/// first day and read by *nothing at all*, so it was never more than a wish.
///
/// Nor could the app have granted it: the Locator holds a live `MKMapView`, and
/// MapKit fetches its own tiles by routes an application does not get a say in.
/// The proof is on this suite's own record. `LaunchOrderTests` used to identify
/// the Locator by a button titled "Europe", a string that appears nowhere in
/// Hipparchus — it is a *rendered* MapKit label, and it could only ever have
/// been there because the tiles had come down off the network. A test built on
/// the fetch that was supposedly prevented is as clear as this gets.
///
/// The variable that claimed to arrange it, `HIPPARCHUS_UI_TESTS`, is gone
/// rather than fixed: a switch nothing reads is worse than no switch, because it
/// reads in the source like a guarantee. What replaces it is `keepPanelsVisible`
/// below, which is narrow, is passed by exactly one test, and says on its face
/// what it does. The isolation that actually protects the user's work is
/// `--state-directory`, above, and that one is real.
enum LaunchedApp {

    /// A directory name unique to this run, so two runs cannot collide and a
    /// left-behind one is obviously junk.
    static func isolatedStateName(function: String = #function) -> String {
        let cleaned = function.prefix(while: { $0 != "(" })
        return "HipparchusUITests-\(cleaned)-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// - Parameter keepPanelsVisible: passes `--no-panel-hiding`, which stops the
    ///   Locator taking itself off screen while the app is in the background.
    ///
    ///   **Only for the tests that ask what windows exist** — `LaunchOrderTests`
    ///   and `HierarchyDumpTests` — and off by default for a reason that was
    ///   measured rather than guessed. `NSPanel.hidesOnDeactivate` is `true` by
    ///   default, so such a test cannot otherwise tell a panel that never opened
    ///   from one that opened and hid.
    ///   But a panel that will not hide is a panel left sitting over the main
    ///   window, and turning this on for everything cost `WindowLayoutTests` its
    ///   `testTheControlsAreHittable` — Render map exists but cannot be clicked.
    ///   The layout tests want the window as somebody would actually meet it.
    static func launch(stateName: String, keepPanelsVisible: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        let arguments = [
            "--state-directory", stateName,
            // The splash is a modal window over everything the tests want to
            // look at, and dismissing it in each test would be testing the
            // splash rather than the layout.
            "-ShowAboutOnLaunch", "NO",
        ]
        app.launchArguments = keepPanelsVisible ? arguments + ["--no-panel-hiding"] : arguments
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
    /// The `Window(id:)` of the map scene. Addressing the window by this rather
    /// than by `firstMatch` is what stops the Locator — a floating panel that
    /// comes to the front — being mistaken for the window under test.
    static let mainWindow = "map"

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
