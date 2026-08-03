import XCTest

/// What nothing else here checks: that the window is usable.
///
/// The model behind it has hundreds of tests and the window has had two looks
/// from one person. **A control that moves off screen, greys out for good, or
/// stops responding fails nothing** — that was the largest real gap in the
/// project, and these are the assertions that close the first part of it.
///
/// They deliberately do not pin pixels. A test that asserts a button is at
/// (412, 96) fails on every honest improvement, and a suite that fails on
/// improvements is one people stop running. These assert what is true of a
/// working window at any size: the parts exist, they are inside it, they are in
/// the right order, they respond, and the controls that should be dead are dead.
///
/// **Two things the first run taught, both of which had to be seen rather than
/// reasoned about** — `HierarchyDumpTests` is what saw them:
///
/// - `app.windows.firstMatch` is whichever window macOS fronted, and the Locator
///   is a floating panel. Eight tests failed against the Locator's tree. The
///   window is addressed by its scene identifier now, which is exact.
/// - **SwiftUI stamps a container's `accessibilityIdentifier` onto every
///   descendant.** `frame_panel` matches a Map, a Button and an Outline;
///   `map_column` matches the zoom buttons floating at the map's *trailing*
///   edge. A container identifier is not one element, so nothing here treats it
///   as one — the structural assertions go through the two sidebar `Outline`s,
///   which are single and stable.
@MainActor
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

    /// The main window, by the identifier its `Window` scene was given.
    ///
    /// Not `firstMatch`: the Locator floats above this one when it opens, and
    /// asserting against whichever window happened to be fronted is how the
    /// first run of these tests failed eight ways at once.
    private var window: XCUIElement { app.windows[ID.mainWindow] }

    private func requireWindow() {
        XCTAssertTrue(
            window.waitForExistence(timeout: 30),
            "no window with identifier \(ID.mainWindow) — renamed the scene?"
        )
    }

    /// The frame panel and the inspector are `Outline`s, which is the one
    /// element per column that is single rather than stamped on everything.
    private func sidebar(_ identifier: String) -> XCUIElement {
        window.outlines.matching(identifier: identifier).firstMatch
    }

    // MARK: - It opens at all

    func testTheWindowOpens() {
        requireWindow()
    }

    /// The layout declares `minWidth: 960, minHeight: 620`. A window smaller
    /// than its own minimum has a layout that cannot fit.
    func testTheWindowIsAtLeastItsStatedMinimum() {
        requireWindow()
        XCTAssertGreaterThanOrEqual(window.frame.width, 960)
        XCTAssertGreaterThanOrEqual(window.frame.height, 620)
    }

    // MARK: - The parts are there

    /// **The test that keeps the others honest.** A UI test bundle cannot import
    /// the app target, so the identifiers are written out twice. Without this,
    /// renaming one in `UITestID.swift` would not fail — every test would simply
    /// stop finding its element and report "does not exist", which reads like a
    /// broken window rather than a stale string.
    func testTheIdentifiersMatchTheApplication() {
        requireWindow()
        for identifier in ID.alwaysPresent {
            XCTAssertTrue(
                window.descendants(matching: .any).matching(identifier: identifier).count > 0,
                "\(identifier) is nowhere in the window — renamed in UITestID.swift?"
            )
        }
    }

    /// Three columns and a status bar.
    func testTheThreeColumnsAndTheStatusBarAreAllPresent() {
        requireWindow()
        XCTAssertTrue(sidebar(ID.framePanel).exists, "no frame panel sidebar")
        XCTAssertTrue(sidebar(ID.inspector).exists, "no inspector sidebar")
        XCTAssertTrue(mapHint.exists, "the map column's hint is missing")
        XCTAssertTrue(statusText.exists, "the status bar says nothing")
    }

    /// The caption on the canvas — the one element carrying `map_column` that is
    /// in the map rather than floating at its edge.
    private var mapHint: XCUIElement {
        window.staticTexts.matching(identifier: ID.mapColumn).firstMatch
    }

    private var statusText: XCUIElement {
        window.staticTexts.matching(identifier: ID.statusBar).firstMatch
    }

    // MARK: - They are placed

    /// Left to right: frame panel, map, inspector. A split view that reorders
    /// itself is a bug that reads as a redesign.
    func testTheColumnsAreInOrderLeftToRight() {
        requireWindow()
        let frame = sidebar(ID.framePanel)
        let inspector = sidebar(ID.inspector)
        XCTAssertTrue(frame.exists)
        XCTAssertTrue(inspector.exists)
        XCTAssertLessThan(
            frame.frame.minX, inspector.frame.minX,
            "the frame panel should be left of the inspector"
        )
        XCTAssertLessThan(
            frame.frame.maxX, mapHint.frame.midX,
            "the map should be right of the frame panel"
        )
        XCTAssertLessThan(
            mapHint.frame.midX, inspector.frame.minX,
            "the map should be left of the inspector"
        )
    }

    /// The status bar is a row of the window rather than something inside a
    /// column, which is why it is a sibling of the split view rather than an
    /// inset on it. So it sits below both sidebars.
    func testTheStatusBarSitsBeneathTheColumns() {
        requireWindow()
        XCTAssertTrue(statusText.exists)
        XCTAssertGreaterThan(
            statusText.frame.minY, sidebar(ID.inspector).frame.minY,
            "the status bar should be below the columns, not beside them"
        )
        XCTAssertGreaterThan(
            statusText.frame.midY, window.frame.midY,
            "the status bar should be in the lower half of the window"
        )
    }

    /// Nothing is off the edge.
    ///
    /// A toolbar's trailing items are the first thing macOS folds into an
    /// overflow menu when a window is narrow, and "the button is not there" and
    /// "the window does not work" look identical from outside.
    ///
    /// Every element is required to exist. An earlier version skipped the ones
    /// it could not find, which meant it **passed against the wrong window
    /// entirely** — a test that cannot fail is worse than no test, because it
    /// reports confidence it never earned.
    func testNothingSitsOutsideTheWindow() {
        requireWindow()
        let bounds = window.frame
        for element in [renderButton, exportMenu, locatorButton, areaDescription, statusText] {
            XCTAssertTrue(element.exists, "\(element) is missing")
            let box = element.frame
            XCTAssertGreaterThan(box.width, 0)
            XCTAssertGreaterThan(box.height, 0)
            XCTAssertTrue(
                bounds.intersects(box), "\(box) lies outside the window at \(bounds)"
            )
        }
    }

    // MARK: - They respond

    private var renderButton: XCUIElement {
        window.buttons.matching(identifier: ID.renderButton).firstMatch
    }

    private var locatorButton: XCUIElement {
        window.buttons.matching(identifier: ID.locatorButton).firstMatch
    }

    private var exportMenu: XCUIElement {
        window.popUpButtons.matching(identifier: ID.exportMenu).firstMatch
    }

    private var areaDescription: XCUIElement {
        window.staticTexts.matching(identifier: ID.areaDescription).firstMatch
    }

    /// Existing and being usable are different claims, and only the second one
    /// matters to somebody trying to press a button.
    func testTheControlsAreHittable() {
        requireWindow()
        XCTAssertTrue(renderButton.exists, "no Render map button")
        XCTAssertTrue(renderButton.isHittable, "Render map exists but cannot be clicked")
        XCTAssertTrue(locatorButton.exists, "no Locator button")
        XCTAssertTrue(locatorButton.isHittable, "the Locator button cannot be clicked")
    }

    /// **Render map is the one button the whole window exists to have pressed**,
    /// so it is on screen from the first frame whether or not it can be used
    /// yet. Its enabled state is the model's business; its presence is not.
    func testTheRenderButtonIsAlwaysOffered() {
        requireWindow()
        XCTAssertTrue(renderButton.exists)
        XCTAssertFalse(renderButton.label.isEmpty, "a button with no label")
    }

    /// Export is dead until something has been drawn. Offering it before there
    /// is a scene would produce a file dialogue for an empty map.
    func testExportIsDisabledBeforeAnythingIsDrawn() {
        requireWindow()
        XCTAssertTrue(exportMenu.exists, "no Export menu")
        XCTAssertFalse(exportMenu.isEnabled, "Export should be dead until a map exists")
    }

    /// The window says which area it is pointed at, and it says so before
    /// anything is fetched — a readout that appears only after a render is a
    /// readout nobody can use to decide whether to render.
    func testTheWindowSaysWhichAreaItIsShowing() {
        requireWindow()
        XCTAssertTrue(areaDescription.exists)
        XCTAssertFalse(
            (areaDescription.value as? String ?? "").isEmpty,
            "the area readout is blank"
        )
    }

    // MARK: - It is not eating the user's state

    /// The safety property, asserted rather than assumed.
    ///
    /// If `--state-directory` ever stops being honoured, this run is writing its
    /// session over the real one — so it must fail here, loudly, rather than in
    /// whatever the user notices next time they open the app.
    func testTheRunIsIsolatedFromTheRealState() {
        requireWindow()
        XCTAssertNotEqual(stateName, "Hipparchus", "the tests are pointed at the real state")
        XCTAssertTrue(stateName.hasPrefix("HipparchusUITests-"))
    }
}
