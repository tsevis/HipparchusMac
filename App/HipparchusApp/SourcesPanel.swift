import HipparchusData
import SwiftUI

/// The sources stack: **stack, don't replace**.
///
/// The single most important idea in the design. Ticking Elevation onto a street map
/// adds contours; it never discards the streets. Each source carries its own
/// settings inline behind a disclosure, because the knobs that most change the
/// output belong beside the source they belong to.
///
/// File-backed sources sit behind a further disclosure: four always-visible cards
/// for the minority case pushed everything else off the panel.
struct SourcesPanel: View {
    @Bindable var model: MapModel
    @State private var expanded: Set<String> = []
    @State private var showsFileBacked = false

    var body: some View {
        Section {
            ForEach(onlineSources) { definition in
                row(for: definition)
            }

            DisclosureGroup("File-backed sources", isExpanded: $showsFileBacked) {
                ForEach(fileBackedSources) { definition in
                    row(for: definition)
                }
            }
            .font(.subheadline)
        } header: {
            HStack {
                Text("Sources")
                Spacer()
                Text("stack, don't replace")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var onlineSources: [SourceDefinition] {
        model.stack.definitions.filter { !$0.needsPath }
    }

    private var fileBackedSources: [SourceDefinition] {
        model.stack.definitions.filter(\.needsPath)
    }

    // MARK: -

    @ViewBuilder
    private func row(for definition: SourceDefinition) -> some View {
        let settings = model.stack.settings(for: definition.id)
        let isAvailable = model.stack.isAvailable(definition.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { model.stack.isEnabled(definition.id) },
                    set: { model.stack.setEnabled(definition.id, $0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(definition.label)
                            .fontWeight(.medium)
                        Text(definition.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                // A source needing a file cannot be ticked until one is chosen. It
                // stays listed rather than hidden, so the stack shows the whole menu.
                .disabled(!isAvailable)

                Spacer(minLength: 4)

                ProvenanceBadge(provenance: definition.provenance)

                if !settings.isEmpty || definition.needsPath {
                    Button {
                        if expanded.contains(definition.id) {
                            expanded.remove(definition.id)
                        } else {
                            expanded.insert(definition.id)
                        }
                    } label: {
                        Image(systemName: expanded.contains(definition.id) ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }

            if expanded.contains(definition.id) {
                inlineSettings(for: definition, settings: settings)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
        .opacity(isAvailable ? 1 : 0.55)
    }

    @ViewBuilder
    private func inlineSettings(
        for definition: SourceDefinition,
        settings: [SourceSetting]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if definition.needsPath {
                HStack(spacing: 6) {
                    Text(model.stack.path(definition.id).isEmpty
                        ? "No file chosen"
                        : (model.stack.path(definition.id) as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseFile(for: definition) }
                        .controlSize(.small)
                }
            }

            ForEach(settings) { setting in
                HStack(spacing: 6) {
                    Text(setting.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 62, alignment: .leading)

                    switch setting.kind {
                    case .number:
                        numberField(definition: definition, setting: setting)
                    case .choice:
                        choiceField(definition: definition, setting: setting)
                    }
                }
            }
        }
    }

    private func numberField(definition: SourceDefinition, setting: SourceSetting) -> some View {
        HStack(spacing: 4) {
            TextField(setting.label, text: Binding(
                get: {
                    switch setting.value {
                    case .integer(let value): String(value)
                    case .number(let value): value == value.rounded() ? String(Int(value)) : String(value)
                    case .text(let value): value
                    }
                },
                set: { text in
                    guard let number = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
                    // Keep the declared shape: a band count is an integer and a
                    // magnitude floor is not, and round-tripping through Double
                    // would show "10.0 bands".
                    if case .integer = setting.value {
                        model.stack.setSetting(definition.id, setting.key, .integer(Int(number)))
                    } else {
                        model.stack.setSetting(definition.id, setting.key, .number(number))
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 70)

            if !setting.suffix.isEmpty {
                Text(setting.suffix)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func choiceField(definition: SourceDefinition, setting: SourceSetting) -> some View {
        Picker(setting.label, selection: Binding(
            get: { setting.value.stringValue ?? "" },
            set: { model.stack.setSetting(definition.id, setting.key, .text($0)) }
        )) {
            ForEach(setting.choices.compactMap(\.stringValue), id: \.self) { choice in
                Text(choice).tag(choice)
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func chooseFile(for definition: SourceDefinition) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.stack.setPath(definition.id, url.path)
    }
}

/// What a source is, said plainly beside it.
///
/// Provenance is load-bearing: it is what stops a generated map being mistaken for a
/// survey. It is on screen for the same reason it is in the exported file.
struct ProvenanceBadge: View {
    let provenance: SourceProvenance

    var body: some View {
        Text(provenance.rawValue)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch provenance {
        case .live: .blue
        case .measured: .green
        case .synthetic: .purple
        case .uncalibrated: .orange
        case .approximate: .teal
        }
    }
}
