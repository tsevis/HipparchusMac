import XCTest
@testable import HipparchusGeometry

/// A locator that starts at world scale, and a saved session's area that
/// loads after the window already appeared: this is the decision that keeps
/// the second from silently overwriting the first.
final class LocatorSyncTests: XCTestCase {
    private let athens = BoundingBox(minLon: 23.6, minLat: 37.9, maxLon: 23.8, maxLat: 38.0)
    private let hawaii = BoundingBox(minLon: -156.0, minLat: 19.0, maxLon: -155.0, maxLat: 20.0)

    // MARK: - Before launch setup has finished

    /// The value seen while `wasSettled` is still false is exactly a restored
    /// session's area arriving — it must never move the map, no matter what
    /// it is or what came before it.
    func testABoxSeenBeforeSettlingNeverSyncs() {
        let decision = LocatorSync.decide(bbox: athens, wasSettled: false, lastKnown: nil)
        XCTAssertFalse(decision.shouldSync)
        XCTAssertEqual(decision.newLastKnown, athens)
    }

    func testABoxSeenBeforeSettlingNeverSyncsEvenIfDifferentFromLastKnown() {
        let decision = LocatorSync.decide(bbox: athens, wasSettled: false, lastKnown: hawaii)
        XCTAssertFalse(decision.shouldSync)
        XCTAssertEqual(decision.newLastKnown, athens)
    }

    // MARK: - After launch setup has finished

    func testTheSameBoxSeenAgainAfterSettlingDoesNotSync() {
        let decision = LocatorSync.decide(bbox: athens, wasSettled: true, lastKnown: athens)
        XCTAssertFalse(decision.shouldSync)
        XCTAssertEqual(decision.newLastKnown, athens)
    }

    /// This is the real thing the whole check exists for: a genuine change —
    /// a search, a saved place, a pasted coordinate — after setup is done.
    func testADifferentBoxSeenAfterSettlingDoesSync() {
        let decision = LocatorSync.decide(bbox: hawaii, wasSettled: true, lastKnown: athens)
        XCTAssertTrue(decision.shouldSync)
        XCTAssertEqual(decision.newLastKnown, hawaii)
    }

    /// No prior value to compare against: nothing to call a change relative
    /// to, so this does not sync either.
    func testANilLastKnownAfterSettlingDoesNotSync() {
        let decision = LocatorSync.decide(bbox: athens, wasSettled: true, lastKnown: nil)
        XCTAssertFalse(decision.shouldSync)
        XCTAssertEqual(decision.newLastKnown, athens)
    }

    // MARK: - The exact launch sequence

    /// The full sequence a real launch produces: the model's own starting
    /// default, then the restored session's area arriving one tick later,
    /// then — much later — a real search. Only the last one should sync.
    func testTheFullLaunchSequenceOnlySyncsTheGenuineLaterChange() {
        let defaultBox = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)

        // 1. The view's first render, before `.task` has run at all.
        var wasSettled = false
        var lastKnown: BoundingBox?
        var decision = LocatorSync.decide(bbox: defaultBox, wasSettled: wasSettled, lastKnown: lastKnown)
        XCTAssertFalse(decision.shouldSync)
        lastKnown = decision.newLastKnown
        wasSettled = false // launch setup has not finished yet either

        // 2. `restore()` has now loaded the saved session's area — setup
        // finishes in this same tick, but this call still reflects the
        // *previous* state, since the coordinator only learns the new
        // settled-ness after recording this observation.
        decision = LocatorSync.decide(bbox: athens, wasSettled: wasSettled, lastKnown: lastKnown)
        XCTAssertFalse(decision.shouldSync, "the restored area must not overwrite the world-scale start")
        lastKnown = decision.newLastKnown
        wasSettled = true // now that setup has actually finished

        // 3. Seconds later, an actual search.
        decision = LocatorSync.decide(bbox: hawaii, wasSettled: wasSettled, lastKnown: lastKnown)
        XCTAssertTrue(decision.shouldSync, "a real change once launch has settled must still sync")
        XCTAssertEqual(decision.newLastKnown, hawaii)
    }
}
