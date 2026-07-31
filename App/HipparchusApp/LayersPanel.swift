import HipparchusRender
import SwiftUI

/// Layers in this map — derived from what was actually fetched.
///
/// Not a fixed checklist. The rows come from the scene that was built, grouped, with
/// counts, and a layer that found nothing says "none here" rather than sitting there
/// ticked and blank. That is what makes an empty map explain itself.
struct LayersPanel: View {
    @Bindable var model: MapModel

    var body: some View {
        Section {
            if model.layerRows.isEmpty {
                Text("Nothing fetched yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.layerRows, id: \.group) { group in
                if model.layerRows.count > 1 {
                    Text(group.group)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                ForEach(group.rows) { row in
                    LayerRow(row: row, model: model)
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Layers in this map")
                Spacer(minLength: 4)
                // A sheet is usually built by turning most of the map off and a
                // few layers back on, which is a lot of clicks from a full
                // fetch. Both skip the empty layers — there is nothing in them
                // to show, which is why their rows are disabled.
                Button("All") { model.setAllLayers(visible: true) }
                    .help("Show every layer that has something in it")
                Button("None") { model.setAllLayers(visible: false) }
                    .help("Hide every layer that has something in it")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.hasToggleableLayers)
        }
    }
}

private struct LayerRow: View {
    let row: LayerInventory.Entry
    @Bindable var model: MapModel

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { !model.hiddenLayers.contains(row.layerID) },
                set: { _ in model.toggleLayer(row.layerID) }
            )) {
                Text(row.label)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            // A layer with nothing in it cannot be shown or hidden — there is
            // nothing to show. Greying it says so without an explanation.
            .disabled(!row.hasData)

            Spacer(minLength: 4)

            Text(row.countText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(row.hasData ? .secondary : .tertiary)
        }
        .opacity(row.hasData ? 1 : 0.5)
        .help(row.isLabels ? "\(row.countText) labels" : "\(row.countText) features")
    }
}
