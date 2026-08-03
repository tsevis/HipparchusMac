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
            let app = LaunchedApp.launch(stateName: stateName)
            defer {
                app.terminate()
                LaunchedApp.removeState(named: stateName)
            }

            XCTAssertTrue(
                app.windows[ID.mainWindow].waitForExistence(timeout: 30),
                "launch \(attempt): no main window"
            )
            XCTAssertTrue(
                locator(in: app).waitForExistence(timeout: 15),
                "launch \(attempt) of \(Self.attempts): the Locator did not open. "
                    + "If this passes sometimes and fails others, the launch "
                    + "ordering has come apart again — see ContentView.openOnLaunch()."
            )
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

    /// The Locator, found by something only it has.
    ///
    /// It carries a `Locator` title and a world map of continent buttons, and
    /// the continents are the part the main window has no equivalent of.
    private func locator(in app: XCUIApplication) -> XCUIElement {
        app.windows.containing(
            NSPredicate(format: "elementType == %d AND title == %@", XCUIElement.ElementType.button.rawValue, "Europe")
        ).firstMatch
    }
}
