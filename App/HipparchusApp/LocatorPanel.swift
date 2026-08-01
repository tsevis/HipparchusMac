import AppKit
import HipparchusGeometry
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
    /// Owned here rather than by the content view, because the event monitor
    /// below needs to reach the map too, and it outlives any one SwiftUI update.
    private let handle = LocatorHandle()
    private let trace = PenTrace()
    private let mode = LocatorMode()
    private var monitor: Any?
    /// Pressing Render map here must do exactly what pressing it in the
    /// toolbar does, so it is the same closure rather than a second
    /// implementation that will drift from the first.
    private var onRender: () -> Void = {}
    /// Where the current press went down, in the map's coordinates.
    private var pressedAt: CGPoint?

    // No `deinit` removing the monitor: this controller is held by the one
    // window for as long as the app has one, so the monitor's life is the
    // process's life. A `deinit` cannot reach main-actor state to remove it
    // anyway, and faking that with an unchecked escape would be inventing a
    // concurrency problem to solve a lifetime that does not exist.

    /// Shows the panel, creating it once and reusing it after — so a second
    /// click brings the same window forward rather than spawning another.
    func show(model: MapModel, onRender: @escaping () -> Void = {}) {
        self.onRender = onRender
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            // Bigger than the sidebar on purpose: MapKit has a hard,
            // size-dependent limit on how far out it will zoom — a sidebar-
            // sized view cannot show more than roughly 70° in either
            // direction no matter what is asked for, which reads as an
            // arbitrary patch of a continent rather than "the whole world."
            // A window this size gets close to the full globe instead.
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // The build time used to be here, because "is this even the new app?"
        // has cost more time on this project than any actual bug: several
        // copies can exist at once — an old release in /Applications, a stale
        // one in Xcode's DerivedData — identical from the outside, same name,
        // same icon, same version.
        //
        // It is gone from the title because this window appears in the
        // README's screenshot, and a development aid does not belong in the
        // picture of the finished thing. The check itself is not lost; it
        // never needed the app's help:
        //
        //     stat -f "%Sm" /Applications/Hipparchus.app/Contents/MacOS/Hipparchus
        panel.title = "Locator"
        panel.level = .floating
        panel.minSize = NSSize(width: 420, height: 380)
        panel.isMovableByWindowBackground = false
        // Kept alive when closed, same as the map window: closing hides it,
        // it does not need rebuilding — including the `MKMapView` inside,
        // which would otherwise lose its region and start over at the whole
        // world every time.
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(
            rootView: LocatorPanelContent(
                model: model, handle: handle, trace: trace, mode: mode,
                onRender: { [weak self] in self?.onRender() }
            )
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        watchForPresses(in: panel)
    }

    // MARK: - A second way in for the pen

    /// Catch presses on the map before AppKit decides what they were.
    ///
    /// There is already a gesture recognizer on the map, and for a mouse it is
    /// enough. A pen is a different matter: tablet input reaches an app by a
    /// route with more places to go wrong, and a recognizer that never fires
    /// is indistinguishable from a map that ignores you. A local monitor sits
    /// upstream of all of that — it sees events as the app takes them off its
    /// own queue, before any view or recognizer has had an opinion — so if the
    /// press arrives at the application at all, this sees it.
    ///
    /// The event is returned unchanged, never swallowed, so the map still pans
    /// and zooms exactly as before. Both routes reaching the same click is
    /// harmless: they resolve the same point to the same place and set the
    /// same area twice, which the model coalesces into one.
    private func watchForPresses(in panel: NSPanel) {
        // `.leftMouseDragged` as well as down and up, because this route now
        // carries the whole of drawing an area, not only clicking a place.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak panel] event in
            MainActor.assumeIsolated { self?.note(event, in: panel) }
            return event
        }
    }

    private func note(_ event: NSEvent, in panel: NSPanel?) {
        trace.noteEventSeen()
        guard let map = handle.view else { return }
        // Compared against the *map's* own window rather than the panel.
        //
        // `event.window === panel` was wrong, and wrong in a way that showed
        // as nothing at all happening: an `NSHostingView`'s content does not
        // have to sit directly in the window handed to it, so the window an
        // event names need not be the panel even when the click landed
        // squarely on the map. Asking the map which window it is in cannot
        // disagree with itself.
        guard let mapWindow = map.window, event.window === mapWindow else { return }
        trace.noteEventInWindow()

        let point = map.convert(event.locationInWindow, from: nil)
        // A drag may leave the map on its way; only its start has to be on it.
        guard map.bounds.contains(point) || pressedAt != nil else { return }

        switch event.type {
        case .leftMouseDown:
            guard map.bounds.contains(point) else { return }
            trace.notePress(at: point)
            pressedAt = point
            if mode.isDrawingArea { handle.beginDrawing(at: point) }

        case .leftMouseDragged:
            guard mode.isDrawingArea, let down = pressedAt else { return }
            handle.updateDrawing(from: down, to: point)

        case .leftMouseUp:
            defer { pressedAt = nil }
            guard let down = pressedAt else { return }

            // Drawing an area and choosing a place are the same gesture until
            // the mouse comes up; which one it was is decided here.
            if mode.isDrawingArea {
                handle.finishDrawing(from: down, to: point)
                return
            }
            // The same tolerance the recognizer uses, for the same reason: a
            // hand holding a pen is never perfectly still.
            guard ForgivingClickRecognizer.isAClick(from: down, to: point) else { return }
            handle.selectPoint(at: point)

        default:
            break
        }
    }

}

/// The panel's content: a world map to look at, buttons to get closer with,
/// and a click to choose with.
///
/// The division of labour is the whole design. Dragging and the zoom buttons
/// go *looking* and change nothing but the view; a click *chooses*, and what it
/// chooses is what `Render map` will fetch. Keeping those apart is what lets
/// you pick a place, zoom out to check you picked the right one, and still
/// have it picked.
private struct LocatorPanelContent: View {
    @Bindable var model: MapModel
    /// The way the buttons above the map reach the map. Same as
    /// `ContentView`'s `canvasHandle`, for the same reason. Owned by the
    /// controller rather than here, because the panel's event monitor needs it
    /// as well.
    let handle: LocatorHandle
    let trace: PenTrace
    @Bindable var mode: LocatorMode
    let onRender: () -> Void
    @State private var chosen: ChosenPoint?

    /// What was clicked, kept so it can be shown. The area it produced lives
    /// in the model, where everything else can see it; this is only the
    /// original point, which reads better than the four corners it became.
    private struct ChosenPoint: Equatable {
        let lat: Double
        let lon: Double
    }

    /// The same 1.3 the main canvas's buttons use would be a timid step across
    /// a span this wide — the locator starts at the whole world and has to get
    /// down to a city.
    private static let zoomStep = 1.6

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Locator(
                    bbox: model.bbox,
                    isSettled: model.didFinishLaunchSetup,
                    // What this window shows *is* the area. Browsing used to
                    // be only browsing, with a click choosing instead — which
                    // meant the preview and the request were two different
                    // things, and pressing Render map after a click and a zoom
                    // fetched a tenth of a degree around the pin while the
                    // preview showed a county. What you see is what is drawn.
                    onRegionChanged: { model.browseWorldMap(to: $0) },
                    onPointSelected: { lat, lon in
                        chosen = ChosenPoint(lat: lat, lon: lon)
                    },
                    onAreaDrawn: { area in
                        chosen = nil
                        model.drawAreaOnWorldMap(area)
                        // One rectangle, then back to browsing: leaving the
                        // mode on makes the next pan draw another area by
                        // accident, which is how a chosen area gets lost.
                        mode.isDrawingArea = false
                    },
                    isDrawingArea: mode.isDrawingArea,
                    handle: handle,
                    trace: trace
                )

                // Sized to itself and pinned to the corner, so it covers its own
                // 30-odd points of the map and nothing more. The bordered overlay
                // is safe *here* for the reason it was not safe over the whole
                // map: a stroked shape hit-tests as its full frame, and this
                // frame is the button stack.
                zoomControls
                    .padding(10)

                VStack {
                    Spacer()
                    HStack {
                        keyLegend
                        Spacer()
                    }
                }
                .padding(10)
                .allowsHitTesting(false)
            }
            .padding(8)
            // The map itself cannot take key presses — it is an `MKMapView`
            // inside an `NSViewRepresentable` — so the surrounding view holds
            // the focus and translates them.
            .focusable()
            .focusEffectDisabled()
            .onKeyPress { press in handle(press) }

            Divider()
            readout
        }
    }

    // MARK: - The keyboard

    /// Arrow keys to move, `+`/`-` to zoom, `0` for the whole world, `d` to
    /// draw. Written out on the map itself — see `keyLegend` — because a
    /// shortcut nobody is told about is a shortcut nobody uses.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Shift moves three times as far, which is the difference between
        // nudging a coastline into view and crossing a sea.
        let far = press.modifiers.contains(.shift) ? 3.0 : 1.0
        switch press.key {
        case .leftArrow: handle.pan(dx: -far, dy: 0)
        case .rightArrow: handle.pan(dx: far, dy: 0)
        case .upArrow: handle.pan(dx: 0, dy: far)
        case .downArrow: handle.pan(dx: 0, dy: -far)
        case .escape:
            guard mode.isDrawingArea else { return .ignored }
            mode.isDrawingArea = false
        default:
            switch press.characters.lowercased() {
            case "+", "=": handle.zoom(by: Self.zoomStep)
            case "-", "_": handle.zoom(by: 1 / Self.zoomStep)
            case "0": handle.showWholeWorld()
            case "d": mode.isDrawingArea.toggle()
            default: return .ignored
            }
        }
        return .handled
    }

    /// The keys, on the map, in the corner nothing else uses.
    private var keyLegend: some View {
        VStack(alignment: .leading, spacing: 2) {
            legendRow("↑ ↓ ← →", "move")
            legendRow("⇧ + arrows", "move further")
            legendRow("+ −", "zoom")
            legendRow("0", "whole world")
            legendRow("D", "draw an area")
            legendRow("⌘↵", "render")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5)
        }
        // Never in the way of the map it explains.
        .allowsHitTesting(false)
    }

    private func legendRow(_ keys: String, _ what: String) -> some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 62, alignment: .leading)
            Text(what)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - The buttons

    /// Deliberately the same stack of controls as `ContentView.zoomControls`:
    /// same size, same material, same border. Two maps in one app that zoom by
    /// different-looking buttons would be two apps.
    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button { handle.zoom(by: Self.zoomStep) } label: {
                Image(systemName: "plus").frame(width: 22, height: 22)
            }
            .help("Zoom in")

            Divider().frame(width: 22)

            Button { handle.zoom(by: 1 / Self.zoomStep) } label: {
                Image(systemName: "minus").frame(width: 22, height: 22)
            }
            .help("Zoom out")

            Divider().frame(width: 22)

            Button { handle.showWholeWorld() } label: {
                Image(systemName: "globe").frame(width: 22, height: 22)
            }
            .help("Back to the whole world")

            Divider().frame(width: 22)

            // Drag out an area rather than clicking a place. Tinted while on,
            // because a mode that does not look different from the mode beside
            // it is a mode nobody can tell they are in.
            Button { mode.isDrawingArea.toggle() } label: {
                Image(systemName: "rectangle.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(mode.isDrawingArea ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .help(
                mode.isDrawingArea
                    ? "Drag on the map to draw the area. Click here again to go back to panning."
                    : "Draw an area by dragging a rectangle, instead of clicking a single place."
            )
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    // MARK: - What was chosen

    /// The coordinates, said plainly. Clicking a place that then shows nothing
    /// back is indistinguishable from clicking a place and nothing happening.
    @ViewBuilder
    private var readout: some View {
        HStack(spacing: 10) {
            if let chosen {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.tint)
                Text(String(format: "%.5f, %.5f", chosen.lat, chosen.lon))
                    .font(.callout)
                    .monospacedDigit()
                    // Selectable because a coordinate you can read but not copy
                    // is half a coordinate.
                    .textSelection(.enabled)
                Text("· \(model.areaDescription) around it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Render map fetches this")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
                Text("Click a place to choose it. Drag to pan, + and − to zoom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }

            // Rendering from here, so choosing a place and drawing it are not
            // separated by a trip back to the main window — which is the whole
            // reason this panel is a window of its own.
            // Renders `model.bbox`, which this window's map keeps up to date.
            // It deliberately does not go through the main canvas's visible
            // area the way the toolbar button does: the two windows show
            // different things, and a button on this one that quietly drew the
            // other one's view is how an "extreme zoom" arrives out of nowhere.
            Button(action: onRender) {
                if model.isFetching {
                    Label("Rendering…", systemImage: "hourglass")
                } else {
                    Label("Render map", systemImage: "square.and.arrow.up.trianglebadge.exclamationmark")
                }
            }
            .labelStyle(.titleOnly)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.isFetching || model.bbox == nil)
            .help("Fetch and draw the chosen area — the same as Render map in the main window.")

            // What the map is actually receiving — only when asked for. See
            // `PenTrace.isShown`.
            if PenTrace.isShown {
                Text(trace.summary)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .help(
                    "Presses the window received inside the map, places chosen, "
                    + "and which route the last one arrived by."
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
