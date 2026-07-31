import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// The undo stack, argued as a value type.
///
/// Every rule that makes undo feel right — one action per intention, names in the
/// menu, a fetch that undoes instantly, memory that does not grow without bound —
/// is a rule about values, and is tested here without a window.
final class SessionHistoryTests: XCTestCase {

    private func session(preset: String = "Hypsometric Relief", west: Double = 25.32) -> Session {
        var session = Session()
        session.presetName = preset
        session.area.west = west
        return session
    }

    private func scene(_ mark: String) -> RenderScene {
        RenderScene(metadata: ["mark": .string(mark)])
    }

    private func mark(_ scene: RenderScene?) -> String? {
        scene?.metadata["mark"]?.stringValue
    }

    // MARK: - Undo and redo

    func testUndoRestoresTheStateBeforeTheChange() {
        var history = SessionHistory(initial: session())
        XCTAssertFalse(history.canUndo, "nothing has happened yet")

        history.record(session(preset: "Contour Study"), action: "Change Preset", at: 0)
        XCTAssertTrue(history.canUndo)

        let restored = history.undo()
        XCTAssertEqual(restored?.session.presetName, "Hypsometric Relief")
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo)
    }

    func testRedoRestoresWhatUndoTookAway() {
        var history = SessionHistory(initial: session())
        history.record(session(preset: "Contour Study"), action: "Change Preset", at: 0)
        _ = history.undo()

        let restored = history.redo()
        XCTAssertEqual(restored?.session.presetName, "Contour Study")
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    /// macOS puts the action name in the menu — "Undo Change Preset" — and a menu
    /// that only ever says "Undo" is a menu that tells you nothing.
    func testTheMenuNamesTheActionItWillUndo() {
        var history = SessionHistory(initial: session())
        XCTAssertNil(history.undoActionName)

        history.record(session(preset: "Contour Study"), action: "Change Preset", at: 0)
        XCTAssertEqual(history.undoActionName, "Change Preset")

        _ = history.undo()
        XCTAssertNil(history.undoActionName)
        XCTAssertEqual(history.redoActionName, "Change Preset")
    }

    func testANewActionCutsTheRedoBranchOff() {
        var history = SessionHistory(initial: session())
        history.record(session(preset: "Contour Study"), action: "Change Preset", at: 0)
        _ = history.undo()

        history.record(session(preset: "Blueprint"), action: "Change Preset", at: 10)
        XCTAssertFalse(history.canRedo, "the branch that was undone is gone")
        XCTAssertEqual(history.current.session.presetName, "Blueprint")
    }

    // MARK: - Coalescing

    /// Dragging a stepper from 60 to 120 is one action to a person and sixty to
    /// the model. One ⌘Z must take all of it back.
    func testARunOfStepperTicksIsOneAction() {
        var history = SessionHistory(initial: session(west: 25.0))
        let first = history.record(session(west: 25.1), action: "Change Area", coalescing: "area", at: 0.0)
        let second = history.record(session(west: 25.2), action: "Change Area", coalescing: "area", at: 0.2)
        let third = history.record(session(west: 25.3), action: "Change Area", coalescing: "area", at: 0.4)

        XCTAssertTrue(first, "the first tick opens the action")
        XCTAssertFalse(second, "the run continues the action")
        XCTAssertFalse(third)

        XCTAssertEqual(history.undo()?.session.area.west, 25.0, "one undo takes the whole run back")
        XCTAssertFalse(history.canUndo)
    }

    /// Come back to the same control later and it is a new action.
    func testCoalescingEndsWhenTimePasses() {
        var history = SessionHistory(initial: session(west: 25.0))
        history.record(session(west: 25.1), action: "Change Area", coalescing: "area", at: 0)
        let later = history.record(session(west: 25.2), action: "Change Area", coalescing: "area", at: 5)

        XCTAssertTrue(later, "a pause separates intentions")
        XCTAssertEqual(history.undo()?.session.area.west, 25.1)
        XCTAssertEqual(history.undo()?.session.area.west, 25.0)
    }

    func testCoalescingNeverMergesAcrossDifferentControls() {
        var history = SessionHistory(initial: session(west: 25.0))
        history.record(session(west: 25.1), action: "Change Area", coalescing: "area", at: 0)
        let other = history.record(
            session(preset: "Blueprint", west: 25.1), action: "Change Preset", coalescing: "preset", at: 0.1
        )
        XCTAssertTrue(other)
        XCTAssertEqual(history.undo()?.session.presetName, "Hypsometric Relief")
        XCTAssertEqual(history.undo()?.session.area.west, 25.0)
    }

    /// An edit straight after redo must not merge into the entry it redid, or one
    /// undo would then jump two intentions.
    func testAnEditAfterRedoIsItsOwnAction() {
        var history = SessionHistory(initial: session(west: 25.0))
        history.record(session(west: 25.1), action: "Change Area", coalescing: "area", at: 0)
        _ = history.undo()
        _ = history.redo()

        let boundary = history.record(session(west: 25.2), action: "Change Area", coalescing: "area", at: 0.2)
        XCTAssertTrue(boundary)
        XCTAssertEqual(history.undo()?.session.area.west, 25.1)
        XCTAssertEqual(history.undo()?.session.area.west, 25.0)
    }

    /// SwiftUI observation can fire without anything changing; a no-op is not an
    /// action, and must not eat a real one from the redo stack.
    func testRecordingAnUnchangedStateIsNotAnAction() {
        var history = SessionHistory(initial: session())
        _ = history.record(session(preset: "Contour Study"), action: "Change Preset", at: 0)
        _ = history.undo()

        let boundary = history.record(session(), action: "Change Preset", at: 1)
        XCTAssertFalse(boundary)
        XCTAssertFalse(history.canUndo)
        XCTAssertTrue(history.canRedo, "a no-op wrongly cut the redo branch")
    }

    // MARK: - Fetching

    /// The rule that shapes the whole design: undo of a fetch restores the
    /// previous scene, and never re-fetches — undo must not cost minutes of
    /// Overpass time to take back something that cost minutes of Overpass time.
    func testUndoOfAFetchRestoresThePreviousSceneWithoutFetching() {
        var history = SessionHistory(initial: session())
        history.recordFetch(session(), scene: scene("santorini"), action: "Fetch Map", at: 0)
        history.recordFetch(session(west: 23.5), scene: scene("athens"), action: "Fetch Map", at: 60)

        let previous = history.undo()
        XCTAssertEqual(mark(history.scene(for: previous?.sceneToken)), "santorini")

        let first = history.undo()
        XCTAssertNil(first?.sceneToken, "before any fetch there was no map")
    }

    /// A fetch with unchanged choices is still an action — the map changed.
    func testAFetchIsAnActionEvenWhenNoChoiceChanged() {
        var history = SessionHistory(initial: session())
        history.recordFetch(session(), scene: scene("first"), action: "Fetch Map", at: 0)
        let second = history.recordFetch(session(), scene: scene("second"), action: "Fetch Map", at: 1)

        XCTAssertTrue(second)
        XCTAssertEqual(history.undoActionName, "Fetch Map")
        XCTAssertEqual(mark(history.scene(for: history.undo()?.sceneToken)), "first")
    }

    // MARK: - Bounds

    /// A session of a thousand edits must not hold a thousand entries.
    func testTheHistoryDoesNotGrowWithoutBound() {
        var history = SessionHistory(initial: session(west: 0), maxDepth: 3)
        for step in 1...5 {
            history.record(session(west: Double(step)), action: "Change Area", at: Double(step) * 10)
        }

        var undos = 0
        while history.canUndo {
            _ = history.undo()
            undos += 1
        }
        XCTAssertEqual(undos, 3)
        XCTAssertEqual(history.current.session.area.west, 2, "the oldest retained state")
    }

    /// Scenes are the expensive part — a city fetch is tens of megabytes — so only
    /// the newest few are kept. An entry whose scene was let go still restores its
    /// choices; the canvas is honestly empty rather than silently re-fetched.
    func testOnlyTheNewestScenesAreKept() {
        var history = SessionHistory(initial: session(), maxScenes: 2)
        history.recordFetch(session(west: 1), scene: scene("a"), action: "Fetch Map", at: 0)
        let tokenA = history.current.sceneToken
        history.recordFetch(session(west: 2), scene: scene("b"), action: "Fetch Map", at: 1)
        history.recordFetch(session(west: 3), scene: scene("c"), action: "Fetch Map", at: 2)

        XCTAssertNil(history.scene(for: tokenA), "the oldest scene was kept beyond the cap")
        XCTAssertEqual(mark(history.scene(for: history.current.sceneToken)), "c")

        _ = history.undo()
        XCTAssertEqual(mark(history.scene(for: history.current.sceneToken)), "b")

        let oldest = history.undo()
        XCTAssertEqual(oldest?.session.area.west, 1, "the choices still come back")
        XCTAssertNil(history.scene(for: oldest?.sceneToken), "but the scene is honestly gone")
    }

    /// Cutting the redo branch must also release the scenes it held.
    func testACutRedoBranchReleasesItsScenes() {
        var history = SessionHistory(initial: session())
        history.recordFetch(session(west: 1), scene: scene("kept"), action: "Fetch Map", at: 0)
        history.recordFetch(session(west: 2), scene: scene("dropped"), action: "Fetch Map", at: 1)
        let droppedToken = history.current.sceneToken

        _ = history.undo()
        history.record(session(west: 9), action: "Change Area", at: 10)

        XCTAssertNil(history.scene(for: droppedToken), "the branch is gone; its scene must go too")
        XCTAssertEqual(mark(history.scene(for: history.current.sceneToken)), "kept")
    }
}
