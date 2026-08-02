import SwiftUI

/// The one button the whole window exists to have pressed.
///
/// `.borderedProminent` with a tint was the obvious way to do this and it was
/// not enough: macOS draws a *disabled* prominent button in system grey, losing
/// the tint entirely, and Render map is disabled for the whole length of a
/// fetch — which is exactly when someone is looking at it. The button appeared
/// grey often enough to read as never having been turquoise at all.
///
/// So the fill is painted here rather than asked for. Unavailable, it keeps its
/// colour and loses its strength: the same button, dimmed, rather than a
/// different grey button that happens to occupy the same place.
struct RenderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1.0 : 0.75))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.hipparchus)
                    .opacity(opacity(pressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func opacity(pressed: Bool) -> Double {
        guard isEnabled else { return 0.32 }
        return pressed ? 0.72 : 1.0
    }
}
