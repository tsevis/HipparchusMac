import HipparchusRender
import SwiftUI

/// Page composition for the SVG export: paper, margins and map furniture.
///
/// The Python keeps these as checkboxes in its export options, transient and all
/// off by default, and this keeps both properties: the map is the product, and a
/// scale bar or a title block is asked for per export rather than remembered as
/// map state. Nothing here changes the map — which is why none of it lands in
/// the undo history or the session.
struct CompositionPanel: View {
    @Bindable var model: MapModel

    var body: some View {
        Section {
            Picker("Paper", selection: $model.svgComposition.paperPreset) {
                ForEach(SVGExporter.Composition.paperPresets, id: \.name) { preset in
                    if preset.width > 0 {
                        Text("\(preset.name) · \(preset.width)×\(preset.height)").tag(preset.name)
                    } else {
                        Text(preset.name).tag(preset.name)
                    }
                }
            }
            Picker("Orientation", selection: $model.svgComposition.orientation) {
                ForEach(SVGExporter.Composition.orientations, id: \.self) { orientation in
                    Text(orientation).tag(orientation)
                }
            }

            Toggle("Title block", isOn: $model.svgComposition.includeTitle)
                .toggleStyle(.checkbox)
            if model.svgComposition.includeTitle {
                TextField("Title", text: $model.svgComposition.title)
                TextField("Subtitle", text: $model.svgComposition.subtitle)
            }

            Toggle("Scale bar", isOn: $model.svgComposition.includeScaleBar)
                .toggleStyle(.checkbox)
                .help("A bar of known ground length, labelled in the projection's own units.")
            Toggle("North arrow", isOn: $model.svgComposition.includeNorthArrow)
                .toggleStyle(.checkbox)
            Toggle("Legend", isOn: $model.svgComposition.includeLegend)
                .toggleStyle(.checkbox)
                .help("The first ten visible layers, named as the layer panel names them.")
            Toggle("Background", isOn: $model.svgIncludeBackground)
                .toggleStyle(.checkbox)
                .help("Off exports a transparent SVG for compositing over other artwork. Dark presets need it on to be legible.")
        } header: {
            HStack {
                Text("Page")
                Spacer()
                Text("SVG export")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
