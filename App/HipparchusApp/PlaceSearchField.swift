import SwiftUI

/// The search box: type a place, get a frame.
///
/// From the design, top-left of the toolbar — a magnifier, the name of wherever you
/// are, and a chevron for the saved places. It is the first thing on screen because
/// it is the first thing anyone does.
struct PlaceSearchField: View {
    @Bindable var model: MapModel
    @State private var showsResults = false
    /// Owned by the window rather than here, so ⌘F — Search for a Place — has
    /// somewhere to put the cursor.
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Search for a place", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    model.searchForPlace()
                    showsResults = true
                }
                .onChange(of: model.searchQuery) { _, _ in
                    // Typing invalidates whatever was on screen, but does not
                    // search: that waits for Return.
                    if model.searchQuery.isEmpty { model.clearSearch() }
                }

            if model.isSearching {
                ProgressView().controlSize(.mini)
            } else if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                    model.clearSearch()
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }

            Divider().frame(height: 14)

            savedPlaces
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5)
        }
        .frame(minWidth: 240, idealWidth: 300)
        .onChange(of: model.searchResults) { _, results in
            showsResults = !results.isEmpty || model.searchMessage != nil
        }
        .popover(isPresented: $showsResults, arrowEdge: .bottom) {
            results
        }
    }

    private var savedPlaces: some View {
        Menu {
            ForEach(MapModel.places) { place in
                Button(place.name) {
                    model.select(place.name)
                    model.searchQuery = place.name
                    model.clearSearch()
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Saved places")
    }

    @ViewBuilder
    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = model.searchMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            ForEach(model.searchResults) { result in
                Button {
                    model.adopt(result)
                    showsResults = false
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.name)
                        HStack(spacing: 6) {
                            if !result.detail.isEmpty {
                                Text(result.detail)
                            }
                            // What the frame will be, before committing to it: a
                            // search that would fetch half a country is worth
                            // seeing before Render map is pressed.
                            Text(String(
                                format: "%.2f° × %.2f°",
                                abs(result.bbox.lonSpan), abs(result.bbox.latSpan)
                            ))
                            .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 300)
        .padding(.vertical, 4)
    }
}
