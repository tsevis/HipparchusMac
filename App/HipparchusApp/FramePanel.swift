import HipparchusGeometry
import MapKit
import SwiftUI

/// The frame: where you are, and where you might go instead.
///
/// A locator answers "where am I?" at a glance. The Python drew a graticule with no
/// coastline because it had no data to hand, and needed four coordinate boxes and
/// eight nudge buttons to describe a frame it never showed. MapKit does it properly,
/// which makes the nudge buttons unnecessary and lets the coordinates sit one
/// disclosure away.
struct FramePanel: View {
    @Bindable var model: MapModel
    @State private var showsCoordinates = false

    var body: some View {
        List {
            Section("Frame") {
                Locator(bbox: model.bbox)
                    .frame(height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }

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

/// The area marked on the world.
///
/// Non-interactive on purpose: this answers "where am I?", and a locator you can
/// accidentally scroll has stopped answering it.
private struct Locator: NSViewRepresentable {
    let bbox: BoundingBox?

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.isZoomEnabled = false
        view.isScrollEnabled = false
        view.isRotateEnabled = false
        view.isPitchEnabled = false
        view.showsCompass = false
        view.pointOfInterestFilter = .excludingAll
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        view.removeOverlays(view.overlays)
        guard let bbox else { return }

        let centre = CLLocationCoordinate2D(
            latitude: (bbox.minLat + bbox.maxLat) / 2,
            longitude: (bbox.minLon + bbox.maxLon) / 2
        )
        // Pulled well back: the point is to say *where in the world*, so the frame
        // has to be a mark on a recognisable region rather than filling the view.
        let span = MKCoordinateSpan(
            latitudeDelta: max(abs(bbox.latSpan) * 12, 6),
            longitudeDelta: max(abs(bbox.lonSpan) * 12, 6)
        )
        view.setRegion(MKCoordinateRegion(center: centre, span: span), animated: false)

        let corners = [
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.minLon),
            CLLocationCoordinate2D(latitude: bbox.minLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.maxLon),
            CLLocationCoordinate2D(latitude: bbox.maxLat, longitude: bbox.minLon),
        ]
        view.addOverlay(MKPolygon(coordinates: corners, count: corners.count))
        view.delegate = context.coordinator
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
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
