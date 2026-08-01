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
    /// Every mouse event the monitor was handed, before any test at all.
    ///
    /// Counted because the previous version of this could only say "no
    /// presses", which conflates three different faults: the monitor never
    /// installed, the monitor running but rejecting the events as belonging to
    /// another window, and the events landing outside the map. Each needs a
    /// different fix and they are indistinguishable from one number.
    private(set) var eventsSeen = 0
    /// Those the monitor accepted as belonging to the map's own window.
    private(set) var eventsInWindow = 0
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

    /// What the gesture recognizers are doing, which is the other half of the
    /// picture: the monitor and the recognizers are two independent routes to
    /// the same map, and "nothing happened" has to be attributable to one.
    private(set) var recognizerEvents = 0
    private(set) var lastRecognizer = "—"

    /// Whether the readout is shown. Off unless asked for.
    ///
    /// This existed to find one bug — a pen whose clicks never arrived — and
    /// it found it. What it cost was a line of counters permanently across
    /// the bottom of a window that people are meant to choose places in, and
    /// diagnostics that never leave are how an interface fills with things
    /// nobody reads. The counting stays, because it is free and the next
    /// input bug will want it; only the display is behind the flag:
    ///
    ///     Hipparchus.app/Contents/MacOS/Hipparchus --locator-diagnostics
    static let isShown = ProcessInfo.processInfo.arguments.contains("--locator-diagnostics")

    func noteRecognizer(_ what: String) {
        recognizerEvents += 1
        lastRecognizer = what
    }

    func noteEventSeen() { eventsSeen += 1 }
    func noteEventInWindow() { eventsInWindow += 1 }

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
        // Each number narrows it: no events at all means the monitor is not
        // installed; events but none in the window means the window test is
        // wrong; in the window but not on the map means the coordinates are.
        return "evt \(eventsSeen) · win \(eventsInWindow) · map \(pressesSeen)\(where_)"
            + " · rec \(recognizerEvents) \(lastRecognizer)"
            + " · chosen \(selectionsMade) · via \(lastRoute)"
    }
}
