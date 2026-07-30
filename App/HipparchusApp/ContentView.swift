import AppKit
import HipparchusData
import HipparchusGeometry
import HipparchusRender
import SwiftUI
import UniformTypeIdentifiers

/// Deliberately plain.
///
/// The three-column `NavigationSplitView` from the Python's screenshots — the
/// sources stack, the derived layer list, the style thumbnails, the locator — is
/// the next slice. Building it now would be a lot of interface standing on one
/// data path, and this slice exists to prove that path end to end. What is here is
/// the minimum needed to look at the result of a real fetch and export it.
struct ContentView: View {
    @State private var model = MapModel()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            MapCanvas(scene: model.scene)
                .frame(minWidth: 480, minHeight: 360)
            Divider()
            statusBar
        }
        .frame(minWidth: 760, minHeight: 560)
        .task { model.fetchIfRequestedOnLaunch() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Area").foregroundStyle(.secondary)
                coordinateField("W", value: $model.west)
                coordinateField("S", value: $model.south)
                coordinateField("E", value: $model.east)
                coordinateField("N", value: $model.north)

                Picker("", selection: $model.placeName) {
                    Text("Saved places").tag("")
                    Divider()
                    ForEach(MapModel.places, id: \.name) { place in
                        Text(place.name).tag(place.name)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: model.placeName) { _, name in model.select(name) }

                Spacer()
            }

            HStack(spacing: 8) {
                Button("Update map") { model.fetch() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isFetching)

                Button("Cancel") { model.cancel() }
                    .disabled(!model.isFetching)

                Spacer()

                Button("Export SVG…") { model.exportSVG() }
                    .disabled(model.scene == nil)
                Button("Export PDF…") { model.exportPDF() }
                    .disabled(model.scene == nil)
            }
        }
        .padding(12)
    }

    private func coordinateField(_ label: String, value: Binding<String>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .labelsHidden()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isFetching {
                ProgressView().controlSize(.small)
            }
            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.isError ? .red : .primary)
                .textSelection(.enabled)
            Spacer()
            if let provenance = model.provenance {
                // Provenance is on screen for the same reason it is in the file: a
                // generated map must not be mistakable for a survey.
                Text(provenance)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: -

@MainActor
@Observable
final class MapModel {
    struct Place {
        let name: String
        let bbox: BoundingBox
    }

    static let places: [Place] = [
        Place(name: "Santorini", bbox: BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)),
        Place(name: "Athens", bbox: BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136)),
        Place(name: "San Francisco", bbox: BoundingBox(minLon: -122.53, minLat: 37.70, maxLon: -122.35, maxLat: 37.84)),
        Place(name: "Addis Ababa", bbox: BoundingBox(minLon: 38.65, minLat: 8.90, maxLon: 38.88, maxLat: 9.10)),
        Place(name: "Everest", bbox: BoundingBox(minLon: 86.85, minLat: 27.93, maxLon: 87.05, maxLat: 28.06)),
        Place(name: "Myrtoan Sea", bbox: BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)),
    ]

    var west = "25.32"
    var south = "36.33"
    var east = "25.50"
    var north = "36.48"
    var placeName = "Santorini"

    var scene: RenderScene?
    var status = "Pick an area and press Update map."
    var isError = false
    var isFetching = false
    var provenance: String?

    private var task: Task<Void, Never>?

    /// Open straight onto an area given on the command line:
    ///
    ///     Hipparchus.app/Contents/MacOS/Hipparchus --bbox 25.32,36.33,25.50,36.48
    ///
    /// Useful on its own — it is how you get from a coordinate in a notebook to a
    /// map without retyping four numbers — and it is the only way to check the
    /// window's own draw path without a human clicking the button, since driving
    /// the UI from a script needs accessibility permission this process has not
    /// been granted.
    func fetchIfRequestedOnLaunch() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--bbox"), flag + 1 < arguments.count else { return }
        let parts = arguments[flag + 1]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else {
            status = "--bbox needs four numbers: west,south,east,north"
            isError = true
            return
        }
        west = String(parts[0])
        south = String(parts[1])
        east = String(parts[2])
        north = String(parts[3])
        placeName = Self.places.first { place in
            place.bbox.minLon == parts[0] && place.bbox.minLat == parts[1]
                && place.bbox.maxLon == parts[2] && place.bbox.maxLat == parts[3]
        }?.name ?? ""
        fetch()
    }

    func select(_ name: String) {
        guard let place = Self.places.first(where: { $0.name == name }) else { return }
        west = String(place.bbox.minLon)
        south = String(place.bbox.minLat)
        east = String(place.bbox.maxLon)
        north = String(place.bbox.maxLat)
    }

    func fetch() {
        guard let bbox = parsedBBox() else {
            status = "Those coordinates do not make an area. West must be less than east, south less than north."
            isError = true
            return
        }

        task?.cancel()
        isFetching = true
        isError = false
        status = "Fetching elevation…"

        task = Task { [bbox] in
            do {
                let collection = try await TerrainTileProvider().fetch(BBoxQuery(bbox: bbox))
                let built = try SceneBuilder().build(from: collection)
                if Task.isCancelled { return }

                scene = built
                provenance = collection.provenance?.label
                let low = collection.metadata["elevation_min_metres"]?.doubleValue ?? .nan
                let high = collection.metadata["elevation_max_metres"]?.doubleValue ?? .nan
                let interval = collection.metadata["contour_interval_metres"]?.doubleValue ?? .nan
                status = String(
                    format: "%@ · %.0f m to %.0f m · %.0f m interval",
                    built.summary, low, high, interval
                )
            } catch is FetchCancelled {
                // Cancel cannot pull a request out of its socket. It skips sources
                // that have not started, stops those that check between requests,
                // and discards the result rather than drawing it. The map already on
                // screen stays.
                status = "Cancelled. The map on screen is the previous fetch."
            } catch {
                isError = true
                status = "\(error)"
            }
            isFetching = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    func exportSVG() {
        export(type: .svg, extension: "svg") { scene, url in
            _ = try SVGExporter().write(scene, to: url)
        }
    }

    func exportPDF() {
        export(type: .pdf, extension: "pdf") { scene, url in
            try PDFExporter().write(scene, to: url)
        }
    }

    // MARK: -

    private func parsedBBox() -> BoundingBox? {
        guard
            let west = Double(west.trimmingCharacters(in: .whitespaces)),
            let south = Double(south.trimmingCharacters(in: .whitespaces)),
            let east = Double(east.trimmingCharacters(in: .whitespaces)),
            let north = Double(north.trimmingCharacters(in: .whitespaces)),
            west < east, south < north,
            (-180...180).contains(west), (-180...180).contains(east),
            (-90...90).contains(south), (-90...90).contains(north)
        else {
            return nil
        }
        return BoundingBox(minLon: west, minLat: south, maxLon: east, maxLat: north)
    }

    private func export(
        type: UTType,
        extension suffix: String,
        write: (RenderScene, URL) throws -> Void
    ) {
        guard let scene else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(placeName.isEmpty ? "map" : placeName.lowercased()).\(suffix)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try write(scene, url)
            status = "Exported \(url.lastPathComponent)."
            isError = false
        } catch {
            isError = true
            status = "Export failed: \(error)"
        }
    }
}
