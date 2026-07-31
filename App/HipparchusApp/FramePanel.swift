import HipparchusGeometry
import MapKit
import SwiftUI

/// The frame: where you are, and where you might go instead.
///
/// The Python drew a graticule with no coastline because it had no data to hand,
/// and needed four coordinate boxes and eight nudge buttons to describe a frame
/// it never showed. MapKit does it properly, which makes the nudge buttons
/// unnecessary and lets the coordinates sit one disclosure away — and, because
/// it is a real, live map rather than a static indicator, it can be the way an
/// area is chosen in the first place, before anything has ever been fetched and
/// the main canvas has nothing yet to draw a selection on top of.
struct FramePanel: View {
    @Bindable var model: MapModel
    @State private var showsCoordinates = false

    var body: some View {
        List {
            Section("Frame") {
                Locator(bbox: model.bbox, onRegionChanged: { model.browseWorldMap(to: $0) })
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
                    .help("Drag to pan, scroll or pinch to zoom. The area shown becomes the area Update map fetches.")

                Text(model.areaDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)

                DisclosureGroup("Edit coordinates", isExpanded: $showsCoordinates) {
                    coordinate("North", $model.north)
                    coordinate("South", $model.south)
                    coordinate("West", $model.west)
                    coordinate("East", $model.east)

                    Button {
                        showsCoordinates = true
                        model.importCoordinates()
                    } label: {
                        Label("Paste Coordinates", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(
                        "Reads the clipboard for a bounding box (west, south, east, "
                        + "north — the same order as this app's own --bbox), two "
                        + "corners, a single point, or a Google or Apple Maps link."
                    )
                }
                .font(.subheadline)
            }

            Section("Saved places") {
                ForEach(MapModel.places) { place in
                    Button {
                        model.select(place.name)
                    } label: {
                        HStack {
                            Text(place.name)
                            Spacer()
                            if model.placeName == place.name {
                                Text("current")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(String(format: "%.2f°", abs(place.bbox.lonSpan)))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func coordinate(_ label: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.trailing)
                .frame(width: 82)
                .labelsHidden()
        }
    }
}

/// The world, to browse and to mark.
///
/// A real, live `MKMapView` — interactive, not a static indicator — because it
/// is the one place an area can be chosen by *looking at the actual world*
/// rather than by naming it or typing four numbers: before anything has ever
/// been fetched the main canvas is blank, with no basemap of its own to draw a
/// selection on top of.
///
/// Two directions have to agree without fighting each other. Panning or
/// zooming here calls `onRegionChanged`, which becomes the requested area —
/// but the requested area can also change from elsewhere entirely (typing
/// coordinates, a search result, a saved place, Option-drag on the main
/// canvas), and this has to move to show that too. `Coordinator` is what keeps
/// the two from turning into a ping-pong: a region this view is *told* to show
/// is marked before it is set, and the delegate callback that same `setRegion`
/// triggers checks that mark and does not report it back as if the user had
/// just panned there.
private struct Locator: NSViewRepresentable {
    let bbox: BoundingBox?
    var onRegionChanged: (BoundingBox) -> Void

    /// South of the poles' worst MapKit projection distortion, wide enough to
    /// read as "the whole world" rather than any particular place.
    private static let wholeWorld = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 170, longitudeDelta: 360)
    )

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.isZoomEnabled = true
        view.isScrollEnabled = true
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.pointOfInterestFilter = .excludingAll
        view.delegate = context.coordinator

        // Always the whole world to start, whatever area is already requested
        // — this is a place to go looking, not a mirror of the main canvas.
        context.coordinator.isSettingRegionProgrammatically = true
        view.setRegion(Self.wholeWorld, animated: false)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.onRegionChanged = onRegionChanged

        view.removeOverlays(view.overlays)
        guard let bbox else { return }

        let corners = [
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLon),
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.minLon),
        ]
        view.addOverlay(MKPolygon(coordinates: corners, count: corners.count))

        // The first call lands immediately after makeNSView, with whatever
        // area was already requested — often not the default Santorini, since
        // a restored session or --bbox sets it before this view ever appears.
        // Reacting to it here would overwrite the whole-world start on the
        // very first frame.
        guard context.coordinator.hasSyncedOnce else {
            context.coordinator.hasSyncedOnce = true
            return
        }

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

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onRegionChanged: (BoundingBox) -> Void
        var isSettingRegionProgrammatically = false
        var hasSyncedOnce = false

        init(onRegionChanged: @escaping (BoundingBox) -> Void) {
            self.onRegionChanged = onRegionChanged
        }

        /// Close enough that the difference is rounding, not a real move —
        /// about a metre, far tighter than anything a pan or zoom gesture
        /// could land on by coincidence.
        func isAlreadyShowing(_ bbox: BoundingBox, on mapView: MKMapView) -> Bool {
            let shown = BoundingBox(mapView.region)
            let tolerance = 1e-5
            return abs(shown.minLon - bbox.minLon) < tolerance
                && abs(shown.minLat - bbox.minLat) < tolerance
                && abs(shown.maxLon - bbox.maxLon) < tolerance
                && abs(shown.maxLat - bbox.maxLat) < tolerance
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isSettingRegionProgrammatically else {
                isSettingRegionProgrammatically = false
                return
            }
            onRegionChanged(BoundingBox(mapView.region))
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

// MARK: - Bridging MapKit's region shape to this app's own

private extension BoundingBox {
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

private extension MKCoordinateRegion {
    init(_ bbox: BoundingBox) {
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (bbox.minLat + bbox.maxLat) / 2, longitude: (bbox.minLon + bbox.maxLon) / 2
            ),
            span: MKCoordinateSpan(latitudeDelta: abs(bbox.latSpan), longitudeDelta: abs(bbox.lonSpan))
        )
    }
}

// MARK: - Verifying what nobody can drag

/// Exists for the same reason `--search` does: nobody can drag this map in a
/// screenshot-less environment. Drives the real `Coordinator` and a real
/// `MKMapView` directly — not a re-implementation of either — establishing a
/// programmatic starting region exactly as `makeNSView` does, then simulating
/// what a finished pan or zoom gesture leaves behind: `MapKit` itself calling
/// `setRegion` and then firing the delegate, which is indistinguishable from
/// this at the `Coordinator`'s level. The interesting part — the conversion
/// math, and whether the loop-avoidance flag correctly tells "the app moved
/// this" from "the user moved this" apart — is fully exercised; the one thing
/// this does not test is whether `MapKit` calls the delegate after a real
/// drag, which is core, ubiquitous framework behaviour that does not need
/// re-proving here.
/// A single-threaded, entirely synchronous collector: `setRegion` fires the
/// delegate synchronously on the calling thread throughout, so the
/// `@unchecked` is not papering over anything genuinely concurrent.
private final class VerificationResult: @unchecked Sendable {
    var bbox: BoundingBox?
}

func verifyLocatorRegionConversion(
    centerLat: Double, centerLon: Double, latSpan: Double, lonSpan: Double
) -> String {
    let result = VerificationResult()
    let coordinator = Locator.Coordinator(onRegionChanged: { result.bbox = $0 })
    let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 300, height: 220))
    mapView.delegate = coordinator

    // `setRegion` fires `regionDidChangeAnimated` on its own, synchronously,
    // even for a view with no window — exactly as it does for the real
    // `Locator`, which is why neither this nor `makeNSView`/`updateNSView`
    // ever calls the delegate method directly.
    coordinator.isSettingRegionProgrammatically = true
    mapView.setRegion(Locator.wholeWorldForVerification, animated: false)
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

extension Locator {
    static var wholeWorldForVerification: MKCoordinateRegion { wholeWorld }
}
