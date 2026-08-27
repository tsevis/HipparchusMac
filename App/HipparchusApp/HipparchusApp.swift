import SwiftUI

@main
struct HipparchusApp: App {
    /// Owned here rather than by `ContentView` because Settings is a second
    /// scene and has to see the same model — a preferences window editing a
    /// different copy of the settings than the one the app is using would be
    /// worse than having no preferences window at all.
    @State private var model = MapModel()
    /// What the menu items act on. The menu bar exists before any window does,
    /// so the commands cannot reach into the view tree; the window fills these
    /// in as it appears.
    @State private var actions = AppActions()
    /// Shown once at launch, and again from About Hipparchus. It carries the
    /// OpenStreetMap attribution, which has to live somewhere findable.
    @State private var about = AboutWindowController()

    var body: some Scene {
        // What opens at launch is `ContentView.openOnLaunch()`, deliberately.
        //
        // The splash used to be shown from a `.task` here, calling
        // `actions.openLocator` — which the view's *own* task assigns. SwiftUI
        // does not specify which of two `.task` modifiers runs first, so whether
        // the Locator appeared was a coin toss. Ordering it against the wiring
        // means being in the same task as the wiring.
        Window("Hipparchus", id: "map") {
            ContentView(model: model, actions: actions, about: about)
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            // No New: there is one window and one map, and a New that does
            // nothing is a menu item that teaches distrust.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Hipparchus") { about.show() }
            }
            mapCommands
            viewCommands
        }

        Settings {
            SettingsView(model: model)
        }
    }

    /// The verbs, gathered under one menu so the shortcuts are discoverable
    /// rather than folklore. Every one of them is a control that already
    /// exists on screen: a shortcut for something with no button is a secret.
    @CommandsBuilder
    private var mapCommands: some Commands {
        CommandMenu("Map") {
            Button("Render Map") { actions.renderMap?() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.whyCannotRender != nil)

            Button("Cancel Fetch") { model.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isFetching)

            Divider()

            Button("Open Locator") { actions.openLocator?() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Search for a Place") { actions.focusSearch?() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Paste Coordinates") { model.importCoordinates() }
                .keyboardShortcut("v", modifiers: [.command, .shift])

            Divider()

            Menu("Saved Places") {
                ForEach(Array(model.availablePlaces.enumerated()), id: \.element.id) { index, place in
                    savedPlace(place, at: index)
                }
            }

            Divider()

            Button("Export SVG…") { model.exportSVG() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.scene == nil)
            Button("Export PDF…") { model.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.scene == nil)
            Button("Export PNG…") { model.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.scene == nil)
            // No shortcut: the three obvious ⌘E combinations are taken, and a
            // fourth would be a chord nobody guesses.
            Button("Export GeoJSON…") { model.exportGeoJSON() }
                .disabled(model.scene == nil)
        }
    }

    /// ⌘1…⌘9 for the first nine places, then ⌥⌘1…⌥⌘7 for the rest.
    ///
    /// Sixteen places shipped and nine of them could be reached, which made the
    /// last seven look like a different kind of thing than the first nine. The
    /// obvious tenth key is ⌘0, and it is taken — Fit to Window, where every
    /// Mac application puts it — so the run continues on the option key rather
    /// than stealing a shortcut people already know.
    ///
    /// Bounded at sixteen because that is what the second run of digits holds.
    /// A seventeenth place would be unreachable, and silently so; that is worth
    /// knowing about before it happens.
    @ViewBuilder
    private func savedPlace(_ place: MapModel.Place, at index: Int) -> some View {
        let button = Button(place.name) { model.select(place.name) }
        if index < 9, let key = "\(index + 1)".first {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else if index < 16, let key = "\(index - 8)".first {
            button.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
        } else {
            button
        }
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In") { actions.zoomIn?() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { actions.zoomOut?() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Fit to Window") { actions.fitToWindow?() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Turn Anticlockwise") { actions.rotateLeft?() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Turn Clockwise") { actions.rotateRight?() }
                .keyboardShortcut("]", modifiers: .command)
        }
    }
}

/// The window's verbs, reachable from the menu bar.
///
/// The menu exists before any window does and outlives every redraw of one, so
/// it cannot hold a reference into the view tree. The window fills these in as
/// it appears and the menu calls whatever is there — nothing when there is no
/// window, which is the right answer at that moment.
@MainActor
@Observable
final class AppActions {
    var renderMap: (() -> Void)?
    var openLocator: (() -> Void)?
    var focusSearch: (() -> Void)?
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var fitToWindow: (() -> Void)?
    var rotateLeft: (() -> Void)?
    var rotateRight: (() -> Void)?
}
