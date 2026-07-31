import Foundation

/// Every state the app has been in, so any of them can be the state again.
///
/// This is the undo stack, and it is a value type over value types on purpose:
/// `Session` already snapshots every choice the app holds — sources, paths,
/// settings, preset, quality, hidden layers, area, the derived switches — so an
/// undo entry is a `Session` plus a reference to the scene that was on screen.
/// Undo restores; it never recomputes. In particular **undo of a fetch restores
/// the previous scene rather than re-fetching it**: undo must not cost minutes of
/// Overpass time to take back something that cost minutes of Overpass time.
///
/// Scenes are held by token in a bounded store rather than inline, because a city
/// fetch is tens of megabytes and a history of a hundred of them would not fit.
/// An entry whose scene has been let go still restores its choices, and the
/// canvas is honestly empty rather than silently re-fetched.
///
/// The window's `UndoManager` is driven *by* this type, one registration per
/// boundary `record` reports; the reverse — asking `UndoManager` what happened —
/// would put the truth in an object that cannot be inspected or tested.
public struct SessionHistory: Sendable {

    /// What an entry restores: the choices, and which scene was on screen.
    public struct Snapshot: Sendable, Equatable {
        public var session: Session
        public var sceneToken: Int?
    }

    private struct Entry: Sendable {
        var snapshot: Snapshot
        /// What the Edit menu shows: "Undo Change Preset", "Undo Fetch Map".
        var action: String
        /// Same key arriving within the window continues one action; `nil` never
        /// coalesces. Stripped when an entry is restored by undo or redo, so a new
        /// edit after either is always its own action.
        var key: String?
        var time: TimeInterval
    }

    private var past: [Entry] = []
    private var present: Entry
    private var future: [Entry] = []
    private var scenes: [Int: RenderScene] = [:]
    private var nextToken = 0

    /// Seconds within which a repeated key continues the same action. A stepper
    /// drag ticks every few hundredths; coming back to a control after a pause is
    /// a new intention.
    public let coalescingWindow: TimeInterval
    /// Entries kept. Sessions are small; this bounds the *number* of intentions.
    public let maxDepth: Int
    /// Scenes kept. Scenes are large; this bounds the memory.
    public let maxScenes: Int

    public init(
        initial: Session,
        coalescingWindow: TimeInterval = 1.0,
        maxDepth: Int = 100,
        maxScenes: Int = 8
    ) {
        self.present = Entry(
            snapshot: Snapshot(session: initial, sceneToken: nil),
            action: "", key: nil, time: -.infinity
        )
        self.coalescingWindow = coalescingWindow
        self.maxDepth = maxDepth
        self.maxScenes = maxScenes
    }

    // MARK: - Reading

    public var current: Snapshot { present.snapshot }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// The name of the action ⌘Z would take back — the one that made the present.
    public var undoActionName: String? { past.isEmpty ? nil : present.action }
    public var redoActionName: String? { future.last?.action }

    public func scene(for token: Int?) -> RenderScene? {
        token.flatMap { scenes[$0] }
    }

    // MARK: - Recording

    /// Record a change of choices. Returns whether a new undo boundary was made —
    /// the caller registers exactly one `UndoManager` action per `true`.
    @discardableResult
    public mutating func record(
        _ session: Session,
        action: String,
        coalescing key: String? = nil,
        at time: TimeInterval
    ) -> Bool {
        let snapshot = Snapshot(session: session, sceneToken: present.snapshot.sceneToken)
        // Observation can fire without anything changing, and a no-op must not
        // become an entry — nor cut the redo branch a real undo just grew.
        guard snapshot != present.snapshot else { return false }

        cutRedoBranch()

        if let key, key == present.key, time - present.time < coalescingWindow {
            // The run continues: the same intention, a newer state. The entry
            // under it — the state before the run — stays where it is.
            present.snapshot = snapshot
            present.time = time
            return false
        }

        push(Entry(snapshot: snapshot, action: action, key: key, time: time))
        return true
    }

    /// Record a completed fetch: the same choices, a new map. Always a boundary —
    /// the map changed, whatever the choices did.
    @discardableResult
    public mutating func recordFetch(
        _ session: Session,
        scene: RenderScene,
        action: String = "Fetch Map",
        at time: TimeInterval
    ) -> Bool {
        cutRedoBranch()

        let token = nextToken
        nextToken += 1
        scenes[token] = scene

        push(Entry(
            snapshot: Snapshot(session: session, sceneToken: token),
            action: action, key: nil, time: time
        ))
        evictScenesBeyondCap()
        return true
    }

    // MARK: - Travelling

    /// Step back, returning the state to put on screen. `nil` at the beginning.
    public mutating func undo() -> Snapshot? {
        guard var previous = past.popLast() else { return nil }
        future.append(present)
        // A restored entry is a destination, not an action in progress: the next
        // edit must not merge into it.
        previous.key = nil
        present = previous
        return present.snapshot
    }

    /// Step forward again. `nil` when nothing was undone.
    public mutating func redo() -> Snapshot? {
        guard var next = future.popLast() else { return nil }
        past.append(present)
        next.key = nil
        present = next
        return present.snapshot
    }

    // MARK: - Bounds

    private mutating func push(_ entry: Entry) {
        past.append(present)
        present = entry
        if past.count > maxDepth {
            past.removeFirst(past.count - maxDepth)
            releaseUnreferencedScenes()
        }
    }

    private mutating func cutRedoBranch() {
        guard !future.isEmpty else { return }
        future.removeAll()
        releaseUnreferencedScenes()
    }

    /// Drop scenes no entry can reach any more.
    private mutating func releaseUnreferencedScenes() {
        var referenced = Set<Int>()
        for entry in past { entry.snapshot.sceneToken.map { referenced.insert($0) } }
        present.snapshot.sceneToken.map { referenced.insert($0) }
        for entry in future { entry.snapshot.sceneToken.map { referenced.insert($0) } }
        scenes = scenes.filter { referenced.contains($0.key) }
    }

    /// Keep only the newest `maxScenes` scenes. Tokens are monotonic, so the
    /// smallest tokens are the oldest maps.
    private mutating func evictScenesBeyondCap() {
        guard scenes.count > maxScenes else { return }
        for token in scenes.keys.sorted().dropLast(maxScenes) {
            scenes.removeValue(forKey: token)
        }
    }
}
