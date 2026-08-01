import HipparchusRender
import SwiftUI

/// Style, chosen by eye — **see it, don't read it**.
///
/// Sixteen preset names in a dropdown ask you to remember what each one looks like.
/// A thumbnail does not. Each swatch is drawn from the preset itself, so a preset
/// cannot advertise a look it no longer has.
struct StylePicker: View {
    @Bindable var model: MapModel
    @State private var isNamingPreset = false
    @State private var newPresetName = ""
    /// The style Delete is asking about. Non-nil raises the confirmation.
    @State private var presetToDelete: String?

    var body: some View {
        Section {
            // A grid that wraps, not a strip that scrolls.
            //
            // This section's whole claim is *see it, don't read it*, and a
            // horizontal strip in a sidebar this narrow showed four of sixteen
            // — so choosing meant scrolling back and forth comparing from
            // memory, which is reading by another name. Wrapping shows every
            // style at once and leaves nothing to navigate. `.adaptive` rather
            // than a fixed column count because the sidebar is resizable
            // between 260 and 380 points, and the right number of columns is
            // Four columns exactly, so the sixteen fall into a 4×4 block: a
            // grid that reads as a complete set rather than as a row that ran
            // out. All sixteen, not the six that used to be "featured" —
            // with nothing to scroll there is no reason to decide for someone
            // which looks they are allowed to see.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: 4),
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(StylePreviews.swatches(Presets.names)) { swatch in
                    SwatchButton(
                        swatch: swatch,
                        isSelected: model.preset.name == swatch.name
                    ) {
                        model.preset = model.namedPreset(swatch.name)
                    }
                }
            }
            .padding(.vertical, 2)

            // Still here, because a name is the faster way in when you already
            // know which one you want — and because plugin and saved styles
            // have no swatch of their own.
            Picker("All styles", selection: Binding(
                get: { model.preset.name },
                set: { model.preset = model.namedPreset($0) }
            )) {
                // Built-in, then anything plugins brought, then the user's own
                // — grouped, because "which of these can I delete?" is a
                // question the list should answer without being asked.
                ForEach(Presets.names, id: \.self) { name in
                    Text(name).tag(name)
                }
                if !model.pluginPresets.isEmpty {
                    Divider()
                    ForEach(model.pluginPresets.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                if !model.customPresets.isEmpty {
                    Divider()
                    ForEach(model.customPresets.map(\.name), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            .controlSize(.small)

            savedStyles

            Picker("Quality", selection: Binding(
                get: { model.quality.key },
                set: { model.quality = Quality.profile($0) }
            )) {
                ForEach(Quality.profiles) { profile in
                    Text(profile.label).tag(profile.key)
                }
            }
            .controlSize(.small)
            .help("A preset says what the map should look like; quality says how much work to spend getting there.")
        } header: {
            HStack {
                Text("Style")
                Spacer()
                Text("see it, don't read it")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Styles of your own

    /// Keeping a tuned style, and letting go of one.
    ///
    /// The sixteen built-in presets are code and cannot be edited. Everything
    /// the eye is actually for — nudging a colour, turning the illumination up
    /// — was previously lost at the next launch, which made the tuning pointless.
    @ViewBuilder
    private var savedStyles: some View {
        Button {
            // Seeded with the current style's name plus a suffix, because the
            // commonest save is a variation on the one being looked at.
            newPresetName = model.isCustomPreset(model.preset.name)
                ? model.preset.name
                : "\(model.preset.name) (mine)"
            isNamingPreset = true
        } label: {
            Label("Save this style…", systemImage: "square.and.arrow.down")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Keep the current style, with its derivation sizes, under a name of your own.")
        .alert("Save this style", isPresented: $isNamingPreset) {
            TextField("Name", text: $newPresetName)
            Button("Save") { model.saveCurrentStyleAsPreset(named: newPresetName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will appear in All styles, and in the Python app — the two share this file.")
        }

        if model.isCustomPreset(model.preset.name) {
            Button(role: .destructive) {
                presetToDelete = model.preset.name
            } label: {
                Label("Delete “\(model.preset.name)”", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            // Asked before, not regretted after. Deleting a saved style
            // rewrites `presets.json` — there is no undo for a file, and the
            // only copy of a style someone spent an evening tuning can go on
            // one stray click. A dialog is the cheapest thing that makes that
            // impossible.
            .confirmationDialog(
                "Delete the style “\(presetToDelete ?? "")”?",
                isPresented: Binding(
                    get: { presetToDelete != nil },
                    set: { if !$0 { presetToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let name = presetToDelete { model.deleteCustomPreset(named: name) }
                    presetToDelete = nil
                }
                Button("Cancel", role: .cancel) { presetToDelete = nil }
            } message: {
                Text("This removes it from presets.json. It cannot be undone.")
            }
        }

        if !model.loadedPlugins.isEmpty || !model.pluginLoadErrors.isEmpty {
            pluginSummary
        }
    }

    /// What loaded, and what did not. A plugin that failed silently is
    /// indistinguishable from one that was never installed.
    private var pluginSummary: some View {
        DisclosureGroup {
            ForEach(model.loadedPlugins) { plugin in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(plugin.name).font(.caption)
                        Text(plugin.origin)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            ForEach(model.pluginLoadErrors, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The folder is inside the sandbox container, which nobody is
            // going to find by hand — so the app opens it, and creates it the
            // first time so there is something to open.
            Button {
                model.revealPluginFolder()
            } label: {
                Label("Show plugins folder", systemImage: "folder")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        } label: {
            Text("Plugins (\(model.loadedPlugins.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SwatchButton: View {
    let swatch: StylePreviews.Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                SwatchView(swatch: swatch)
                    // 16:9 rather than nearly square: a map is a landscape,
                    // and a wide thumbnail of one carries more of its look in
                    // less height than a tall one does.
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: isSelected ? 2 : 0.5
                            )
                    }
                Text(shortName)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .help(swatch.name)
    }

    /// The row is narrow, so "Monochrome Figure Ground" becomes "Monochrome".
    private var shortName: String {
        swatch.name.split(separator: " ").first.map(String.init) ?? swatch.name
    }
}

/// One preset, drawn as a small synthetic hill.
///
/// Enough contour nesting to show weight, spacing and ground; small enough to redraw
/// the whole picker in a few milliseconds.
struct SwatchView: View {
    let swatch: StylePreviews.Swatch
    var rings = 5

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(swatch.background.color)
            )

            // Bands first: they are ground, and the lines describe the same terrain.
            // Painted outermost inward so each sits on top of the one below it.
            for index in (0..<rings).reversed() where index < swatch.bandColors.count {
                context.fill(path(for: index, in: size), with: .color(swatch.bandColors[index].color))
            }

            for index in 0..<rings {
                context.stroke(
                    path(for: index, in: size),
                    with: .color(swatch.contourColor.color),
                    lineWidth: max(0.5, swatch.contourWidths[min(index, swatch.contourWidths.count - 1)])
                )
            }
        }
    }

    private func path(for index: Int, in size: CGSize) -> Path {
        var path = Path()
        let points = StylePreviews.ringGeometry(index: index, total: rings)
        for (offset, point) in points.enumerated() {
            // Unit coordinates, y down — the swatch is drawn the way a window is.
            let location = CGPoint(x: point.x * size.width, y: point.y * size.height)
            if offset == 0 {
                path.move(to: location)
            } else {
                path.addLine(to: location)
            }
        }
        path.closeSubpath()
        return path
    }
}

extension RGBAColor {
    var color: Color {
        Color(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
