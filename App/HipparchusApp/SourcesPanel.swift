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

            // A file-backed source shows its file, and the way to choose one,
            // without being expanded first.
            //
            // Behind the chevron, the only control that makes the row usable
            // was invisible: four permanently greyed-out rows with no stated
            // reason and no visible way out read as four broken features. The
            // row is greyed because it has no file — so the row should say so,
            // where the greying is.
            if definition.needsPath {
                filePicker(for: definition)
                    .padding(.leading, 22)
            }

            if expanded.contains(definition.id) {
                inlineSettings(for: definition, settings: settings)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 2)
        // The label dims to say "not ready", but the control that fixes that
        // must not dim with it — a faded button reads as a disabled one.
        .opacity(isAvailable ? 1 : 0.55)
    }

    /// The chosen file, why it is or is not usable, and the way to change it.
    private func filePicker(for definition: SourceDefinition) -> some View {
        let status = model.stack.fileStatus(definition.id)
        let path = model.stack.path(definition.id)

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(path.isEmpty ? "No file chosen" : (path as NSString).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(path.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // The reason, when there is one worth giving. GeoParquet's
                // answer carries the command that converts it — computed all
                // along, and until now shown nowhere, which left the one
                // format this cannot read looking like a format it silently
                // ignored.
                if let status, !status.isAvailable, !path.isEmpty {
                    Text(status.detail)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Button(path.isEmpty ? "Choose…" : "Change…") { chooseFile(for: definition) }
                .controlSize(.small)
                // Never dimmed with the row: this is the control that undims it.
                .opacity(1)
        }
    }

    @ViewBuilder
    private func inlineSettings(
        for definition: SourceDefinition,
        settings: [SourceSetting]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
        // Directories too, because two of the formats genuinely are one: a
        // shapefile is a set of sidecar files that travel together, and a
        // converted extract usually arrives as a folder of GeoJSON, one file
        // per layer. `FileFormat.of` has always understood both; the picker
        // simply would not let anyone choose one.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the file or folder for \(definition.label)."
        panel.prompt = "Use"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Minted here, while the open panel's grant is still held — this is
        // the only moment a token for this file can be made. Without it the
        // path is readable this run and refused after a relaunch.
        model.stack.setPath(
            definition.id, url.path, bookmark: SecurityScopedAccess.bookmark(for: url)
        )
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
