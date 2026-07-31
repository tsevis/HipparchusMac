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
    @State private var model = MapModel()
    @State private var viewport = ViewportState()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The window's own undo manager, which puts ⌘Z and the Edit menu in charge
    /// of the model's history rather than inventing a parallel mechanism.
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // The status bar is a sibling of the split view rather than a
        // `safeAreaInset` on it: it spans all three columns, so it is a row of the
        // window rather than an inset of the split view, and a VStack says that
        // directly.
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                FramePanel(model: model)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
            } content: {
                map
                    .navigationSplitViewColumnWidth(min: 420, ideal: 720)
            } detail: {
                List {
                    SourcesPanel(model: model)
                    LayersPanel(model: model)
                    StylePicker(model: model)
                    DerivedPanel(model: model)
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
            model.startIfRequestedOnLaunch()
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
                onAreaDrawn: { model.setArea($0) }
            )

            zoomControls
                .padding(10)

            VStack {
                Spacer()
                // Direct manipulation needs saying once. It is a pill rather than a
                // panel because it should read as a caption on the map, not as
                // another piece of interface competing with it.
                Text("drag to pan · scroll to zoom · Option-drag to draw a new area")
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
            PlaceSearchField(model: model)
        }

        ToolbarItem(placement: .principal) {
            // Cancel appears beside Update map while a fetch runs — where the eye
            // already is — as well as in the status bar next to the progress.
            HStack(spacing: 8) {
                Button("Update map") { model.update() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isFetching || model.bbox == nil)
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
