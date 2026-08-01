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
                FramePanel(model: model, openLocator: { locatorPanel.show(model: model, onRender: renderMap) })
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } content: {
                map
                    .navigationSplitViewColumnWidth(min: 420, ideal: 720)
            } detail: {
                List {
                    SourcesPanel(model: model)
                    LayersPanel(model: model)
                    StylePicker(model: model)
                    CompositionPanel(model: model)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            }
            .navigationTitle("Hipparchus")
            .toolbar { toolbar }

            statusBar
        }
        .frame(minWidth: 960, minHeight: 620)
        .task {
            model.undoManager = undoManager
            wireUpMenuCommands()
            model.startIfRequestedOnLaunch()
            // `--locator` opens the floating Locator straight away, without
            // anyone having to find the toolbar button first. A toolbar's
            // trailing items are the first thing macOS folds away into an
            // overflow menu when a window is narrow, so "the button is not
            // there" and "the window does not work" look identical from the
            // outside — this tells them apart.
            if ProcessInfo.processInfo.arguments.contains("--locator") {
                locatorPanel.show(model: model, onRender: renderMap)
            }
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
    private func wireUpMenuCommands() {
        actions.renderMap = { renderMap() }
        actions.openLocator = { locatorPanel.show(model: model, onRender: renderMap) }
        actions.focusSearch = { isSearchFocused = true }
        actions.zoomIn = { viewport = viewport.zoomed(by: 1.3) }
        actions.zoomOut = { viewport = viewport.zoomed(by: 1 / 1.3) }
        actions.fitToWindow = { viewport = ViewportState() }
        actions.rotateLeft = { viewport = viewport.rotated(by: -15) }
        actions.rotateRight = { viewport = viewport.rotated(by: 15) }
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
                Button("Render map") { renderMap() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.whyCannotRender != nil)
                // The reason is on the button that will not work, so hovering
                // it answers the question instead of a click having to.
                .help(model.whyCannotRender ?? "Fetch and draw the chosen area.")
                if model.isFetching {
                    Button("Cancel") { model.cancel() }
                        .help("Skips sources not yet started and discards the result. A request already in flight runs to completion.")
                }
            }
        }

        ToolbarItem(placement: .principal) {
            Text(model.areaDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                locatorPanel.show(model: model, onRender: renderMap)
            } label: {
                Image(systemName: "map")
            }
            .help("Open the Locator in its own floating window")
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
