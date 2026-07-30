import Foundation

/// Progress and cancellation for a fetch.
///
/// Ported from `core/fetch_progress.py`.
///
/// A fetch can take five minutes while the status bar says "Idle", and the wait is
/// nearly always one source — Overpass — with the others finishing in seconds.
/// Reporting per source turns an opaque wait into an explicable one.
///
/// **Cancellation is honest about what it can do.** A request already in flight
/// cannot be torn out of its socket, so cancelling means three things: sources that
/// have not started are skipped, sources that check between requests stop early,
/// and the result of whatever is still running is discarded rather than drawn. The
/// map you were looking at stays on screen and the app is yours again immediately.
/// Say that plainly rather than implying more.
///
/// The Python needs a `CancellationToken` because a Python thread cannot be
/// cancelled. Swift has cooperative cancellation built in, so the token is gone and
/// `Task.isCancelled` does the same job — one fewer thing to keep in step.

public enum SourceState: String, Sendable, Equatable {
    case waiting
    case running
    case done
    case failed
    case cancelled
}

/// How one source in this fetch is getting on.
public struct SourceProgress: Sendable, Equatable, Identifiable {
    public let sourceID: String
    public var state: SourceState = .waiting
    public var startedAt: ContinuousClock.Instant?
    public var finishedAt: ContinuousClock.Instant?
    /// A short note about what this source actually returned.
    public var detail: String = ""

    public var id: String { sourceID }

    public init(sourceID: String) {
        self.sourceID = sourceID
    }

    public func elapsed(now: ContinuousClock.Instant = ContinuousClock.now) -> Duration {
        guard let startedAt else { return .zero }
        return (finishedAt ?? now) - startedAt
    }

    public func summary(now: ContinuousClock.Instant = ContinuousClock.now) -> String {
        let seconds = Double(elapsed(now: now).components.seconds)
            + Double(elapsed(now: now).components.attoseconds) / 1e18
        switch state {
        case .waiting: return "\(sourceID) waiting"
        case .running: return String(format: "%@ %.0f s", sourceID, seconds)
        case .done:
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return String(format: "%@ ✓ %.1f s%@", sourceID, seconds, suffix)
        case .cancelled: return "\(sourceID) cancelled"
        case .failed:
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "\(sourceID) failed\(suffix)"
        }
    }
}

/// A snapshot of every source in one fetch, in the order they were asked for.
public struct FetchProgress: Sendable, Equatable {
    public private(set) var sources: [SourceProgress]

    public init(sources: [SourceProgress] = []) {
        self.sources = sources
    }

    public func source(_ id: String) -> SourceProgress? {
        sources.first { $0.sourceID == id }
    }

    public var isRunning: Bool { sources.contains { $0.state == .running } }

    /// One line for the status bar.
    public func summary(now: ContinuousClock.Instant = ContinuousClock.now) -> String {
        sources.map { $0.summary(now: now) }.joined(separator: "  ·  ")
    }

    // MARK: - Mutation, used by the reporter

    mutating func expect(_ ids: [String]) {
        for id in ids where !sources.contains(where: { $0.sourceID == id }) {
            sources.append(SourceProgress(sourceID: id))
        }
    }

    mutating func update(_ id: String, _ change: (inout SourceProgress) -> Void) {
        guard let index = sources.firstIndex(where: { $0.sourceID == id }) else {
            var progress = SourceProgress(sourceID: id)
            change(&progress)
            sources.append(progress)
            return
        }
        change(&sources[index])
    }
}

/// Collects per-source progress and publishes snapshots.
///
/// An actor rather than a lock: the fetch runs off the main actor and the interface
/// observes from it, and this is exactly the shared mutable state actors exist for.
/// Observers receive immutable snapshots, so a view can never see the reporter
/// half-way through an update.
public actor FetchReporter {
    private var progress = FetchProgress()
    private var continuations: [UUID: AsyncStream<FetchProgress>.Continuation] = [:]

    public init() {}

    public var current: FetchProgress { progress }

    /// A stream of snapshots, starting with the state at the moment of subscribing
    /// so a late observer is not left blank until the next change.
    public func updates() -> AsyncStream<FetchProgress> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(progress)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    public func expect(_ ids: [String]) {
        progress.expect(ids)
        publish()
    }

    public func started(_ id: String) {
        progress.update(id) {
            $0.state = .running
            $0.startedAt = ContinuousClock.now
        }
        publish()
    }

    public func finished(_ id: String, detail: String = "") {
        progress.update(id) {
            $0.state = .done
            $0.finishedAt = ContinuousClock.now
            $0.detail = detail
        }
        publish()
    }

    public func failed(_ id: String, detail: String = "") {
        progress.update(id) {
            $0.state = .failed
            $0.finishedAt = ContinuousClock.now
            $0.detail = detail
        }
        publish()
    }

    public func cancelled(_ id: String) {
        progress.update(id) {
            $0.state = .cancelled
            $0.finishedAt = ContinuousClock.now
        }
        publish()
    }

    /// Mark everything still waiting or running as cancelled, in one step.
    public func cancelRemaining() {
        for source in progress.sources where source.state == .waiting || source.state == .running {
            progress.update(source.sourceID) {
                $0.state = .cancelled
                $0.finishedAt = ContinuousClock.now
            }
        }
        publish()
    }

    private func publish() {
        for continuation in continuations.values {
            continuation.yield(progress)
        }
    }

    /// Close every stream. Called when a fetch finishes for good.
    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }
}
