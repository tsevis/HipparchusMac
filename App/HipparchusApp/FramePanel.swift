import HipparchusGeometry
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
    /// Opens the Locator in its own window. Handed in rather than done here
    /// because the panel is owned by `ContentView`, which keeps it alive
    /// between openings — the same window comes back, still showing wherever
    /// it was left.
    var openLocator: () -> Void
    @State private var showsCoordinates = false

    var body: some View {
        VStack(spacing: 0) {
            // Outside the list on purpose: a `List` on macOS owns a real
            // `NSScrollView`, which competes with `MKMapView`'s own pan and
            // magnify recognizers for the same mouse-down-drag and scroll
            // events — a map row that looks right but never actually pans
            // or zooms. A plain sibling view has no scroll view to compete with.
            //
            // No `.clipShape`/`.overlay` here either, for the same reason:
            // both add a SwiftUI view stacked on top of the real `MKMapView`,
            // and a stroked shape's hit-testing is its full frame, not just
            // the painted line — exactly the kind of thing that would eat
            // every click and scroll before the map ever saw them. The
            // rounding lives on the map's own layer instead, in `makeNSView`.
            Locator(
                bbox: model.bbox, isSettled: model.didFinishLaunchSetup,
                onRegionChanged: { model.browseWorldMap(to: $0) }
            )
            .frame(height: 220)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .help("Drag to pan, scroll or pinch to zoom. The area shown becomes the area Render map fetches.")

            // The same map icon the toolbar uses, so the two ways to the same
            // window look like the same thing. Here as well as up there because
            // this is where the eye already is when the strip is too small to
            // aim at — which is the moment the bigger window is wanted.
            Button(action: openLocator) {
                Label("Open bigger map", systemImage: "map")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Open the Locator in its own floating window, big enough to click a place on")

            list
        }
    }

    private var list: some View {
        List {
            Section("Frame") {
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
                ForEach(SavedPlaces.groups(featured: model.availablePlaces)) { group in
                    PlaceMenu(model: model, group: group)
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

/// One saved-places group as a menu, its subgroups as nested menus — which is
/// how AppKit draws a cascade. Two hundred countries are a wall as a list and
/// unremarkable as six continents, so the depth is the whole point.
///
/// A view rather than a `@ViewBuilder` method because the recursion has to go
/// through a type the compiler already knows: an opaque `some View` returned by
/// a function that calls itself would be defined in terms of itself, which is
/// an error. `AnyView` at the recursion point is what breaks that circle.
private struct PlaceMenu: View {
    let model: MapModel
    let group: PlaceGroup

    var body: some View {
        Menu(group.name) {
            ForEach(group.places) { place in
                Button {
                    model.choose(name: place.name, bbox: place.bbox)
                } label: {
                    if place.name == model.placeName {
                        Label(title(for: place), systemImage: "checkmark")
                    } else {
                        Text(title(for: place))
                    }
                }
            }
            ForEach(group.subgroups) { subgroup in
                AnyView(PlaceMenu(model: model, group: subgroup))
            }
        }
    }

    /// The place and how wide it is. A menu item is one run of text — there is
    /// no second column to hang the width off, the way the flat list had — so
    /// the two are joined and the width carries its own degree sign to say what
    /// it is. Which one is current is the checkmark's job, not the title's.
    private func title(for place: MapModel.Place) -> String {
        "\(place.name) — \(Self.width(place.bbox.lonSpan))"
    }

    /// Places run from the Vatican's 0.04° to the whole world's 360°, and a fixed
    /// two decimals across that range spends its precision where there is none
    /// to report: "360.00°" is three characters of noise. Narrow it as the
    /// number grows.
    private static func width(_ lonSpan: Double) -> String {
        let degrees = abs(lonSpan)
        let decimals = degrees >= 100 ? 0 : (degrees >= 10 ? 1 : 2)
        return String(format: "%.\(decimals)f°", degrees)
    }
}
