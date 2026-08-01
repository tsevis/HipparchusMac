import AppKit

/// A click, as a hand actually performs one.
///
/// `NSClickGestureRecognizer` fails the moment the pointer moves between press
/// and release, and its tolerance for that is essentially nothing. A mouse
/// resting on a desk can meet it. A pen held in the air cannot: a Wacom
/// digitiser reports sub-pixel movement continuously, so every press carries a
/// point or two of tremor with it and every click is thrown away as the start
/// of a drag that never came. The map appears dead to a pen and perfectly fine
/// to a mouse, which is exactly how it was reported.
///
/// So the tolerance is stated here instead of accepted from AppKit. Everything
/// else is left alone: this is a discrete recognizer that fails itself as soon
/// as the movement is real, which is what lets `MKMapView`'s own pan take over
/// without the two having to negotiate.
final class ForgivingClickRecognizer: NSGestureRecognizer {

    /// How far a press may wander and still be a click, in points.
    ///
    /// Eight is comfortably past a pen's tremor and comfortably short of a
    /// deliberate drag — and a pan of less than eight points would have moved
    /// the map by a rounding error anyway, so nothing is lost by reading one
    /// as a click. Touch platforms use a similar figure for the same reason.
    static let slop: CGFloat = 8

    /// Whether a press and a release are one gesture or the two ends of
    /// another. Split out from the event handling because this is the part
    /// with a right answer, and events are the part nothing here can make.
    static func isAClick(from down: CGPoint, to up: CGPoint) -> Bool {
        hypot(up.x - down.x, up.y - down.y) <= slop
    }

    private var pressedAt: CGPoint?
    /// The furthest the pointer has been from where it went down — not merely
    /// where it ended up. A press dragged across the map and brought back is a
    /// drag, however it finishes.
    private var strayed: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        pressedAt = location(in: view)
        strayed = 0
        state = .possible
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let now = location(in: view)
        strayed = max(strayed, hypot(now.x - pressedAt.x, now.y - pressedAt.y))
        // Past the tolerance this is a pan, and saying so promptly is what
        // hands the gesture to the map rather than leaving both waiting.
        if strayed > Self.slop { state = .failed }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard let pressedAt, state != .failed else {
            state = .failed
            return
        }
        let released = location(in: view)
        // Both tests, because they catch different things: `strayed` catches
        // the round trip, `isAClick` catches a release that jumped without
        // any drag being reported in between.
        guard strayed <= Self.slop, Self.isAClick(from: pressedAt, to: released) else {
            state = .failed
            return
        }
        state = .ended
    }

    override func reset() {
        super.reset()
        pressedAt = nil
        strayed = 0
    }
}
