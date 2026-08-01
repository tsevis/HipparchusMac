import AppKit

/// What the Locator is actually receiving, said out loud.
///
/// This exists because of a specific, repeated failure: the map works with a
/// mouse and not with a pen, and from outside the app "the click was never
/// delivered", "the click was delivered and discarded as a drag" and "the
/// click was handled but landed nowhere" are indistinguishable — they all look
/// like nothing happening. Guessing between them costs a build, an install and
/// somebody's patience each time.
///
/// So the window says which. Presses counted as they arrive at the app, and
/// selections counted as they are made, are enough to tell the three apart at
/// a glance: presses but no selections is a recognition problem, no presses at
/// all is a delivery problem, and both climbing is a map that is working.
@MainActor
@Observable
final class PenTrace {
    /// Raw presses and releases the app received inside the map, counted
    /// before anything has had a chance to interpret them.
    private(set) var pressesSeen = 0
    /// Places actually chosen, by whichever route got there first.
    private(set) var selectionsMade = 0
    /// How the last selection arrived, which is the thing worth knowing when
    /// one route works and the other does not.
    private(set) var lastRoute = "—"
    /// The last press, in the map's own coordinates.
    private(set) var lastPress: CGPoint?

    func notePress(at point: CGPoint) {
        pressesSeen += 1
        lastPress = point
    }

    func noteSelection(via route: String) {
        selectionsMade += 1
        lastRoute = route
    }

    /// Short enough to sit in the corner of the readout and still be read.
    var summary: String {
        let where_ = lastPress.map { String(format: " @%.0f,%.0f", $0.x, $0.y) } ?? ""
        return "presses \(pressesSeen)\(where_) · chosen \(selectionsMade) · via \(lastRoute)"
    }
}
