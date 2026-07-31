import AppKit
import SwiftUI

/// The Locator, undocked: a real floating panel rather than a sidebar row.
///
/// A `List` row was never a safe home for this — see `FramePanel`'s own note
/// on why — but even a plain sibling view still lives inside the one window
/// the whole rest of the interface competes for space in. A separate panel
/// gives the map a window of its own, and `.floating` keeps it visible over
/// the main window rather than getting buried behind it the way an ordinary
/// document window would.
@MainActor
final class LocatorPanelController: NSObject {
    private var panel: NSPanel?

    /// Shows the panel, creating it once and reusing it after — so a second
    /// click brings the same window forward rather than spawning another.
    func show(model: MapModel) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Locator"
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        // Kept alive when closed, same as the map window: closing hides it,
        // it does not need rebuilding — including the `MKMapView` inside,
        // which would otherwise lose its region and start over at the whole
        // world every time.
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: LocatorPanelContent(model: model))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }
}

/// The panel's content: the same `Locator` the sidebar shows, with room to
/// breathe now that it owns the whole window rather than a corner of one.
private struct LocatorPanelContent: View {
    @Bindable var model: MapModel

    var body: some View {
        Locator(bbox: model.bbox, onRegionChanged: { model.browseWorldMap(to: $0) })
            .padding(8)
    }
}
