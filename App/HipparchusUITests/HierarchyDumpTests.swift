import XCTest

/// Prints the window tree, so authoring a layout test is looking rather than
/// guessing.
///
/// **This is the equivalent of rendering a sheet and reading the PNG.** The
/// first run of the layout tests failed eight ways, and every one of them traced
/// to a single wrong assumption about which window `windows.firstMatch` returns.
/// Guessing again would have been the same mistake twice; this dumps what is
/// actually there.
///
/// It asserts one thing — that a window exists to be printed — and nothing about
/// what is in it, so it cannot fail for a reason that matters. Run it alone when
/// an identifier stops resolving:
///
///     xcodebuild test -project App/HipparchusMac.xcodeproj \
///         -scheme HipparchusUITests -destination 'platform=macOS' \
///         -only-testing:HipparchusUITests/HierarchyDumpTests
@MainActor
final class HierarchyDumpTests: XCTestCase {

    func testPrintsEveryWindow() {
        let stateName = LaunchedApp.isolatedStateName(function: name)
        let app = LaunchedApp.launch(stateName: stateName)
        defer {
            app.terminate()
            LaunchedApp.removeState(named: stateName)
        }

        // **Not `.runningForeground`.** This used to wait for the front, on the
        // shortest timeout in the bundle, and under load it was the timeout
        // that lost — sixteen tests launch and quit applications in sequence,
        // and each handover is an argument about who gets activated.
        //
        // Being in front was never incidental, though, and that is the part
        // worth writing down: the Locator is an `NSPanel`,
        // `NSPanel.hidesOnDeactivate` defaults to `true`, and a dump taken from
        // the background is a dump with the floating panels missing. **This
        // test never saw that bug precisely because it waited for the front**,
        // while `LaunchOrderTests`, which did not, spent three rounds of
        // investigation calling a hidden panel a broken launch.
        //
        // The panel now stops hiding under the harness, so the tree is complete
        // whether or not this app is frontmost — see
        // `LocatorPanelController.show()`. Which means the front can stop being
        // demanded here, and this suite is that much less of an imposition on
        // whoever is trying to use the machine.
        //
        // What is left is the real requirement: something to dump. *Any*
        // window, rather than `ID.mainWindow`, because this is the test you run
        // when an identifier has stopped resolving — a diagnostic that asserts
        // the identifier it exists to investigate would go red exactly when it
        // is needed, and print nothing.
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 30),
            "the application opened no window at all — nothing to dump"
        )
        // Give the window a moment to build itself. A tree read while SwiftUI is
        // still assembling is a picture of a window that never existed.
        Thread.sleep(forTimeInterval: 3)

        print("=== HIPPARCHUS WINDOW COUNT: \(app.windows.count)")
        for index in 0..<app.windows.count {
            let window = app.windows.element(boundBy: index)
            print("=== HIPPARCHUS WINDOW \(index) frame=\(window.frame) title=\(window.title.debugDescription) identifier=\(window.identifier.debugDescription)")
        }
        print("=== HIPPARCHUS FULL TREE BEGIN")
        print(app.debugDescription)
        print("=== HIPPARCHUS FULL TREE END")
    }
}
