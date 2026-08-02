import SwiftUI

/// A slider with a number beside it you can type into.
///
/// A slider alone can express "about one and a bit" and cannot express 1.25. It
/// is the right control for finding a value by eye and the wrong one for saying
/// a value you already know — and both of those happen: you drag until the
/// sheet looks right, then you want the same weight on the next sheet, and
/// dragging to the same place is a game rather than a setting.
///
/// So the field is not a readout with an editable pretence. Typing into it and
/// pressing return moves the slider; dragging the slider retypes the field;
/// leaving the field with something unparseable in it puts the real value back
/// rather than guessing what was meant.
///
/// Written once here rather than at the one call site, because there will be a
/// second slider — sun bearing and relief stretch are asking for it — and a
/// control that behaves differently in two places is worse than either
/// behaviour.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// What the reset button goes back to.
    let defaultValue: Double
    var suffix = ""
    var decimals = 2
    var help = ""

    @State private var text = ""
    @FocusState private var editing: Bool

    private var formatted: String { String(format: "%.\(decimals)f", value) }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Slider(value: $value, in: range)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
                .frame(width: 54)
                .focused($editing)
                .onSubmit(commit)
                // Clicking away is as much a commit as pressing return; leaving
                // a typed number uncommitted because the mouse moved first is
                // the thing that makes a field like this feel broken.
                .onChange(of: editing) { _, focused in
                    if !focused { commit() }
                }
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                value = defaultValue
                text = formatted
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(value == defaultValue)
            .help("Back to \(String(format: "%.\(decimals)f", defaultValue))\(suffix)")
        }
        .controlSize(.small)
        .help(help)
        .onAppear { text = formatted }
        // Not while typing: rewriting the field under the cursor turns "1.2"
        // into "1.20" halfway through entering 1.25.
        .onChange(of: value) { _, _ in
            if !editing { text = formatted }
        }
    }

    /// Read what was typed, or put back what was there.
    private func commit() {
        // A comma is a decimal point in most of Europe, and a typed "1.16×" is
        // someone copying the label back in. Both are obvious in intent, so
        // both are accepted rather than rejected on a technicality.
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let parsed = Double(cleaned), parsed.isFinite else {
            text = formatted
            return
        }
        value = Swift.min(Swift.max(parsed, range.lowerBound), range.upperBound)
        // Rewritten from the clamped value, so typing 9 into a 4× maximum shows
        // 4.00 rather than leaving 9 on screen next to a slider at its end.
        text = formatted
    }
}
