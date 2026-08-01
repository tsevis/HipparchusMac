import AppKit
import SwiftUI

/// The one colour the application draws itself with.
///
/// SwiftUI picks the accent up from the asset catalogue on its own — that is
/// what `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` is for, and it is why
/// `.tint` and `Color.accentColor` need nothing here. AppKit does not:
/// `NSColor.controlAccentColor` is the *system's* accent, chosen in System
/// Settings, so a selection rectangle drawn with it turned blue or pink or
/// graphite depending on what the person had picked for the Finder — while the
/// rest of the interface stayed turquoise.
///
/// Everything drawn by hand — the area rectangle on the canvas, the locator's
/// frame, the rubber band — comes through here instead.
extension NSColor {
    /// Turquoise, and the same turquoise as the app icon. Reads from the asset
    /// catalogue so it follows light and dark automatically, and falls back to
    /// the system accent only if the asset has somehow gone missing.
    static let hipparchus = NSColor(named: "AccentColor") ?? .controlAccentColor
}

extension Color {
    static let hipparchus = Color(nsColor: .hipparchus)
}
