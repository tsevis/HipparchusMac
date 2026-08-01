import AppKit

/// Permission to read a file, kept between launches.
///
/// The app is sandboxed. Choosing a file in an open panel grants access to
/// that file — but only to *this run* of the app. The path saved in the
/// session is just text, and on the next launch opening it fails with a
/// permission error that surfaces as a fetch failure, which reads as "the
/// file-backed sources are broken" rather than "the app was never given
/// permission again".
///
/// A security-scoped bookmark is what macOS provides instead: a token minted
/// while access is held, stored alongside the path, and redeemed on a later
/// launch for the same access. It needs the
/// `com.apple.security.files.user-selected.read-write` entitlement, which this
/// app already has for the save panel.
enum SecurityScopedAccess {

    /// Mint a token for a file the user has just chosen.
    ///
    /// `nil` when the system declines — an unsandboxed debug run, a volume
    /// that cannot represent one. The path still works for this session, so a
    /// missing bookmark degrades to the old behaviour rather than failing.
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Redeem a token and begin access, returning where it points.
    ///
    /// Access is begun and deliberately never balanced with a matching stop:
    /// the file is in use for as long as its source is ticked, which is as
    /// long as the app runs. Stopping when this returns would hand back the
    /// very permission it was called to obtain.
    ///
    /// A stale bookmark — the file moved or was renamed — still resolves, and
    /// says so, which is worth passing on: the app can then read it *and*
    /// mint a fresh token for next time.
    static func resolve(_ bookmark: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else {
            // Resolvable but not openable: the volume is not mounted, or the
            // token has been revoked. The caller reports it rather than
            // failing silently at fetch time.
            return nil
        }
        return (url, isStale)
    }
}
