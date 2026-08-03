import Foundation
import HipparchusData

/// Where this launch keeps its session, preferences, saved styles and cache.
///
/// **This exists so a UI test cannot destroy the user's work.** Every store here
/// already took a `subdirectory:` and every call site passed the default, so a
/// second copy of the application — which is what an XCUITest run is — wrote its
/// session over the real one. A test that opens a window, ticks a source and
/// quits would have left the user's saved area, style and layer choices replaced
/// by whatever the test happened to do.
///
/// So the name is a launch argument. It defaults to `Hipparchus` and nothing but
/// a deliberate flag changes it, which means the normal path is exactly what it
/// was. The parsing lives in `StateDirectoryName`, in the package, where it can
/// be tested — this is only the reading of the arguments.
enum StateDirectory {

    /// Resolved once. Reading `ProcessInfo` repeatedly would let two stores
    /// disagree if anything ever mutated the arguments, and a session written to
    /// one directory while preferences were read from another is the kind of
    /// fault that looks like data loss.
    static let name = StateDirectoryName.resolve(from: ProcessInfo.processInfo.arguments)

    /// Whether this launch is running against somewhere other than the real
    /// state, which is worth being able to assert in a test.
    static var isIsolated: Bool { StateDirectoryName.isIsolated(name) }
}
