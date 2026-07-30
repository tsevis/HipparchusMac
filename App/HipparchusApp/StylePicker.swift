import HipparchusRender
import SwiftUI

/// Style, chosen by eye — **see it, don't read it**.
///
/// Sixteen preset names in a dropdown ask you to remember what each one looks like.
/// A thumbnail does not. Each swatch is drawn from the preset itself, so a preset
/// cannot advertise a look it no longer has.
struct StylePicker: View {
    @Bindable var model: MapModel

    var body: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StylePreviews.swatches()) { swatch in
                        SwatchButton(
                            swatch: swatch,
                            isSelected: model.preset.name == swatch.name
                        ) {
                            model.preset = Presets.preset(swatch.name)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            // The featured row spans the looks the app can produce; the rest stay
            // reachable rather than hidden.
            Picker("All styles", selection: Binding(
                get: { model.preset.name },
                set: { model.preset = Presets.preset($0) }
            )) {
                ForEach(Presets.names, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .controlSize(.small)

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
}

private struct SwatchButton: View {
    let swatch: StylePreviews.Swatch
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                SwatchView(swatch: swatch)
                    .frame(width: 62, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isSelected ? 2 : 0.5
                            )
                    }
                Text(shortName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 66)
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
