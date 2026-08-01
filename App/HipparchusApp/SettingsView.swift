import HipparchusRender
import SwiftUI

/// Preferences, at ⌘, where macOS keeps them.
///
/// There has been a `settings.json` for a while — the cache ceiling, the rate
/// this asks shared services at — and no way to see or change it without a text
/// editor. A file the app reads and the user cannot reach is a setting in name
/// only.
///
/// Deliberately four rows. Everything describing *a map* is in the session and
/// everything describing *a style* is in a preset; what is left is a handful of
/// numbers about how the application behaves, which is exactly what the Python
/// keeps in the same file.
struct SettingsView: View {
    @Bindable var model: MapModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Cache ceiling") {
                    HStack(spacing: 6) {
                        TextField(
                            "Cache ceiling",
                            value: Binding(
                                get: { model.settings.cacheSizeLimitMB },
                                // Floored at one megabyte rather than trusted:
                                // a typed zero would mean "keep nothing".
                                set: { megabytes in
                                    model.updateSettings { $0.cacheSizeLimitMB = max(1, megabytes) }
                                }
                            ),
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 80)
                        Text("MB")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(model.cacheSummary.isEmpty ? "Nothing cached yet." : model.cacheSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button("Clear cache now") { model.clearCache() }
                    .controlSize(.small)
            } header: {
                Text("Cache")
            } footer: {
                Text("The oldest answers are dropped when the cache passes this. Fetching again is a network round trip, not a loss.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section {
                LabeledContent("Requests a second") {
                    HStack(spacing: 6) {
                        TextField(
                            "Requests a second",
                            value: Binding(
                                get: { model.settings.providerRPSLimit },
                                set: { rate in model.updateSettings { $0.providerRPSLimit = rate } }
                            ),
                            format: .number
                        )
                        .labelsHidden()
                        .frame(width: 80)
                        Text("/s")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Shared services")
            } footer: {
                Text("Overpass runs on donated hardware. One a second is its stated guidance; a source's own settings can still override this.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Where things are kept") {
                ForEach(model.storageLocations, id: \.label) { place in
                    LabeledContent(place.label) {
                        Button("Show") { model.reveal(place.url) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
