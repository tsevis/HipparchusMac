import XCTest

/// What opens by itself, and whether it does so every time.
///
/// **These exist because two identical launches produced two different
/// windows.** The splash was shown from a `.task` the app attached to
/// `ContentView`, and its completion called `actions.openLocator` — which
/// `ContentView`'s *own* `.task` assigns. SwiftUI does not specify which of two
/// `.task` modifiers runs first, so when the app's won, the closure was still
/// nil and the Locator never appeared.
///
/// The splash hid it in ordinary use by giving the wiring time to land. It
/// showed only with "Show About on launch" off, which is how the layout tests
/// launch — they found it by accident, in the shape of eight failures caused by
/// asserting against a window that was sometimes there and sometimes not.
///
/// **A race cannot be caught by one launch.** One launch of a coin toss is a
/// passing test half the time, so these repeat.
@MainActor
final class LaunchOrderTests: XCTestCase {

    /// Enough launches that a fair coin would almost certainly have shown both
    /// faces — a one-in-thirty-two chance of a false pass, against about four
    /// seconds a launch.
    private static let attempts = 5

    override func setUp() {
        continueAfterFailure = false
    }

    /// With the splash suppressed the completion runs immediately, so the
    /// Locator must be up **every** time. This is the case that used to be a
    /// coin toss.
    func testTheLocatorOpensOnEveryLaunchWhenTheSplashIsOff() {
        for attempt in 1...Self.attempts {
            let stateName = "\(LaunchedApp.isolatedStateName(function: name))-\(attempt)"
            // **This passes `keepPanelsVisible`, and it is the test that most
            // needs it.** The Locator is
            // an `NSPanel`, `NSPanel.hidesOnDeactivate` defaults to `true`, and
            // the panel therefore drops out of the window tree whenever the
            // application is not the active one — which is what made this test
            // intermittent, and which reads from outside as "the launch never
            // opened it".
            //
            // The obvious repair is for the test to take the front and hold it.
            // That was tried and rejected: holding the front means calling
            // `activate()` every couple of seconds for as long as the wait
            // lasts, and this suite already takes over the screen of whoever
            // runs it. A test that also snatches the keyboard back every two
            // seconds is one nobody can run while working.
            //
            // Detection is untouched by either: if the ordering comes apart,
            // `show()` is never called and there is no panel for the flag to
            // keep on screen.
            let app = LaunchedApp.launch(stateName: stateName, keepPanelsVisible: true)
            defer {
                app.terminate()
                LaunchedApp.removeState(named: stateName)
            }

            XCTAssertTrue(
                app.windows[ID.mainWindow].waitForExistence(timeout: 30),
                "launch \(attempt): no main window"
            )
            // Thirty seconds matches every other window wait here. It is
            // tidiness rather than a fix, recorded because it was tried as the
            // fix first and only moved the failure from 19s to 34s.
            if !locator(in: app).waitForExistence(timeout: 30) {
                XCTFail(
                    "launch \(attempt) of \(Self.attempts): the Locator did not open. "
                        + "The windows that were open instead: \(describeWindows(of: app)). "
                        + "\(describeFront(of: app)) "
                        + "If this passes sometimes and fails others, the launch "
                        + "ordering has come apart again — see ContentView.openOnLaunch()."
                )
                return
            }
        }
    }

    /// The main window is there every time regardless, which is the control:
    /// without it a failure above could just mean the app did not start.
    func testTheMainWindowIsThereOnEveryLaunch() {
        for attempt in 1...Self.attempts {
            let stateName = "\(LaunchedApp.isolatedStateName(function: name))-\(attempt)"
            let app = LaunchedApp.launch(stateName: stateName)
            defer {
                app.terminate()
                LaunchedApp.removeState(named: stateName)
            }
            XCTAssertTrue(
                app.windows[ID.mainWindow].waitForExistence(timeout: 30),
                "launch \(attempt): no main window"
            )
        }
    }

    /// Whether the application was in front, which used to be the whole answer.
    ///
    /// A missing panel and a backgrounded application were once the same
    /// sentence: `hidesOnDeactivate` accounted for the first without any bug
    /// being involved, and working that out took three runs. It is reported
    /// here so that nobody has to work it out a second time — and now that the
    /// panel no longer hides under the harness, the two readings have come
    /// apart again, which is what makes it worth printing.
    private func describeFront(of app: XCUIApplication) -> String {
        app.state == .runningForeground
            ? "The application was in front."
            : "The application was NOT in front, which should no longer matter — "
                + "this test launches with keepPanelsVisible, so the panel is told "
                + "not to hide on deactivate. If that flag stopped reaching the "
                + "app, this is where it would show."
    }

    /// Every window that is actually open, for the failure message.
    ///
    /// **A failure that names only what it wanted is a failure you have to
    /// reproduce before you can read it.** This test spent two rounds of
    /// investigation being read as "the Locator is missing" when the question
    /// worth asking first was "then what *is* on screen, and under which
    /// attribute?" — so it now says so itself, and the next person gets the
    /// answer in the log rather than from a second run.
    private func describeWindows(of app: XCUIApplication) -> String {
        let windows = app.windows.allElementsBoundByIndex.map { window in
            "title=\(window.title.debugDescription) "
                + "identifier=\(window.identifier.debugDescription) "
                + "label=\(window.label.debugDescription)"
        }
        return windows.isEmpty ? "none at all" : windows.joined(separator: "; ")
    }

    /// The Locator, found by the title its own panel sets.
    ///
    /// **Not by a continent button, which is what made this test flaky.** It
    /// used to match a window *containing* a button titled "Europe", reasoning
    /// that continents are the one thing the main window has no equivalent of.
    /// That much is true. The trouble is that "Europe" is not Hipparchus's
    /// button — the string does not occur anywhere in the app. The panel holds a
    /// live `MKMapView`, and that is MapKit's own accessibility element for a
    /// **rendered** piece of map.
    ///
    /// So the assertion was really "MapKit has fetched and drawn tiles and
    /// published their labels" — in a suite that launches the app deliberately
    /// offline, on whatever machine happens to be free. It failed on launch 1
    /// of 5, the coldest tile cache, whenever the machine was busy, and the
    /// message it printed blamed the launch ordering for a map render.
    ///
    /// The title is set in `LocatorPanelController.show()`, synchronously,
    /// before the panel is ordered front — it is there the moment the window
    /// is, and it is precisely what this test means to ask about. The window
    /// tree carries two windows, "Locator" and "Hipparchus", so there is
    /// nothing to confuse it with.
    private func locator(in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == %@", "Locator")).firstMatch
    }
}
