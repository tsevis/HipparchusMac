import HipparchusGeometry
import MapKit

// MARK: - Verifying what nobody can click

/// Exists for the same reason `--search` does: nobody can drag, click or press
/// a button on this map in a screenshot-less environment. Everything here
/// drives the real `Locator.Coordinator`, the real `LocatorHandle` and a real
/// `MKMapView` — not a re-implementation of any of them — so what is checked is
/// the code that ships.
///
/// What each of these cannot check is the last inch: whether AppKit delivers a
/// real mouse-down to the recognizer, and whether a real button in a real
/// window is where it looks like it is. That inch needs eyes.

/// A single-threaded, entirely synchronous collector: `setRegion` fires the
/// delegate synchronously on the calling thread throughout, so the
/// `@unchecked` is not papering over anything genuinely concurrent.
private final class VerificationResult: @unchecked Sendable {
    var bbox: BoundingBox?
    var points: [(lat: Double, lon: Double)] = []
}

/// A map with a real frame and a known region, laid out as a window would lay
/// it out. Everything below needs one, and getting it wrong — no frame, no
/// layout — is what makes `convert(_:toCoordinateFrom:)` quietly answer
/// nonsense.
@MainActor
private func laidOutMap(
    _ coordinator: Locator.Coordinator, region: MKCoordinateRegion, size: CGSize
) -> MKMapView {
    let mapView = MKMapView(frame: CGRect(origin: .zero, size: size))
    mapView.delegate = coordinator
    mapView.layoutSubtreeIfNeeded()
    coordinator.isSettingRegionProgrammatically = true
    mapView.setRegion(region, animated: false)
    mapView.layoutSubtreeIfNeeded()
    return mapView
}

/// Establishes a programmatic starting region exactly as `makeNSView` does,
/// then simulates what a finished pan or zoom gesture leaves behind: `MapKit`
/// itself calling `setRegion` and then firing the delegate, which is
/// indistinguishable from this at the `Coordinator`'s level. The interesting
/// part — the conversion math, and whether the loop-avoidance flag correctly
/// tells "the app moved this" from "the user moved this" apart — is fully
/// exercised; the one thing this does not test is whether `MapKit` calls the
/// delegate after a real drag, which is core, ubiquitous framework behaviour
/// that does not need re-proving here.
@MainActor
func verifyLocatorRegionConversion(
    centerLat: Double, centerLon: Double, latSpan: Double, lonSpan: Double
) -> String {
    let result = VerificationResult()
    let coordinator = Locator.Coordinator(onRegionChanged: { result.bbox = $0 })
    let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 220))
    mapView.delegate = coordinator

    // `setVisibleMapRect` fires `regionDidChangeAnimated` on its own,
    // synchronously, even for a view with no window — exactly as it does
    // for the real `Locator`, which is why neither this nor
    // `makeNSView`/`updateNSView` ever calls the delegate method directly.
    coordinator.isSettingRegionProgrammatically = true
    mapView.setVisibleMapRect(.world, animated: false)
    guard result.bbox == nil else {
        return "FAIL: the programmatic starting region was reported as if the user had panned there"
    }

    let simulated = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
        span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
    )
    mapView.setRegion(simulated, animated: false)

    guard let reported = result.bbox else {
        return "FAIL: a user-driven region change was never reported"
    }
    return String(
        format: "reported: %.6f,%.6f -> %.6f,%.6f  (%.4f° × %.4f°)",
        reported.minLon, reported.minLat, reported.maxLon, reported.maxLat,
        abs(reported.lonSpan), abs(reported.latSpan)
    )
}

/// Reproduces the exact launch sequence a real window puts this view
/// through — `makeNSView` on a still-unsized view (SwiftUI has not laid it
/// out yet), then `updateNSView` with whatever bbox the model starts with,
/// then the frame SwiftUI actually gives it (which is when a zero-size view
/// turns out to defer its region report until it has real bounds), then a
/// second `updateNSView` with a settled, restored bbox — the exact sequence
/// that showed the wrong area on screen. Prints the map's own region and
/// `onRegionChanged`'s reports at each step, so a wrong step is visible
/// rather than only its final symptom.
@MainActor
func verifyLocatorLaunchSequence(defaultBBox: BoundingBox, restoredBBox: BoundingBox) -> String {
    final class Reports: @unchecked Sendable {
        var seen: [BoundingBox] = []
    }
    let reports = Reports()
    let coordinator = Locator.Coordinator(onRegionChanged: { reports.seen.append($0) })
    // Exactly as `makeNSView` does: a fresh view, no frame yet.
    let mapView = MKMapView()
    mapView.delegate = coordinator

    coordinator.isSettingRegionProgrammatically = true
    mapView.setVisibleMapRect(.world, animated: false)
    var log = "after makeNSView-style setVisibleMapRect (zero frame): reports=\(reports.seen.count)\n"

    // updateNSView call 1: the model's own starting default, launch setup
    // not finished yet.
    var decision = LocatorSync.decide(bbox: defaultBBox, wasSettled: coordinator.wasSettled, lastKnown: coordinator.lastKnownBBox)
    coordinator.wasSettled = false
    coordinator.lastKnownBBox = decision.newLastKnown
    log += "call 1 (unsettled, default bbox): shouldSync=\(decision.shouldSync)\n"

    // SwiftUI actually laying the view out — this is what triggers a
    // zero-frame `setRegion`'s deferred report, per the standalone
    // reproduction that found it.
    mapView.frame = CGRect(x: 0, y: 0, width: 200, height: 220)
    mapView.layoutSubtreeIfNeeded()
    log += "after real frame assigned + layout: reports=\(reports.seen.count) region=\(mapView.region)\n"

    // updateNSView call 2: launch setup has now finished, restore() has set
    // the real, saved area.
    decision = LocatorSync.decide(bbox: restoredBBox, wasSettled: coordinator.wasSettled, lastKnown: coordinator.lastKnownBBox)
    coordinator.wasSettled = true
    coordinator.lastKnownBBox = decision.newLastKnown
    log += "call 2 (settled, restored bbox): shouldSync=\(decision.shouldSync)\n"
    if decision.shouldSync {
        coordinator.isSettingRegionProgrammatically = true
        mapView.setRegion(MKCoordinateRegion(restoredBBox), animated: true)
    }
    log += "final region shown: \(mapView.region)\n"
    log += "final reports passed to onRegionChanged: \(reports.seen.count)\n"
    for (i, r) in reports.seen.enumerated() {
        log += "  report #\(i): \(r)\n"
    }
    return log
}

// MARK: - The click

/// Put an area through the exact round trip `MapModel` puts it through:
/// `setArea` formats each edge to five decimal places of text, and `bbox`
/// parses that text back. Nothing that leaves the model is the number that
/// went in, and code that assumes otherwise breaks in a way that looks like a
/// MapKit problem.
private func areaAsTheModelKeepsIt(_ bbox: BoundingBox) -> BoundingBox? {
    func roundTrip(_ value: Double) -> Double? { Double(String(format: "%.5f", value)) }
    guard let minLon = roundTrip(bbox.minLon), let minLat = roundTrip(bbox.minLat),
          let maxLon = roundTrip(bbox.maxLon), let maxLat = roundTrip(bbox.maxLat)
    else { return nil }
    return BoundingBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat)
}

/// Drive `Coordinator.selectPoint(at:in:)` — every part of a click that has an
/// answer worth being wrong about — against a real, laid-out `MKMapView`
/// showing a known region.
///
/// Three things are checked, none of them by re-deriving MapKit's projection,
/// which would only prove this file agrees with itself:
///
/// 1. **Round trip.** A point converted to a coordinate and back by MapKit's
///    own inverse must land where it started. This catches a wrong view, a
///    wrong coordinate space, and an unlaid-out map — the whole family of
///    "it returns a plausible number that is not the place you clicked".
/// 2. **The middle of the view is the middle of the region.** The one point
///    whose answer is known independently of the projection.
/// 3. **The area produced holds the point.** A click has to become a box
///    `Render map` will fetch, centred on what was clicked.
@MainActor
func verifyLocatorClick() -> String {
    let athens = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.9760, longitude: 23.7350),
        span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.32)
    )
    let size = CGSize(width: 700, height: 560)
    let result = VerificationResult()
    let coordinator = Locator.Coordinator(onRegionChanged: { _ in })
    coordinator.onPointSelected = { result.points.append((lat: $0, lon: $1)) }
    let mapView = laidOutMap(coordinator, region: athens, size: size)

    var log = String(
        format: "map %.0f×%.0f showing %.4f,%.4f  ±%.4f° lat  ±%.4f° lon\n",
        size.width, size.height,
        mapView.region.center.latitude, mapView.region.center.longitude,
        mapView.region.span.latitudeDelta / 2, mapView.region.span.longitudeDelta / 2
    )
    var failures: [String] = []

    let probes: [(name: String, point: CGPoint)] = [
        ("centre", CGPoint(x: size.width / 2, y: size.height / 2)),
        ("upper left", CGPoint(x: size.width / 4, y: size.height / 4)),
        ("lower right", CGPoint(x: size.width * 3 / 4, y: size.height * 3 / 4)),
        ("near a corner", CGPoint(x: 12, y: 12)),
    ]

    for probe in probes {
        let before = result.points.count
        guard let coordinate = coordinator.selectPoint(at: probe.point, in: mapView) else {
            failures.append("\(probe.name): the click resolved to no coordinate at all")
            continue
        }

        // 1. MapKit's own inverse must bring the point back to where it began.
        let back = mapView.convert(coordinate, toPointTo: mapView)
        let drift = hypot(back.x - probe.point.x, back.y - probe.point.y)
        if drift > 0.5 {
            failures.append(String(
                format: "\(probe.name): clicking (%.1f, %.1f) resolved to a coordinate that maps back to (%.1f, %.1f) — %.2fpt away",
                probe.point.x, probe.point.y, back.x, back.y, drift
            ))
        }

        // 3. The click has to have been reported outward, once.
        guard result.points.count == before + 1 else {
            failures.append("\(probe.name): the click was not reported to the app")
            continue
        }
        let reported = result.points[before]
        let area = LocatorSelection.area(around: reported.lat, lon: reported.lon)
        let holdsIt = area.minLat < reported.lat && reported.lat < area.maxLat
            && area.minLon < reported.lon && reported.lon < area.maxLon
        if !holdsIt {
            failures.append("\(probe.name): the area produced does not contain the point clicked")
        }

        log += String(
            format: "  click (%3.0f, %3.0f) -> %.5f, %.5f  ·  back to (%.1f, %.1f), %.3fpt drift  ·  area %.4f,%.4f -> %.4f,%.4f\n",
            probe.point.x, probe.point.y, reported.lat, reported.lon,
            back.x, back.y, drift,
            area.minLon, area.minLat, area.maxLon, area.maxLat
        )
    }

    // 2. The middle of the view, whose answer is known without the projection.
    if let centre = coordinator.selectPoint(
        at: CGPoint(x: size.width / 2, y: size.height / 2), in: mapView
    ) {
        let offLat = abs(centre.latitude - mapView.region.center.latitude)
        let offLon = abs(centre.longitude - mapView.region.center.longitude)
        log += String(format: "  centre of the view vs. centre of the region: %.6f° lat, %.6f° lon apart\n", offLat, offLon)
        if offLat > 1e-4 || offLon > 1e-4 {
            failures.append("the middle of the view did not resolve to the middle of the region")
        }
    }

    // One marker, replaced each time — not a trail left behind by every click.
    log += "  markers on the map after \(probes.count + 1) clicks: \(mapView.annotations.count)\n"
    if mapView.annotations.count != 1 {
        failures.append("expected exactly one marker, found \(mapView.annotations.count)")
    }

    // The click must not have been mistaken for the user panning: in the
    // floating panel that would overwrite the very selection just made.
    log += "  region after clicking: \(mapView.region.center.latitude), \(mapView.region.center.longitude)\n"
    if abs(mapView.region.center.latitude - athens.center.latitude) > 1e-4 {
        failures.append("clicking moved the map")
    }

    // And the echo. A click sets the model's area, the model hands that area
    // straight back to `updateNSView`, and the locator has to recognise it as
    // its own — otherwise every click ends with the map flying to a tenth of a
    // degree around the point, throwing away the view the click was aimed
    // from. The catch is that the model keeps the area as *text*: five decimal
    // places, formatted on the way in and parsed on the way out, so what comes
    // back is never bit-for-bit what went out. That round trip is reproduced
    // here exactly rather than assumed away.
    if let last = result.points.last {
        let area = LocatorSelection.area(around: last.lat, lon: last.lon)
        guard let throughTheModel = areaAsTheModelKeepsIt(area) else {
            failures.append("the area could not survive the model's own text round trip")
            return log + failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
        }
        log += String(
            format: "  the click's area:      %.7f,%.7f -> %.7f,%.7f\n",
            area.minLon, area.minLat, area.maxLon, area.maxLat
        )
        log += String(
            format: "  after the model:       %.7f,%.7f -> %.7f,%.7f\n",
            throughTheModel.minLon, throughTheModel.minLat,
            throughTheModel.maxLon, throughTheModel.maxLat
        )
        if !coordinator.isEchoOfItsOwnClick(throughTheModel) {
            failures.append(
                "the locator did not recognise its own click coming back, so every click would yank the map"
            )
        }
        // The same guard must not swallow an area from somewhere else — a
        // search result, a saved place — or the locator would stop following
        // anything but its own clicks.
        let elsewhere = BoundingBox(minLon: -122.53, minLat: 37.70, maxLon: -122.35, maxLat: 37.84)
        if coordinator.isEchoOfItsOwnClick(elsewhere) {
            failures.append("the locator mistook San Francisco for its own click on Athens")
        }
    }

    if failures.isEmpty {
        return log + "PASS: every click resolved to the place under it, and only that.\n"
    }
    return log + failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
}

// MARK: - Dragging out an area

/// Drive `Coordinator.report(from:to:in:)` — everything a drag decides — over a
/// real, laid-out map showing a known region.
///
/// Checked: the rectangle's corners land on the coordinates under them, the
/// area is the right way up whichever direction it was dragged in, and a drag
/// too small to be deliberate is refused rather than turned into an area of
/// almost no extent that `Render map` would then decline to fetch.
@MainActor
func verifyLocatorDrag() -> String {
    let athens = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.9760, longitude: 23.7350),
        span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.32)
    )
    let size = CGSize(width: 700, height: 560)
    let coordinator = Locator.Coordinator(onRegionChanged: { _ in })
    coordinator.isDrawingArea = true
    let mapView = laidOutMap(coordinator, region: athens, size: size)

    var log = "dragging on a 700×560 map of Athens\n"
    var failures: [String] = []

    let topLeft = CGPoint(x: 200, y: 150)
    let bottomRight = CGPoint(x: 500, y: 400)

    guard let area = coordinator.report(from: topLeft, to: bottomRight, in: mapView) else {
        return log + "FAIL: a deliberate drag produced no area at all\n"
    }
    log += String(
        format: "  drag (%.0f,%.0f)→(%.0f,%.0f) = %.5f,%.5f -> %.5f,%.5f  (%.4f° × %.4f°)\n",
        topLeft.x, topLeft.y, bottomRight.x, bottomRight.y,
        area.minLon, area.minLat, area.maxLon, area.maxLat,
        area.lonSpan, area.latSpan
    )

    // A real area, the right way round.
    if !(area.minLon < area.maxLon && area.minLat < area.maxLat) {
        failures.append("the area came out inside out")
    }

    // Each dragged corner has to be a corner of the area — that is what makes
    // the rectangle on screen the area that gets fetched.
    for (name, point) in [("start", topLeft), ("end", bottomRight)] {
        let corner = mapView.convert(point, toCoordinateFrom: mapView)
        let onEdge = (abs(corner.longitude - area.minLon) < 1e-9 || abs(corner.longitude - area.maxLon) < 1e-9)
            && (abs(corner.latitude - area.minLat) < 1e-9 || abs(corner.latitude - area.maxLat) < 1e-9)
        if !onEdge {
            failures.append("the \(name) corner is not a corner of the area")
        }
    }

    // Dragged the other way, it must describe the same ground.
    guard let reversed = coordinator.report(from: bottomRight, to: topLeft, in: mapView) else {
        return log + "FAIL: the reverse drag produced no area\n"
    }
    log += String(
        format: "  dragged the other way          = %.5f,%.5f -> %.5f,%.5f\n",
        reversed.minLon, reversed.minLat, reversed.maxLon, reversed.maxLat
    )
    if !reversed.isNearly(area, within: 1e-9) {
        failures.append("dragging up-left and down-right gave different areas")
    }

    // A slip of the hand is not an area.
    let slip = coordinator.report(
        from: topLeft, to: CGPoint(x: topLeft.x + 3, y: topLeft.y + 2), in: mapView
    )
    log += "  a 3.6pt slip of the hand: \(slip == nil ? "refused" : "TAKEN AS AN AREA")\n"
    if slip != nil {
        failures.append("a drag of a few points was taken as a deliberate area")
    }

    // And the drag must not have been mistaken for the user panning.
    if abs(mapView.region.center.latitude - athens.center.latitude) > 1e-4 {
        failures.append("drawing an area moved the map")
    }

    if failures.isEmpty {
        return log + "PASS: a drag becomes exactly the ground it was drawn over.\n"
    }
    return log + failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
}

// MARK: - A click made by a hand rather than a mouse

/// Check the tolerance that decides whether a press was a click or a drag,
/// against the distances a real input device actually produces.
///
/// This is the part that was wrong: `NSClickGestureRecognizer` fails on any
/// movement between press and release, a pen always moves, so every click on
/// the map was discarded and the map looked dead to a pen while working
/// perfectly for a mouse. What cannot be checked here is the events
/// themselves — AppKit does not deliver a synthesised tablet press to a
/// recognizer — so this checks the decision the recognizer makes about them.
@MainActor
func verifyForgivingClick() -> String {
    var log = "click tolerance: \(ForgivingClickRecognizer.slop)pt\n"
    var failures: [String] = []

    let origin = CGPoint(x: 300, y: 220)
    let cases: [(name: String, to: CGPoint, isAClick: Bool)] = [
        ("a mouse held perfectly still", origin, true),
        ("a pen with a point of tremor", CGPoint(x: 301, y: 221), true),
        ("a pen with three points of tremor", CGPoint(x: 303, y: 218), true),
        ("a pen held badly, five points", CGPoint(x: 304, y: 223), true),
        ("a shaky hand, right on the limit", CGPoint(x: 300 + 8, y: 220), true),
        ("a small but deliberate drag", CGPoint(x: 312, y: 220), false),
        ("a pan across the map", CGPoint(x: 460, y: 300), false),
        ("a pan straight up", CGPoint(x: 300, y: 90), false),
    ]

    for probe in cases {
        let decided = ForgivingClickRecognizer.isAClick(from: origin, to: probe.to)
        let distance = hypot(probe.to.x - origin.x, probe.to.y - origin.y)
        log += String(
            format: "  %-36@ %5.1fpt -> %@\n", probe.name as NSString, distance,
            decided ? "click" as NSString : "drag" as NSString
        )
        if decided != probe.isAClick {
            failures.append(
                "\(probe.name) (\(String(format: "%.1f", distance))pt) read as "
                + "\(decided ? "a click" : "a drag"), should be "
                + "\(probe.isAClick ? "a click" : "a drag")"
            )
        }
    }

    if failures.isEmpty {
        return log + "PASS: pen tremor is a click, a real drag is not.\n"
    }
    return log + failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
}

// MARK: - The zoom buttons

/// Press the real zoom buttons' real code — `LocatorHandle.zoom(by:)` — against
/// a real `MKMapView`, and check the map actually moved. The button itself, a
/// SwiftUI view in a floating window, is the part nobody here can press.
///
/// Checked: zooming in shows strictly less, zooming out shows strictly more,
/// the centre is held still, and in-then-out returns to where it started. What
/// this deliberately does *not* insist on is that the map land on exactly the
/// span asked for — MapKit clamps a region to what it can render at the view's
/// pixel size, which is a real constraint of the framework and not a fault to
/// assert away.
@MainActor
func verifyLocatorZoomButtons() -> String {
    let athens = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.9760, longitude: 23.7350),
        span: MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.32)
    )
    let coordinator = Locator.Coordinator(onRegionChanged: { _ in })
    let mapView = laidOutMap(coordinator, region: athens, size: CGSize(width: 700, height: 560))
    let handle = LocatorHandle()
    handle.adopt(mapView, coordinator: coordinator)

    func describe(_ label: String) -> String {
        let padded = label.padding(toLength: 24, withPad: " ", startingAt: 0)
        return "  " + padded + String(
            format: "%.5f, %.5f   %.5f° × %.5f°\n",
            mapView.region.center.latitude, mapView.region.center.longitude,
            mapView.region.span.latitudeDelta, mapView.region.span.longitudeDelta
        )
    }

    var log = "pressing the buttons' own code against a real 700×560 map\n"
    var failures: [String] = []

    let start = mapView.region.span.latitudeDelta
    log += describe("start")

    handle.zoom(by: 1.6)
    log += describe("after zoom in")
    let closer = mapView.region.span.latitudeDelta
    if closer >= start {
        failures.append("zoom in did not show less (\(start)° -> \(closer)°)")
    }
    if abs(mapView.region.center.latitude - athens.center.latitude) > 1e-4 {
        failures.append("zoom in moved the centre")
    }

    handle.zoom(by: 1 / 1.6)
    log += describe("after zoom out")
    let back = mapView.region.span.latitudeDelta
    if abs(back - start) > start * 0.02 {
        failures.append(String(format: "in then out did not return: %.5f° vs %.5f°", back, start))
    }

    for _ in 0..<6 { handle.zoom(by: 1 / 1.6) }
    log += describe("after six more out")
    let wide = mapView.region.span.latitudeDelta
    if wide <= back {
        failures.append("repeated zoom out stopped showing more")
    }

    for _ in 0..<20 { handle.zoom(by: 1 / 1.6) }
    log += describe("after twenty more out")
    // MapKit clamps to what it can draw; the check is that it stayed a real
    // region rather than overflowing into nonsense.
    if !(mapView.region.span.latitudeDelta > 0 && mapView.region.span.latitudeDelta <= 180) {
        failures.append("zooming out past the world left an impossible region")
    }

    handle.showWholeWorld()
    log += describe("after the globe button")

    for _ in 0..<30 { handle.zoom(by: 1.6) }
    log += describe("after thirty in")
    let tightest = mapView.region.span.latitudeDelta
    if tightest <= 0 {
        failures.append("zooming all the way in collapsed the region to nothing")
    }

    if failures.isEmpty {
        return log + "PASS: the buttons move the map, hold the centre, and stop at both ends.\n"
    }
    return log + failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n"
}
