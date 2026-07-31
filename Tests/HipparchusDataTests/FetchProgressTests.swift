import XCTest
@testable import HipparchusData

/// Per-source progress, and what cancelling honestly does.
///
/// Ported from `tests/test_fetch_progress.py`. A fetch can take five minutes
/// while a single status line says "Idle", and the wait is nearly always one
/// source. This is the type that turns an opaque wait into an explicable one, so
/// its reporting is worth pinning directly rather than through a whole fetch.
final class FetchProgressTests: XCTestCase {

    // MARK: - One source

    func testAWaitingSourceHasNoElapsedTime() {
        XCTAssertEqual(SourceProgress(sourceID: "overpass").elapsed(), .zero)
    }

    /// The clock stops when the source does, or a finished fetch would go on
    /// counting for as long as the window stayed open.
    func testAFinishedSourceStopsCounting() {
        var progress = SourceProgress(sourceID: "terrain_tiles")
        let start = ContinuousClock.now
        progress.state = .done
        progress.startedAt = start
        progress.finishedAt = start + .seconds(5)

        XCTAssertEqual(progress.elapsed(now: start + .seconds(5)), .seconds(5))
        // Ten minutes later it still reads five seconds.
        XCTAssertEqual(progress.elapsed(now: start + .seconds(600)), .seconds(5))
    }

    /// A running source counts up, because that is the reassurance the status bar
    /// exists to give.
    func testARunningSourceCountsUp() {
        var progress = SourceProgress(sourceID: "overpass")
        let start = ContinuousClock.now
        progress.state = .running
        progress.startedAt = start

        XCTAssertEqual(progress.elapsed(now: start + .seconds(9)), .seconds(9))
    }

    /// Each state says what it is, in words, rather than by a colour alone.
    func testSummariesReadAsEnglish() {
        var progress = SourceProgress(sourceID: "overpass")
        let start = ContinuousClock.now
        XCTAssertTrue(progress.summary().contains("waiting"))

        progress.state = .running
        progress.startedAt = start
        XCTAssertTrue(progress.summary(now: start + .seconds(42)).contains("42"))

        progress.state = .done
        progress.finishedAt = start + .seconds(42)
        progress.detail = "10 772 features"
        let done = progress.summary()
        XCTAssertTrue(done.contains("✓"))
        XCTAssertTrue(done.contains("10 772 features"), "the detail was dropped")

        progress.state = .cancelled
        XCTAssertTrue(progress.summary().contains("cancelled"))

        progress.state = .failed
        progress.detail = "timed out"
        let failed = progress.summary()
        XCTAssertTrue(failed.contains("failed"))
        XCTAssertTrue(failed.contains("timed out"), "a failure that does not say why is not a report")
    }

    // MARK: - The whole fetch

    func testAnEmptyFetchSummarisesToNothing() async {
        let summary = await FetchReporter().current.summary()
        XCTAssertEqual(summary, "")
    }

    func testExpectedSourcesAppearInTheOrderTheyWereAskedFor() async {
        let reporter = FetchReporter()
        await reporter.expect(["overpass", "terrain_tiles"])
        let sources = await reporter.current.sources.map(\.sourceID)
        XCTAssertEqual(sources, ["overpass", "terrain_tiles"])
    }

    /// Expecting a source twice must not list it twice — the manager may declare
    /// its plan more than once, and a status bar with two Overpass rows is wrong.
    func testExpectingTheSameSourceTwiceDoesNotDuplicateIt() async {
        let reporter = FetchReporter()
        await reporter.expect(["overpass"])
        await reporter.expect(["overpass", "terrain_tiles"])

        let sources = await reporter.current.sources.map(\.sourceID)
        XCTAssertEqual(sources, ["overpass", "terrain_tiles"])
    }

    /// A source nobody announced still gets a row rather than being lost: better
    /// a surprise in the status bar than work happening invisibly.
    func testAnUnexpectedSourceIsStillRecorded() async {
        let reporter = FetchReporter()
        await reporter.started("surprise")

        let progress = await reporter.current
        XCTAssertEqual(progress.source("surprise")?.state, .running)
    }

    /// A source that broke and a source that was called off are different
    /// stories, and a map that says "failed" for both teaches the wrong lesson.
    func testFailureAndCancellationAreDistinct() async {
        let reporter = FetchReporter()
        await reporter.expect(["a", "b"])
        await reporter.failed("a", detail: "timeout")
        await reporter.cancelled("b")

        let progress = await reporter.current
        XCTAssertEqual(progress.source("a")?.state, .failed)
        XCTAssertEqual(progress.source("a")?.detail, "timeout")
        XCTAssertEqual(progress.source("b")?.state, .cancelled)
        XCTAssertFalse(progress.isRunning)
    }

    /// **What cancelling can and cannot do.** Sources not yet started are
    /// skipped and running ones are marked off, but a source that already
    /// finished keeps its result — the request came back, and pretending
    /// otherwise would throw away work that was paid for.
    func testCancellingLeavesFinishedWorkAlone() async {
        let reporter = FetchReporter()
        await reporter.expect(["done", "running", "waiting"])
        await reporter.started("done")
        await reporter.finished("done", detail: "1 200 features")
        await reporter.started("running")
        await reporter.cancelRemaining()

        let progress = await reporter.current
        XCTAssertEqual(progress.source("done")?.state, .done)
        XCTAssertEqual(progress.source("done")?.detail, "1 200 features")
        XCTAssertEqual(progress.source("running")?.state, .cancelled)
        XCTAssertEqual(progress.source("waiting")?.state, .cancelled)
        XCTAssertFalse(progress.isRunning)
    }

    /// A late observer sees the state at the moment it subscribed rather than a
    /// blank panel until something next happens.
    func testAnObserverIsGivenTheCurrentStateImmediately() async {
        let reporter = FetchReporter()
        await reporter.expect(["overpass"])
        await reporter.started("overpass")

        var iterator = await reporter.updates().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.source("overpass")?.state, .running)
    }

    /// The stream carries every change, so the status bar fills in as sources
    /// answer rather than jumping from empty to complete.
    func testEachChangeReachesTheObservers() async {
        let reporter = FetchReporter()
        await reporter.expect(["overpass"])

        let stream = await reporter.updates()
        await reporter.started("overpass")
        await reporter.finished("overpass", detail: "done")

        var seen: [SourceState] = []
        for await snapshot in stream {
            if let state = snapshot.source("overpass")?.state {
                if seen.last != state { seen.append(state) }
            }
            if seen.last == .done { break }
        }
        XCTAssertEqual(seen, [.waiting, .running, .done])
    }
}
