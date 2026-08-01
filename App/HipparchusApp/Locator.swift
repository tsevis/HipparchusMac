import HipparchusGeometry
import MapKit
import SwiftUI

/// The world, to browse and to choose from.
///
/// A real, live `MKMapView` — interactive, not a static indicator — because it
/// is the one place an area can be chosen by *looking at the actual world*
/// rather than by naming it or typing four numbers: before anything has ever
/// been fetched the main canvas is blank, with no basemap of its own to draw a
/// selection on top of.
///
/// It appears twice, and means slightly different things in each place, which
/// is what `onRegionChanged` and `onPointSelected` are for. In the sidebar
/// strip there is no room to aim at anything, so what is on screen *is* the
/// area: pan and zoom to choose. In the floating panel there is room, so
/// panning and zooming only go looking, and a click is what chooses — which
/// matters, because otherwise nudging the view to check what you had picked
/// would silently throw the pick away.
///
/// Two directions have to agree without fighting each other. Choosing here
/// becomes the requested area — but the requested area can also change from
/// elsewhere entirely (typing coordinates, a search result, a saved place,
/// Option-drag on the main canvas), and this has to move to show that too.
/// `Coordinator` is what keeps the two from turning into a ping-pong: a region
/// this view is *told* to show is marked before it is set, and the delegate
/// callback that same `setRegion` triggers checks that mark and does not
/// report it back as if the user had just panned there.
struct Locator: NSViewRepresentable {
    let bbox: BoundingBox?
    /// Whether launch setup — a restored session, a `--bbox` override — has
    /// finished. See `LocatorSync` for why this needs saying at all: a
    /// restored area arrives one SwiftUI update after the window first
    /// appears, and looks exactly like a real change unless something says
    /// which is which.
    let isSettled: Bool
    /// What is on screen, after every pan and zoom. `nil` where browsing is
    /// only browsing and a click is what chooses.
    var onRegionChanged: ((BoundingBox) -> Void)?
    /// Where a click landed, in degrees. `nil` where there is no room to aim
    /// at anything.
    var onPointSelected: ((Double, Double) -> Void)?
    /// A rectangle dragged across the map, as an area. `nil` where dragging
    /// only pans.
    var onAreaDrawn: ((BoundingBox) -> Void)?
    /// Whether a drag draws an area rather than panning the map.
    ///
    /// A mode rather than a modifier key, unlike the main canvas's
    /// Option-drag: this map is also the one place someone arrives without
    /// knowing the app yet, and a modifier nobody is told about is a feature
    /// nobody finds. The button that turns it on says what it does.
    var isDrawingArea = false
    /// Lets the zoom buttons reach the map they sit on top of. Same shape as
    /// `MapCanvasHandle`, and for the same reason: SwiftUI has no other way to
    /// send a one-off instruction to an `NSView` it is only describing.
    var handle: LocatorHandle?
    /// Where to report what the map is actually receiving.
    var trace: PenTrace?

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.isZoomEnabled = true
        view.isScrollEnabled = true
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.pointOfInterestFilter = .excludingAll
        view.delegate = context.coordinator
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor

        if onPointSelected != nil {
            // `ForgivingClickRecognizer` rather than `NSClickGestureRecognizer`
            // — see its own note. AppKit's version treats any movement at all
            // between press and release as a drag, which a mouse can avoid and
            // a pen cannot, so on a Wacom every click was silently discarded.
            let click = ForgivingClickRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleClick(_:))
            )
            // At its default of true this would hold every mouse-down back
            // until it knew the click was not the start of a drag — which is
            // precisely how a map ends up not panning. The two do not need
            // arbitrating anyway: this recognizer fails itself as soon as the
            // movement is real, and the map's own pan takes it from there.
            click.delaysPrimaryMouseButtonEvents = false
            view.addGestureRecognizer(click)
        }

        if onAreaDrawn != nil {
            let drag = NSPanGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.handleAreaDrag(_:))
            )
            drag.delaysPrimaryMouseButtonEvents = false
            // Installed always, and inert unless the mode is on — see the
            // recognizer's own delegate check. Adding and removing it as the
            // mode changes would mean rebuilding gesture state mid-gesture.
            drag.delegate = context.coordinator
            view.addGestureRecognizer(drag)
            context.coordinator.areaDrag = drag
        }

        context.coordinator.onPointSelected = onPointSelected
        context.coordinator.trace = trace
        handle?.adopt(view, coordinator: context.coordinator)

        // Always the whole world to start, whatever area is already requested
        // — this is a place to go looking, not a mirror of the main canvas.
        // `MKMapRect.world` rather than a manually guessed coordinate span:
        // MapKit has a hard, size-dependent limit on how far out it will
        // actually zoom — a view this size cannot show more than roughly
        // 70° in either direction no matter what is asked for — and the
        // map rect lets MapKit pick its own real maximum for whatever size
        // this view turns out to be, rather than a fixed span that is
        // sometimes far past what is achievable and sometimes short of it.
        context.coordinator.isSettingRegionProgrammatically = true
        view.setVisibleMapRect(.world, animated: false)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.onRegionChanged = onRegionChanged
        context.coordinator.onPointSelected = onPointSelected
        context.coordinator.onAreaDrawn = onAreaDrawn
        context.coordinator.trace = trace
        context.coordinator.isDrawingArea = isDrawingArea
        handle?.adopt(view, coordinator: context.coordinator)

        // While drawing, the map must not also pan under the drag — the
        // rectangle would slide away from the ground it was aimed at.
        view.isScrollEnabled = !isDrawingArea

        view.removeOverlays(view.overlays)
        guard let bbox else { return }

        let corners = [
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLon),
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.minLon),
        ]
        view.addOverlay(MKPolygon(coordinates: corners, count: corners.count))

        // See `LocatorSync`: a restored session's area lands one update after
        // the window appears, indistinguishable from a real change unless
        // `isSettled` says which tick it arrived in.
        let decision = LocatorSync.decide(
            bbox: bbox, wasSettled: context.coordinator.wasSettled, lastKnown: context.coordinator.lastKnownBBox
        )
        context.coordinator.wasSettled = isSettled
        context.coordinator.lastKnownBBox = decision.newLastKnown
        guard decision.shouldSync else { return }

        // This area is the click that just happened here, arriving back
        // through the model. The rectangle above is the whole response it
        // wants: flying the map to a tenth of a degree around the point would
        // throw away the view the click was aimed from, and make choosing the
        // next place over a matter of zooming back out first. An area that
        // came from anywhere else — a search, a saved place, typed
        // coordinates — still gets shown, which is the point of the guard
        // being this narrow.
        guard !context.coordinator.isEchoOfItsOwnClick(bbox) else { return }

        // Already showing this, most likely because the change just came
        // *from* here: setting it again would be redundant, and would fire
        // the delegate again for nothing.
        guard !context.coordinator.isAlreadyShowing(bbox, on: view) else { return }

        context.coordinator.isSettingRegionProgrammatically = true
        view.setRegion(MKCoordinateRegion(bbox), animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRegionChanged: onRegionChanged)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        var onRegionChanged: ((BoundingBox) -> Void)?
        var onPointSelected: ((Double, Double) -> Void)?
        var onAreaDrawn: ((BoundingBox) -> Void)?
        var isDrawingArea = false
        /// Held so the delegate below can tell this recognizer from the map's
        /// own, and decline only this one.
        weak var areaDrag: NSPanGestureRecognizer?
        var isSettingRegionProgrammatically = false
        var wasSettled = false
        var lastKnownBBox: BoundingBox?
        /// What the window says out loud about the input it is receiving. See
        /// `PenTrace`: with no way to watch someone use this, "nothing
        /// happened" has three different causes that need three different
        /// fixes, and this is what tells them apart.
        var trace: PenTrace?
        /// The area the last click here produced, so that same area coming
        /// back through the model is recognised as an echo rather than as
        /// somewhere new to fly to.
        var selectedByClick: BoundingBox?

        init(onRegionChanged: ((BoundingBox) -> Void)?) {
            self.onRegionChanged = onRegionChanged
        }

        /// Close enough that the difference is rounding, not a real move —
        /// about a metre, far tighter than anything a pan or zoom gesture
        /// could land on by coincidence.
        func isAlreadyShowing(_ bbox: BoundingBox, on mapView: MKMapView) -> Bool {
            BoundingBox(mapView.region).isNearly(bbox, within: 1e-5)
        }

        /// Whether an area arriving from the model is the click that just
        /// happened here, coming back around.
        ///
        /// Compared loosely on purpose. The model keeps the area as *text*,
        /// five decimal places of it — `setArea` formats, `bbox` parses — so
        /// what returns is never bit-for-bit what went out, and an exact
        /// comparison would call every click somewhere new and fly the map to
        /// a tenth of a degree around the point. Ten metres is a hundred times
        /// past that rounding and five hundred times short of the padding a
        /// click gets, so nothing else can be mistaken for one.
        func isEchoOfItsOwnClick(_ bbox: BoundingBox) -> Bool {
            selectedByClick?.isNearly(bbox, within: 1e-4) ?? false
        }

        // MARK: - Choosing a place by clicking it

        @objc func handleClick(_ recognizer: NSGestureRecognizer) {
            trace?.noteRecognizer("click")
            guard let mapView = recognizer.view as? MKMapView else { return }
            _ = selectPoint(at: recognizer.location(in: mapView), in: mapView, via: "recognizer")
        }

        /// Turn a point in the window into a place, mark it, and report it.
        ///
        /// Split out from `handleClick` so it can be driven without an actual
        /// mouse: synthesising an `NSClickGestureRecognizer` mid-gesture is not
        /// something a headless check can do, but this is every part of the
        /// click that has an answer worth being wrong about. Returns what it
        /// resolved, for the same reason.
        @discardableResult
        func selectPoint(
            at point: CGPoint, in mapView: MKMapView, via route: String = "direct"
        ) -> CLLocationCoordinate2D? {
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            // A map zoomed out far enough is letterboxed inside its own view,
            // so a click can land beside the world rather than on it, and
            // MapKit answers with a coordinate that is not one.
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

            trace?.noteSelection(via: route)
            selectedByClick = LocatorSelection.area(
                around: coordinate.latitude, lon: coordinate.longitude
            )

            // One marker, not a trail of them: this is the place chosen, and
            // there is only ever one of those.
            mapView.removeAnnotations(mapView.annotations)
            let marker = MKPointAnnotation()
            marker.coordinate = coordinate
            mapView.addAnnotation(marker)

            onPointSelected?(coordinate.latitude, coordinate.longitude)
            return coordinate
        }

        // MARK: - Drawing an area by dragging one

        /// The rubber band, as a layer over the map rather than a SwiftUI view
        /// over it — a SwiftUI overlay would sit in front of the `MKMapView`
        /// and eat the very drag it is drawing.
        private var band: CAShapeLayer?
        private var dragOrigin: CGPoint?

        @objc func handleAreaDrag(_ recognizer: NSPanGestureRecognizer) {
            trace?.noteRecognizer("pan \(recognizer.state.rawValue)\(isDrawingArea ? "" : " off")")
            guard isDrawingArea, let mapView = recognizer.view as? MKMapView else { return }
            let point = recognizer.location(in: mapView)

            switch recognizer.state {
            case .began:
                dragOrigin = point
                showBand(on: mapView, from: point, to: point)

            case .changed:
                guard let dragOrigin else { return }
                showBand(on: mapView, from: dragOrigin, to: point)

            case .ended:
                defer { clearBand(); dragOrigin = nil }
                guard let dragOrigin else { return }
                report(from: dragOrigin, to: point, in: mapView)

            case .cancelled, .failed:
                clearBand()
                dragOrigin = nil

            default:
                break
            }
        }

        /// Turn the two dragged corners into an area and hand it out.
        ///
        /// Split out and non-private for the same reason `selectPoint` is:
        /// nothing here can perform a real drag, but every decision the drag
        /// makes can be driven directly.
        @discardableResult
        func report(from start: CGPoint, to end: CGPoint, in mapView: MKMapView) -> BoundingBox? {
            // A drag of a few points is a slip of the hand, not an area — and
            // an area of nearly no extent is one `Render map` would refuse.
            guard hypot(end.x - start.x, end.y - start.y) > ForgivingClickRecognizer.slop else {
                return nil
            }
            let first = mapView.convert(start, toCoordinateFrom: mapView)
            let second = mapView.convert(end, toCoordinateFrom: mapView)
            guard CLLocationCoordinate2DIsValid(first), CLLocationCoordinate2DIsValid(second) else {
                return nil
            }

            let area = BoundingBox(
                minLon: Swift.min(first.longitude, second.longitude),
                minLat: Swift.min(first.latitude, second.latitude),
                maxLon: Swift.max(first.longitude, second.longitude),
                maxLat: Swift.max(first.latitude, second.latitude)
            )
            guard area.lonSpan > 0, area.latSpan > 0 else { return nil }

            // Marked as ours for the same reason a click is: this area is
            // about to arrive back through the model, and the map must not
            // fly to it and throw away the view it was drawn on.
            selectedByClick = area
            // The marker belongs to a point, not to a rectangle.
            mapView.removeAnnotations(mapView.annotations)
            trace?.noteSelection(via: "drag")
            onAreaDrawn?(area)
            return area
        }

        func showBand(on mapView: MKMapView, from start: CGPoint, to end: CGPoint) {
            let layer: CAShapeLayer
            if let band {
                layer = band
            } else {
                layer = CAShapeLayer()
                layer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                layer.strokeColor = NSColor.controlAccentColor.cgColor
                layer.lineWidth = 1.5
                layer.lineDashPattern = [4, 3]
                // Above the map's own tiles and overlays.
                layer.zPosition = 1_000
                mapView.layer?.addSublayer(layer)
                band = layer
            }
            let rect = CGRect(
                x: Swift.min(start.x, end.x), y: Swift.min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            // No implicit animation: a rubber band that eases toward the
            // pointer lags behind the hand and reads as stutter.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = CGPath(rect: rect, transform: nil)
            CATransaction.commit()
        }

        func clearBand() {
            band?.removeFromSuperlayer()
            band = nil
        }

        /// The same three moments the recognizer goes through, named for the
        /// monitor that also drives them.
        func beginBand(on mapView: MKMapView, at point: CGPoint) {
            showBand(on: mapView, from: point, to: point)
        }

        func updateBand(on mapView: MKMapView, from start: CGPoint, to end: CGPoint) {
            showBand(on: mapView, from: start, to: end)
        }

        func endBand() {
            clearBand()
        }

        // MARK: - NSGestureRecognizerDelegate

        /// The drag recognizer stays installed and simply declines to begin
        /// unless the mode is on, which leaves the map's own pan untouched the
        /// rest of the time.
        func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool {
            recognizer === areaDrag ? isDrawingArea : true
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isSettingRegionProgrammatically else {
                isSettingRegionProgrammatically = false
                return
            }
            onRegionChanged?(BoundingBox(mapView.region))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let polygon = overlay as? MKPolygon else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.strokeColor = .controlAccentColor
            renderer.lineWidth = 2
            renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
            return renderer
        }
    }
}

// MARK: - Reaching the map from the buttons above it

/// A way to tell the locator's map to do one thing, once.
///
/// The same shape as `MapCanvasHandle`, and there for the same reason: the
/// zoom buttons are SwiftUI views sitting on top of an `NSView` that SwiftUI
/// only describes, and a description is not something a button can press.
@MainActor
final class LocatorHandle {
    private(set) weak var view: MKMapView?
    private weak var coordinator: Locator.Coordinator?

    /// Held weakly: the map and its coordinator belong to SwiftUI's view tree,
    /// not to this.
    func adopt(_ view: MKMapView, coordinator: Locator.Coordinator) {
        self.view = view
        self.coordinator = coordinator
    }

    /// Choose a place from a point in the map's own coordinates, by the same
    /// code a recognized click goes through. The panel's event monitor calls
    /// this — see `LocatorPanelController` for why there are two ways in.
    @discardableResult
    func selectPoint(at point: CGPoint) -> Bool {
        guard let view, let coordinator else { return false }
        return coordinator.selectPoint(at: point, in: view, via: "monitor") != nil
    }

    // MARK: - Drawing an area, driven from the event monitor

    /// The three moments of a drag, exposed so the panel's event monitor can
    /// drive them.
    ///
    /// The gesture recognizer can drive the same three, and does. Both exist
    /// for the reason the click has two routes: a recognizer that never fires
    /// is indistinguishable from a map that ignores you, and the monitor is
    /// the route already known to receive a pen's events.
    func beginDrawing(at point: CGPoint) {
        guard let view, let coordinator else { return }
        coordinator.beginBand(on: view, at: point)
    }

    func updateDrawing(from start: CGPoint, to end: CGPoint) {
        guard let view, let coordinator else { return }
        coordinator.updateBand(on: view, from: start, to: end)
    }

    @discardableResult
    func finishDrawing(from start: CGPoint, to end: CGPoint) -> Bool {
        guard let view, let coordinator else { return false }
        coordinator.endBand()
        return coordinator.report(from: start, to: end, in: view) != nil
    }

    /// Zoom about the middle of what is on screen. Greater than one moves
    /// closer, matching `ViewportState.zoomed(by:)` on the main canvas so the
    /// two pairs of buttons mean the same thing.
    ///
    /// The arithmetic is `LocatorSelection.zoomed`, which is tested; this is
    /// only the part that has to touch MapKit.
    func zoom(by factor: Double) {
        guard let view else { return }
        let zoomed = LocatorSelection.zoomed(BoundingBox(view.region), by: factor)
        // Deliberately *not* marked as programmatic: pressing the button is
        // the user moving the map, exactly as a pinch is, and the sidebar
        // locator — where what is on screen is the area — has to hear about it.
        view.setRegion(MKCoordinateRegion(zoomed), animated: true)
    }

    /// Shift the view by a fraction of what is on screen.
    ///
    /// A fraction rather than a fixed number of degrees, because the arrow
    /// keys have to be useful at both ends: a fifth of the view is a
    /// comfortable step whether the map is showing a city or an ocean.
    func pan(dx: Double, dy: Double) {
        guard let view else { return }
        let region = view.region
        let step = 0.2
        let centre = CLLocationCoordinate2D(
            latitude: Swift.min(Swift.max(
                region.center.latitude + dy * region.span.latitudeDelta * step, -85), 85),
            longitude: Swift.min(Swift.max(
                region.center.longitude + dx * region.span.longitudeDelta * step, -180), 180)
        )
        view.setRegion(MKCoordinateRegion(center: centre, span: region.span), animated: true)
    }

    /// Back out to the whole world, the way `Fit` on the main canvas goes back
    /// to the whole map. `MKMapRect.world` rather than a guessed span, for the
    /// reason given in `makeNSView` — and, like `zoom(by:)`, reported outward
    /// rather than suppressed, because a button is the user moving the map.
    func showWholeWorld() {
        guard let view else { return }
        view.setVisibleMapRect(.world, animated: true)
    }
}

// MARK: - Bridging MapKit's region shape to this app's own

extension BoundingBox {
    /// The same area, give or take. Two areas here come from different places
    /// — MapKit's own region, and four numbers the model has been through text
    /// and back — so they agree to a tolerance or they do not agree at all.
    func isNearly(_ other: BoundingBox, within tolerance: Double) -> Bool {
        abs(minLon - other.minLon) < tolerance
            && abs(minLat - other.minLat) < tolerance
            && abs(maxLon - other.maxLon) < tolerance
            && abs(maxLat - other.maxLat) < tolerance
    }

    /// Ported through `centerLat:centerLon:latSpan:lonSpan:`, tested there —
    /// this is only the bridge from MapKit's own type to the plain numbers
    /// that initialiser takes.
    init(_ region: MKCoordinateRegion) {
        self.init(
            centerLat: region.center.latitude, centerLon: region.center.longitude,
            latSpan: region.span.latitudeDelta, lonSpan: region.span.longitudeDelta
        )
    }
}

extension MKCoordinateRegion {
    init(_ bbox: BoundingBox) {
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (bbox.minLat + bbox.maxLat) / 2, longitude: (bbox.minLon + bbox.maxLon) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: abs(bbox.latSpan), longitudeDelta: abs(bbox.lonSpan))
        )
    }
}


/// Whether the floating Locator is drawing an area or choosing a place.
///
/// A type of its own, and observable, because two things need it: the button
/// that toggles it, and the panel's event monitor, which is not a SwiftUI view
/// and cannot read `@State`.
@MainActor
@Observable
final class LocatorMode {
    var isDrawingArea = false
}
