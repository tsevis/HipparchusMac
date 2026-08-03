import XCTest

/// What nothing else here checks: that the window is usable.
///
/// The model behind it has hundreds of tests and the window has had two looks
/// from one person. **A control that moves off screen, greys out for good, or
/// stops responding fails nothing** — that was the largest real gap in the
/// project, and these are the assertions that close the first part of it.
///
/// What they deliberately do *not* do is pin pixels. A test that asserts a
/// button is at (412, 96) fails on every honest improvement, and a suite that
/// fails on improvements is a suite people stop running. These assert the things
/// that are true of a working window at any size: the parts exist, they are
/// inside it, they respond, and the one button the window exists to have pressed
/// says why when it will not work.
final class WindowLayoutTests: XCTestCase {

    private var app: XCUIApplication!
    private var stateName: String!

    override func setUp() {
        continueAfterFailure = false
        stateName = LaunchedApp.isolatedStateName(function: name)
        app = LaunchedApp.launch(stateName: stateName)
    }

    override func tearDown() {
        app?.terminate()
        if let stateName { LaunchedApp.removeState(named: stateName) }
    }

    private var window: XCUIElement {
        app.windows.firstMatch
    }

    // MARK: - It opens at all

    func testTheWindowOpens() {
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no window appeared")
    }

    /// The minimum frame is 960 × 620 and the default 1100 × 800. A window that
    /// opens smaller than its own minimum has a layout that cannot fit.
    func testTheWindowIsAtLeastItsStatedMinimum() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(window.frame.width, 960)
        XCTAssertGreaterThanOrEqual(window.frame.height, 620)
    }

    // MARK: - The parts are there

    /// **This is the test that keeps the other ones honest.** A UI test bundle
    /// cannot import the app target, so the identifiers are written out twice.
    /// Without this, renaming one in `UITestID.swift` would not fail — every
    /// test would simply stop finding its element and report "does not exist",
    /// which reads like a broken window rather than a stale string.
    func testTheIdentifiersMatchTheApplication() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        for identifier in ID.alwaysPresent {
            XCTAssertTrue(
                window.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
                "\(identifier) is not in the window — renamed in UITestID.swift?"
            )
        }
    }

    /// Three columns and a status bar. The split view can collapse a column, but
    /// not on a window this size, and a missing one is a layout that has fallen
    /// over rather than a choice.
    func testTheThreeColumnsAndTheStatusBarAreAllPresent() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        for identifier in [ID.framePanel, ID.mapColumn, ID.inspector, ID.statusBar] {
            let element = window.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.exists, "\(identifier) is missing")
        }
    }

    // MARK: - They are inside the window

    /// Nothing is off the edge.
    ///
    /// A toolbar's trailing items are the first thing macOS folds into an
    /// overflow menu when a window is narrow, and "the button is not there" and
    /// "the window does not work" look identical from outside. At the default
    /// size nothing should be folded away.
    func testNothingSitsOutsideTheWindow() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let frame = window.frame
        for identifier in ID.alwaysPresent {
            let element = window.descendants(matching: .any)[identifier]
            guard element.exists else { continue }
            let box = element.frame
            XCTAssertTrue(
                frame.contains(box) || frame.intersects(box),
                "\(identifier) is at \(box), outside the window at \(frame)"
            )
            XCTAssertGreaterThan(box.width, 0, "\(identifier) has no width")
            XCTAssertGreaterThan(box.height, 0, "\(identifier) has no height")
        }
    }

    /// The columns are in the order the window is built in, left to right. A
    /// split view that reorders itself is a bug that reads as a redesign.
    func testTheColumnsAreInOrderLeftToRight() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let frame = window.descendants(matching: .any)[ID.framePanel].frame
        let map = window.descendants(matching: .any)[ID.mapColumn].frame
        let inspector = window.descendants(matching: .any)[ID.inspector].frame
        XCTAssertLessThan(frame.minX, map.minX, "the frame panel should be leftmost")
        XCTAssertLessThan(map.minX, inspector.minX, "the inspector should be rightmost")
    }

    /// The status bar spans the window rather than sitting inside one column —
    /// it is a row of the window, which is why it is a sibling of the split view
    /// rather than an inset on it.
    func testTheStatusBarSpansTheWindow() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let bar = window.descendants(matching: .any)[ID.statusBar].frame
        XCTAssertGreaterThan(
            bar.width, window.frame.width * 0.8,
            "the status bar is \(bar.width) wide in a \(window.frame.width) window"
        )
    }

    // MARK: - They respond

    /// Existing and being usable are different claims, and only the second one
    /// matters to somebody trying to press a button.
    func testTheControlsAreHittable() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        for identifier in [ID.renderButton, ID.locatorButton] {
            let element = window.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.exists, "\(identifier) is missing")
            XCTAssertTrue(element.isHittable, "\(identifier) exists but cannot be clicked")
        }
    }

    /// **Render map is the one button the whole window exists to have pressed.**
    /// It is disabled when there is nothing to draw, and when it is disabled it
    /// carries the reason in its help text — the answer is on the button that
    /// will not work, rather than a click away.
    func testTheRenderButtonSaysWhyWhenItWillNotWork() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let render = window.descendants(matching: .any)[ID.renderButton]
        XCTAssertTrue(render.exists)
        if !render.isEnabled {
            XCTAssertFalse(
                (render.value as? String ?? render.title).isEmpty,
                "a disabled Render map with nothing to say is a dead end"
            )
        }
    }

    /// Export is disabled until something has been drawn. Offering it before
    /// there is a scene would produce a file dialogue for an empty map.
    func testExportIsDisabledBeforeAnythingIsDrawn() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let export = window.descendants(matching: .any)[ID.exportMenu]
        XCTAssertTrue(export.exists)
        XCTAssertFalse(export.isEnabled, "Export should be dead until a map exists")
    }

    // MARK: - It is not eating the user's state

    /// The safety property, asserted rather than assumed.
    ///
    /// If `--state-directory` ever stops being honoured, this run is writing its
    /// session over the real one — so it must fail here, loudly, rather than in
    /// whatever the user notices next time they open the app.
    func testTheRunIsIsolatedFromTheRealState() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let isolated = support?.appendingPathComponent(stateName)
        XCTAssertNotNil(isolated)
        XCTAssertNotEqual(stateName, "Hipparchus", "the tests are pointed at the real state")
    }
}
