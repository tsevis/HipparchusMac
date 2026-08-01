import SwiftUI

/// What this is, who made it, and what it owes.
///
/// Shown once at launch and reachable afterwards from the application menu. A
/// splash screen is unusual on macOS and this one earns its place by carrying
/// the attribution the map data requires: OpenStreetMap is ODbL, and a map
/// drawn from it has to say so somewhere a person can find.
///
/// The island behind it is Cyprus, drawn by this application from real
/// elevation and coastline data in the Monochrome Figure Ground preset — not a
/// decoration someone drew, but the program's own output, which is the only
/// honest thing to put on the front of it.
struct AboutView: View {
    /// Dismisses the window. Supplied by whatever presented it.
    var close: () -> Void

    @Environment(\.openURL) private var openURL

    private static let version = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The island

    private var backdrop: some View {
        VStack {
            Image("CyprusAbout")
                .resizable()
                .scaledToFit()
                // Behind the words rather than beside them, and faint enough
                // that the words win. It is a backdrop, not an illustration.
                .opacity(0.30)
                .padding(.top, 150)
                .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - The words

    private var content: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image("TVDLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 46)

                Text("Hipparchus")
                    .font(.system(size: 34, weight: .light, design: .serif))
                    .tracking(2)

                Text("Maps built from sources that stack")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Version \(Self.version)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 30)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 12) {
                Text(Self.about)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.legal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 34)

            Spacer(minLength: 12)

            credits
                .padding(.bottom, 22)
        }
    }

    private var credits: some View {
        VStack(spacing: 10) {
            Text("Created by Charis Tsevis, with the help of Claude Code.")
                .font(.callout)
                .foregroundStyle(.primary)

            HStack(spacing: 14) {
                link("tsevis.com", "https://tsevis.com", symbol: "safari")
                link("github.com/tsevis", "https://github.com/tsevis", symbol: "chevron.left.forwardslash.chevron.right")
            }

            Button("Continue", action: close)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .padding(.top, 4)
        }
    }

    private func link(_ label: String, _ address: String, symbol: String) -> some View {
        Button {
            guard let url = URL(string: address) else { return }
            openURL(url)
        } label: {
            Label(label, systemImage: symbol)
                .font(.callout)
        }
        .buttonStyle(.link)
        .pointerStyle(.link)
    }

    // MARK: - The text

    private static let about = """
    Hipparchus of Nicaea worked out how to put a grid on the world. Around \
    130 BC he fixed places by latitude and longitude, built the first star \
    catalogue, and argued that maps should be drawn from measurements rather \
    than from travellers' impressions — an argument that took seventeen \
    centuries to win.

    This is a small tribute to that idea. It draws maps from data that was \
    measured: elevation from terrain tiles, coastline and streets from \
    OpenStreetMap, seismicity from the USGS. Sources stack rather than \
    replace, nothing is invented without saying so, and every layer carries \
    its provenance into the exported file — because a generated map must \
    never be mistaken for a survey.
    """

    private static let legal = """
    Map data © OpenStreetMap contributors, available under the Open Database \
    License (ODbL). Elevation from Mapzen/AWS Terrain Tiles. Imagery from \
    NASA GIBS. Earthquake data from the U.S. Geological Survey. Satellite \
    elements from CelesTrak. Geocoding by Nominatim and Apple MapKit; \
    basemap in the Locator © Apple. Rendered with GEOS.

    Maps produced by this application are yours. The attributions above \
    travel with anything you publish from them.
    """
}

// MARK: - Its window

/// Puts `AboutView` in a window of its own.
///
/// A plain `NSWindow` rather than a SwiftUI scene because it has to be
/// summonable from the application menu *and* shown once at launch, and a
/// `Window` scene gives no clean way to do the second without leaving a stale
/// entry in the Window menu.
@MainActor
final class AboutWindowController: NSObject {
    private var window: NSWindow?

    /// Whether the splash appears at launch. A defaults key rather than a
    /// setting in the Settings window: it is a one-line preference about a
    /// window, not about how maps are made.
    private static let showOnLaunchKey = "ShowAboutOnLaunch"

    func showOnLaunchIfWanted() {
        let defaults = UserDefaults.standard
        // Absent means yes — the first launch is exactly when the attribution
        // and the credits are worth reading.
        if defaults.object(forKey: Self.showOnLaunchKey) == nil {
            defaults.set(true, forKey: Self.showOnLaunchKey)
        }
        guard defaults.bool(forKey: Self.showOnLaunchKey) else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: AboutView(close: { [weak self] in self?.window?.close() })
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
