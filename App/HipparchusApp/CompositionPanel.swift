import HipparchusRender
import SwiftUI

/// The page every export shares: paper, resolution, and the map furniture.
///
/// Paper used to govern the SVG alone — PNG was hardcoded to 2400 × 1800 and PDF
/// to A4 in points, whichever sheet was chosen here. One page spec now drives
/// all three, so a sheet asked for at 24 × 36 is that sheet in every format.
///
/// The Python keeps the furniture as checkboxes in its export options, transient
/// and all off by default, and this keeps both properties: the map is the
/// product, and a scale bar or a title block is asked for per export rather than
/// remembered as map state. Nothing here changes the map — which is why none of
/// it lands in the undo history or the session.
struct CompositionPanel: View {
    @Bindable var model: MapModel

    /// One edge of the custom sheet. Clamped on the way in rather than trusted:
    /// a sheet of zero is not a sheet, and one of a thousand inches is a bitmap
    /// nobody can allocate.
    private func inchField(_ label: String, _ value: Binding<Double>) -> some View {
        TextField(label, value: Binding(
            get: { value.wrappedValue },
            set: { typed in
                guard typed.isFinite else { return }
                let range = PageSpec.customInchRange
                value.wrappedValue = min(max(typed, range.lowerBound), range.upperBound)
            }
        ), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 54)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
    }

    /// What the current page comes to, so the cost of a 24 × 36 at 600 dpi is
    /// visible before the export refuses it rather than after.
    private var pageSummary: String {
        let canvas = MapModel.canvasExportPixels
        let pixels = model.page.pixelSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
        let cost = model.page.bitmapCost(canvasWidth: canvas.width, canvasHeight: canvas.height)
        let inches = model.page.inches(canvasAspect: 1)
        let sheet = inches.map { String(format: "%.3g × %.3g in · ", $0.width, $0.height) } ?? ""
        return String(format: "%@%d × %d px · %.0f MP", sheet, pixels.width, pixels.height, cost.megapixels)
    }

    var body: some View {
        Section {
            Picker("Paper", selection: $model.page.paperName) {
                ForEach(PaperSize.all, id: \.name) { paper in
                    if paper.isCanvas {
                        Text(paper.name).tag(paper.name)
                    } else {
                        Text(paper.name).tag(paper.name)
                    }
                }
            }
            // Only when Custom is chosen: two numbers say the sheet outright,
            // and with them any aspect at all — 5:3 for a world, say, which no
            // named sheet offers.
            if model.page.paper.isCustom {
                HStack(spacing: 6) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    inchField("Width", $model.page.customWidthInches)
                    Text("×")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    inchField("Height", $model.page.customHeightInches)
                    Text("in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Text("\(model.page.customAspectDescription) · orientation follows these numbers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Picker("Orientation", selection: $model.page.orientation) {
                ForEach(PageSpec.orientations, id: \.self) { orientation in
                    Text(orientation).tag(orientation)
                }
            }
            .disabled(model.page.paper.isCustom)
            Picker("Resolution", selection: $model.page.dpi) {
                ForEach(Resolution.all, id: \.self) { dpi in
                    Text(Resolution.label(dpi)).tag(dpi)
                }
            }
            HStack {
                Spacer()
                Text(pageSummary)
                    .font(.caption)
                    .foregroundStyle(
                        model.page.exceedsBitmapLimit(
                            canvasWidth: MapModel.canvasExportPixels.width,
                            canvasHeight: MapModel.canvasExportPixels.height
                        ) ? .red : .secondary
                    )
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
