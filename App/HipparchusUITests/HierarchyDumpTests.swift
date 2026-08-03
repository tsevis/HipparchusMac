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
/// It asserts nothing, so it cannot fail for a reason that matters. Run it alone
/// when an identifier stops resolving:
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

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
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
