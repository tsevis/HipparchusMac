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

    // MARK: - The lockup

    private static let titleSize: CGFloat = 36
    private static let subtitleSize: CGFloat = 13

    /// Cap height of the title down to the baseline of the subtitle.
    ///
    /// The mark should read as the same object as the words beside it, which
    /// means matching the block the type actually occupies — not the line
    /// box, which hangs empty space above the capitals and below the last
    /// baseline. Measured from the fonts rather than guessed, so it stays
    /// right if either size changes: 36pt/13pt system currently gives ~48pt,
    /// against the 34pt that was there before.
    private static let logoHeight: CGFloat = {
        let title = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        let subtitle = NSFont.systemFont(ofSize: subtitleSize)

        // A line box places the baseline `ascender` below its top, so the
        // capitals begin `ascender - capHeight` down from it.
        let titleCapInset = title.ascender - title.capHeight
        let titleLine = title.ascender - title.descender
        let subtitleBaseline = titleLine + subtitle.ascender

        return subtitleBaseline - titleCapInset
    }()

    var body: some View {
        VStack(spacing: 0) {
            keyArt
            body(of: Self.about)
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 640, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The island, full bleed

    /// Key art across the top with the name over it, rather than an icon
    /// centred above a paragraph. The map is the product, so it goes first and
    /// at full width; the type sits in it rather than beside it.
    private var keyArt: some View {
        ZStack(alignment: .bottomLeading) {
            Image("CyprusAbout")
                .resizable()
                .scaledToFill()
                .frame(height: 250)
                .clipped()

            // A short scrim, so white type stays legible over the palest part
            // of the sea without dimming the whole image.
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.30)],
                startPoint: .center, endPoint: .bottom
            )
            .frame(height: 250)

            // `.lastTextBaseline` puts the mark's bottom edge on the
            // subtitle's baseline — a view with no text of its own reports
            // its bottom for that guide — so the logo occupies exactly the
            // block the two lines of type describe, rather than a height
            // picked by eye.
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Image("TVDLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(height: Self.logoHeight)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Hipparchus")
                        .font(.system(size: Self.titleSize, weight: .semibold))
                        .tracking(-0.6)
                    Text("Maps built from sources that stack")
                        .font(.system(size: Self.subtitleSize, weight: .regular))
                        .opacity(0.85)
                }
                Spacer()
                Text(Self.version)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
            .padding(.horizontal, 26)
            .padding(.bottom, 20)
        }
        .frame(height: 250)
    }

    // MARK: - The words

    private func body(of text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            DisclosureGroup {
                Text(Self.legal)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text("Data, licences and credits")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 14)

            Divider()

            HStack(spacing: 14) {
                Text("Created by Charis Tsevis, with the help of Claude Code.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                link("tsevis.com", "https://tsevis.com")
                link("github.com/tsevis", "https://github.com/tsevis")

                Spacer()

                Button("Continue", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }

    private func link(_ label: String, _ address: String) -> some View {
        Button(label) {
            guard let url = URL(string: address) else { return }
            openURL(url)
        }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .pointerStyle(.link)
    }

    // MARK: - The text

    private static let about = """
    Hipparchus of Nicaea worked out how to put a grid on the world. Around \
    130 BC he fixed places by latitude and longitude, built the first star \
    catalogue, and argued that maps should be drawn from measurement rather \
    than from travellers' impressions — an argument that took seventeen \
    centuries to win.

    This is a small tribute to that idea. Elevation from terrain tiles, \
    coastline and streets from OpenStreetMap, seismicity from the USGS. \
    Sources stack rather than replace, nothing is invented without saying so, \
    and every layer carries its provenance into the exported file — because a \
    generated map must never be mistaken for a survey.
    """

    private static let legal = """
    Map data © OpenStreetMap contributors, under the Open Database License \
    (ODbL). Elevation from Mapzen/AWS Terrain Tiles. Bathymetry in European \
    seas from EMODnet Bathymetry (emodnet-bathymetry.eu). Imagery from NASA \
    GIBS. Earthquakes from the U.S. Geological Survey. Satellite elements from \
    CelesTrak. Geocoding by Nominatim and Apple MapKit; Locator basemap © \
    Apple. Rendered with GEOS.

    Maps you make are yours. The attributions above travel with anything you \
    publish from them.
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

    /// Show the splash if it is wanted, and run `then` once it is out of the
    /// way — immediately if it was never shown.
    ///
    /// The ordering matters: the Locator is a `.floating` panel, so opening it
    /// alongside the splash would put it *over* the thing the splash is for.
    func showOnLaunchIfWanted(then next: @escaping () -> Void) {
        let defaults = UserDefaults.standard
        // Absent means yes — the first launch is exactly when the attribution
        // and the credits are worth reading.
        if defaults.object(forKey: Self.showOnLaunchKey) == nil {
            defaults.set(true, forKey: Self.showOnLaunchKey)
        }
        guard defaults.bool(forKey: Self.showOnLaunchKey) else {
            next()
            return
        }
        onDismiss = next
        show()
    }

    /// Run when the splash goes away, whether by the button or the close box.
    private var onDismiss: (() -> Void)?

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
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: AboutView(close: { [weak self] in self?.window?.close() })
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

extension AboutWindowController: NSWindowDelegate {
    /// Whatever was waiting on the splash runs when it closes — by the
    /// Continue button or by the close box, which have to mean the same thing.
    func windowWillClose(_ notification: Notification) {
        let next = onDismiss
        onDismiss = nil
        next?()
    }
}
