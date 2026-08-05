import AppKit
import HipparchusData
import HipparchusGeometry
import HipparchusRender
import SwiftUI

/// The three-column interface from the design.
///
/// One spine: **Sources, then Layers, then Style.** Nothing is exclusive, everything
/// stacks, and the map is the product — so the map gets the room and everything else
/// is a narrow column beside it.
struct ContentView: View {
    /// Handed in by the app, not made here: Settings is a second scene and
    /// needs the same model.
    @Bindable var model: MapModel
    /// The menu bar's way in. Filled in below as the window appears.
    let actions: AppActions
    /// The splash, owned by the app because it outlives any window.
    ///
    /// **Handed in rather than shown by the app**, because *when* it appears has
    /// to be ordered against this view's own wiring — see `openOnLaunch()`.
    let about: AboutWindowController
    @State private var viewport = ViewportState()
    /// A handle onto the live canvas, so Render map can ask what is actually
    /// on screen — turning the view is deliberately kept out of the requested
    /// area, so without this, zooming out and pressing Render map re-fetches
    /// the same old bbox while the screen still shows the wider one.
    @State private var canvasHandle = MapCanvasHandle()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var locatorPanel = LocatorPanelController()
    /// The window's own undo manager, which puts ⌘Z and the Edit menu in charge
    /// of the model's history rather than inventing a parallel mechanism.
    @Environment(\.undoManager) private var undoManager
    /// Raised by ⌘F, so Search for a Place has somewhere to land.
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        // The status bar is a sibling of the split view rather than a
        // `safeAreaInset` on it: it spans all three columns, so it is a row of the
        // window rather than an inset of the split view, and a VStack says that
        // directly.
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                FramePanel(model: model, openLocator: { locatorPanel.show(model: model, onRender: renderChosenArea) })
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
                    .accessibilityIdentifier(UITestID.framePanel)
            } content: {
                map
                    .navigationSplitViewColumnWidth(min: 420, ideal: 720)
                    .accessibilityIdentifier(UITestID.mapColumn)
            } detail: {
                List {
                    SourcesPanel(model: model)
                    LayersPanel(model: model)
                    StylePicker(model: model)
                    CompositionPanel(model: model)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .accessibilityIdentifier(UITestID.inspector)
            }
            // A real title, drawn. An *empty* title once hid it from the
            // toolbar, between the search field and the area — the app's name
            // is in the menu bar and on the Dock icon, so a third place felt
            // like one too many. But an empty title is also what the Window
            // menu and Mission Control read, and a blank entry there reads as
            // a bug rather than as restraint.
            //
            // Hiding only the *drawn* text without clearing the title itself
            // needs `NSWindow.titleVisibility`, reached through the map's own
            // view the way `LocatorPanel` already reaches the window — tried
            // once (`203e4a0`) and once more after that (`bcfa95c`), and both
            // times it raced the Locator panel's own launch-time ordering.
            // `titleVisibility` relays out the window, and that relayout goes
            // through the window server asynchronously — outside the app's own
            // run loop, so nothing this process can schedule sequences against
            // it reliably. `bcfa95c` cut the failure rate with a dispatched
            // update and looked fixed at 8 clean runs; asked to verify again
            // before a release, five of the next six failed, one of them
            // losing the main window entirely. Not a fluke either time — a
            // real race neither fix reached the true cause of.
            //
            // So the toolbar shows the name again. A real, visible title and
            // a working Window menu, at the cost of the word "Hipparchus"
            // sitting where the toolbar's controls live — a smaller price than
            // a launch that sometimes drops a window.
            .navigationTitle("Hipparchus")
            .toolbar { toolbar }

            statusBar
        }
        .frame(minWidth: 960, minHeight: 620)
        .task {
            model.undoManager = undoManager
            wireUpMenuCommands()
            model.startIfRequestedOnLaunch()
            openOnLaunch()
        }
        .onAppear { model.undoManager = undoManager }
        .onDisappear { model.save() }
        .alert(
            "This will take a while",
            isPresented: Binding(
                get: { model.pendingWarning != nil },
                set: { if !$0 { model.pendingWarning = nil } }
            )
        ) {
            Button("Fetch anyway") { model.fetch() }
            Button("Cancel", role: .cancel) { model.pendingWarning = nil }
        } message: {
            Text(model.pendingWarning ?? "")
        }
    }

    // MARK: - The map

    private var map: some View {
        ZStack(alignment: .topTrailing) {
            MapCanvas(
                scene: model.visibleScene,
                viewport: viewport,
                onViewportChange: { viewport = $0 },
                onAreaDrawn: { model.setArea($0) },
                handle: canvasHandle
            )

            zoomControls
                .padding(10)

            VStack {
                Spacer()
                // Direct manipulation needs saying once. It is a pill rather than a
                // panel because it should read as a caption on the map, not as
                // another piece of interface competing with it.
                Text("drag to pan · scroll to zoom · Option-drag for a new area · arrows, + − 0 [ ]")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(.bottom, 14)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        // The canvas takes the keyboard too, matching the floating Locator.
        // A `MapCanvasView` is a plain `NSView` inside an
        // `NSViewRepresentable`, so the surrounding view holds the focus and
        // translates the presses.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleCanvasKey(press) }
        // `NavigationSplitView` does not stretch a content column's view to
        // fill it the way a plain `VStack` would — `.navigationSplitViewColumnWidth`
        // (below, where this is placed) sets the column's allowed *range*, not
        // whether what sits inside stretches to fill it. Without this,
        // `MapCanvasView` — a plain `NSView` with no `intrinsicContentSize` —
        // can resolve to a size smaller than the pane, leaving the map
        // floating in a corner of a mostly empty column rather than filling it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Arrow keys to move, `+`/`-` to zoom, `0` to fit, `[`/`]` to turn.
    ///
    /// The same set the Locator takes, so the two maps answer to the same
    /// keys. Panning is a fraction of the view rather than a fixed number of
    /// points, which keeps the step useful whether the map is a street or a
    /// coastline.
    private func handleCanvasKey(_ press: KeyPress) -> KeyPress.Result {
        // Shift moves three times as far — the difference between nudging a
        // label into view and crossing the frame.
        let step = (press.modifiers.contains(.shift) ? 3.0 : 1.0) * 60
        switch press.key {
        case .leftArrow: viewport = viewport.panned(dx: step, dy: 0)
        case .rightArrow: viewport = viewport.panned(dx: -step, dy: 0)
        case .upArrow: viewport = viewport.panned(dx: 0, dy: step)
        case .downArrow: viewport = viewport.panned(dx: 0, dy: -step)
        default:
            switch press.characters.lowercased() {
            case "+", "=": viewport = viewport.zoomed(by: 1.3)
            case "-", "_": viewport = viewport.zoomed(by: 1 / 1.3)
            case "0": viewport = ViewportState()
            case "[": viewport = viewport.rotated(by: -15)
            case "]": viewport = viewport.rotated(by: 15)
            default: return .ignored
            }
        }
        return .handled
    }

    /// Hand the menu bar the window's verbs.
    ///
    /// Done once as the window appears. Each closure captures this view's
    /// state boxes, which are stable across redraws, so the menu keeps working
    /// without being rewired on every update.
    /// What opens by itself when the window appears: the splash, then the
    /// Locator behind it.
    ///
    /// **This used to live on a second `.task`, attached to this view by the
    /// app, and the two raced.** That one called `actions.openLocator`, which
    /// *this* view's task assigns — and SwiftUI does not specify which of two
    /// `.task` modifiers runs first. When the app's won, `openLocator` was still
    /// nil, the call did nothing, and the Locator never appeared. Two identical
    /// launches produced two different windows.
    ///
    /// The splash hid it in ordinary use by giving the wiring time to land, so
    /// it only showed when "Show About on launch" was off — which is how the
    /// layout tests launch, and how they found it.
    ///
    /// The fix is not a delay or a guess about ordering: it is putting the
    /// sequence in **one** task, after the wiring, where the order is program
    /// order. It calls the panel directly rather than through `AppActions` for
    /// the same reason — `AppActions` exists because the menu bar outlives the
    /// view tree, and reaching back through it from inside the view that fills
    /// it in was the indirection that allowed the race.
    private func openOnLaunch() {
        // `--locator` opens the floating Locator straight away, without anyone
        // having to find the toolbar button first. A toolbar's trailing items
        // are the first thing macOS folds away into an overflow menu when a
        // window is narrow, so "the button is not there" and "the window does
        // not work" look identical from the outside — this tells them apart.
        if ProcessInfo.processInfo.arguments.contains("--locator") {
            locatorPanel.show(model: model, onRender: renderChosenArea)
            return
        }
        // The splash first, then the Locator behind it — the Locator floats, so
        // opening both at once would bury the splash under it. With the splash
        // turned off the completion runs immediately, which is the case that
        // used to be a coin toss.
        about.showOnLaunchIfWanted {
            locatorPanel.show(model: model, onRender: renderChosenArea)
        }
    }

    private func wireUpMenuCommands() {
        actions.renderMap = { renderMap() }
        actions.openLocator = { locatorPanel.show(model: model, onRender: renderChosenArea) }
        actions.focusSearch = { isSearchFocused = true }
        actions.zoomIn = { viewport = viewport.zoomed(by: 1.3) }
        actions.zoomOut = { viewport = viewport.zoomed(by: 1 / 1.3) }
        actions.fitToWindow = { viewport = ViewportState() }
        actions.rotateLeft = { viewport = viewport.rotated(by: -15) }
        actions.rotateRight = { viewport = viewport.rotated(by: 15) }
    }

    /// Render exactly the area the model holds, without consulting the canvas.
    ///
    /// What the floating Locator's own button calls. That window shows an area
    /// and keeps `model.bbox` equal to it, so there is nothing to reconcile —
    /// reading the main canvas here instead would draw whatever *it* was
    /// showing, which is a different place.
    private func renderChosenArea() {
        viewport = ViewportState()
        model.shapeAreaToWindow(aspect: canvasHandle.canvasAspect())
        model.update()
    }

    /// What Render map does, in one place.
    ///
    /// The toolbar button and the button on the floating Locator both call
    /// this rather than each doing it themselves: they are the same action,
    /// and two copies of it would be two behaviours within a release or two.
    private func renderMap() {
        // Fetch what is actually on screen, not whatever was last typed —
        // turning the view (pan, zoom, rotation) stays out of the requested
        // area everywhere else, but pressing this button is asking the app to
        // act on what it is showing.
        if let visible = canvasHandle.visibleArea() {
            model.syncAreaToVisibleView(visible)
            viewport = ViewportState()
        }
        // Then shape it to the window — always, whatever the area came from
        // and whether or not anything is drawn yet. It only ever grows the
        // area, and an area already the right shape comes back untouched.
        model.shapeAreaToWindow(aspect: canvasHandle.canvasAspect())
        model.update()
    }

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { viewport = viewport.zoomed(by: 1.3) } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            Divider().frame(width: 22)
            Button { viewport = viewport.zoomed(by: 1 / 1.3) } label: {
                Image(systemName: "minus").frame(width: 22, height: 22)
            }
            Divider().frame(width: 22)
            Button { viewport = viewport.rotated(by: -15) } label: {
                Image(systemName: "rotate.left").frame(width: 22, height: 22)
            }
            .help("Turn the view anticlockwise")
            Button { viewport = viewport.rotated(by: 15) } label: {
                Image(systemName: "rotate.right").frame(width: 22, height: 22)
            }
            .help("Turn the view clockwise")

            // The bearing, and the way back to it. Shown only when the view is
            // turned, because a row reading 0° every other minute is furniture.
            if viewport.rotation != 0 {
                Button { viewport = viewport.rotated(to: 0) } label: {
                    Text("\(Int(viewport.rotation.rounded()))°")
                        .font(.caption2)
                        .monospacedDigit()
                        .frame(width: 22, height: 18)
                }
                .help("Back to north up")
            }

            Divider().frame(width: 22)
            Button { viewport = ViewportState() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .frame(width: 22, height: 22)
            }
            // Fit undoes the turn as well as the zoom: one control meaning
            // "show me the whole thing, the right way up".
            .help("Fit the map to the window, north up")
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            PlaceSearchField(model: model, isFocused: $isSearchFocused)
        }

        ToolbarItem(placement: .principal) {
            // Cancel appears beside Render map while a fetch runs — where the eye
            // already is — as well as in the status bar next to the progress.
            HStack(spacing: 8) {
                // The one button the whole window exists to have pressed, so it
                // is the one thing wearing the app's own turquoise. Everything
                // else in the toolbar is grey on purpose: an accent used twice
                // is an accent used nowhere.
                Button("Render map") { renderMap() }
                .buttonStyle(RenderButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.whyCannotRender != nil)
                // The reason is on the button that will not work, so hovering
                // it answers the question instead of a click having to.
                .help(model.whyCannotRender ?? "Fetch and draw the chosen area.")
                .accessibilityIdentifier(UITestID.renderButton)
                if model.isFetching {
                    Button("Cancel") { model.cancel() }
                        .help("Skips sources not yet started and discards the result. A request already in flight runs to completion.")
                        .accessibilityIdentifier(UITestID.cancelButton)
                }
            }
        }

        ToolbarItem(placement: .principal) {
            Text(model.areaDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier(UITestID.areaDescription)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                locatorPanel.show(model: model, onRender: renderChosenArea)
            } label: {
                Image(systemName: "map")
            }
            .help("Open the Locator in its own floating window")
            .accessibilityIdentifier(UITestID.locatorButton)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu("Export") {
                Button("SVG…") { model.exportSVG() }
                Button("PDF…") { model.exportPDF() }
                Button("PNG…") { model.exportPNG() }
                Divider()
                Button("Clear cache") { model.clearCache() }
            }
            .disabled(model.scene == nil)
            .accessibilityIdentifier(UITestID.exportMenu)
        }
    }

    // MARK: - Status

    /// Progress is per source, with a way out.
    ///
    /// A fetch can take five minutes — Overpass is usually all of it — while a
    /// single status line says "Idle". Showing each source with its own elapsed time
    /// makes the slow one obvious, and Cancel means a mistyped area is not a
    /// five-minute wait.
    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                MakersMark()

                if model.isFetching {
                    ProgressView().controlSize(.small)
                }

                if model.progress.sources.isEmpty {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(model.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                } else {
                    ForEach(model.progress.sources) { source in
                        SourceProgressRow(source: source)
                    }
                    if !model.isFetching {
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(model.isError ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                if model.isFetching {
                    Button("Cancel") { model.cancel() }
                        .controlSize(.small)
                }

                if let provenance = model.provenance {
                    // Provenance is on screen for the same reason it is in the file:
                    // a generated map must not be mistakable for a survey.
                    Text(provenance)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                if !model.cacheSummary.isEmpty {
                    Text(model.cacheSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.bar)
        .accessibilityIdentifier(UITestID.statusBar)
    }
}

private struct SourceProgressRow: View {
    let source: SourceProgress

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(Self.label(for: source.sourceID))
                .font(.caption)
            if source.state == .done, !source.detail.isEmpty {
                Text(source.detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .help(source.summary())
    }

    /// The sidebar's own name for a source, so the status bar and the sources
    /// stack call the same thing by the same name.
    static func label(for sourceID: String) -> String {
        SourceStack.defaultDefinitions.first { $0.id == sourceID }?.label ?? sourceID
    }

    @ViewBuilder
    private var icon: some View {
        switch source.state {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.tertiary)
        }
    }
}


/// Whose app this is, in the corner.
///
/// A vector PDF rather than a bitmap, cropped to the artwork rather than to
/// the Illustrator canvas it was drawn on — the canvas is four times the area
/// of the mark, so framing the uncropped file sized the empty space and left
/// the logo a third of the height it should have been.
private struct MakersMark: View {
    @Environment(\.openURL) private var openURL

    /// Two points taller than the source ticks beside it.
    ///
    /// Measured rather than guessed: the ticks are `checkmark.circle.fill` at
    /// the system font size, and an SF Symbol's rendered height is not its
    /// point size. Asking AppKit for the real one means this stays right if
    /// the status bar's type ever changes.
    private static let height: CGFloat = {
        let symbol = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        let configured = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        )
        return (configured?.size.height ?? 16) + 2
    }()

    var body: some View {
        Button {
            openURL(URL(string: "https://tsevis.com")!)
        } label: {
            Image("TVDLogo")
                .resizable()
                .scaledToFit()
                .frame(height: Self.height)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("tsevis.com")
        .accessibilityLabel("Charis Tsevis — tsevis.com")
    }
}
