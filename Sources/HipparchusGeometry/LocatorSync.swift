/// Whether a locator that starts at world scale should follow a newly-seen
/// area, or hold still.
///
/// A saved session's area loads after the window first appears — restoring
/// *what* to look for is not restoring *where the locator points*, so the
/// area that arrives from that late load must not be treated as a live
/// change any more than the default it briefly replaced was. `wasSettled`
/// says whether launch setup (a restored session, a `--bbox` override) had
/// already finished the *last* time a bbox was seen; only once that is true
/// twice in a row — this call and the one before it — is a change real.
public enum LocatorSync {
    public struct Decision: Equatable {
        public let shouldSync: Bool
        public let newLastKnown: BoundingBox

        public init(shouldSync: Bool, newLastKnown: BoundingBox) {
            self.shouldSync = shouldSync
            self.newLastKnown = newLastKnown
        }
    }

    public static func decide(
        bbox: BoundingBox, wasSettled: Bool, lastKnown: BoundingBox?
    ) -> Decision {
        guard wasSettled, let lastKnown, lastKnown != bbox else {
            return Decision(shouldSync: false, newLastKnown: bbox)
        }
        return Decision(shouldSync: true, newLastKnown: bbox)
    }
}
