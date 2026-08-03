import Foundation

/// The name under Application Support and Caches that a launch owns.
///
/// **This is here rather than in the app target so it can be tested.** Every
/// store already took a `subdirectory:` and every call site passed the default,
/// which meant a UI test run — a second copy of the application — wrote its
/// session over the real one. Pointing the tests somewhere else fixes that, and
/// the flag that does it is the kind of thing worth checking rather than
/// trusting: it names a directory, and a directory name that can contain `..`
/// is a way to write outside the container.
public enum StateDirectoryName {

    public static let flag = "--state-directory"
    public static let `default` = "Hipparchus"

    /// The directory named by `--state-directory`, or the default.
    ///
    /// Anything suspicious falls back rather than throwing. A launch flag is
    /// setup, not an action: refusing to start because one was malformed would
    /// turn a typo into a broken application, and the fallback is the state the
    /// user already had.
    public static func resolve(from arguments: [String]) -> String {
        guard let flagIndex = arguments.firstIndex(of: flag),
              flagIndex + 1 < arguments.count
        else {
            return `default`
        }
        let requested = arguments[flagIndex + 1].trimmingCharacters(in: .whitespaces)

        // A separator would let the flag write anywhere on disk; an empty name
        // would mean Application Support *itself*, which holds every other
        // application's data. `..` is the same problem spelled differently, and
        // a leading dot only ever hides the directory from the person who would
        // otherwise notice it.
        guard !requested.isEmpty,
              !requested.contains("/"),
              !requested.contains("\\"),
              !requested.contains(".."),
              !requested.hasPrefix("."),
              !requested.contains("\0")
        else {
            return `default`
        }
        return requested
    }

    /// Whether a resolved name is somewhere other than the real state.
    public static func isIsolated(_ name: String) -> Bool { name != `default` }
}
