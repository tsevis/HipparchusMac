import Foundation
import HipparchusGeometry

/// Thumbnails for the style picker.
///
/// Ported from `application/style_previews.py`.
///
/// Sixteen preset names in a dropdown ask you to remember what each one looks like.
/// A thumbnail does not.
///
/// Each swatch is drawn **from the preset itself** — its ground colour, its contour
/// styling, its water and road colours — so a preset cannot end up advertising a
/// look it no longer has. The subject is a small synthetic hill: enough contour
/// nesting to show weight, spacing and ground, small enough to redraw the whole
/// picker in a few milliseconds.
public enum StylePreviews {

    /// The picker shows a short, curated row rather than all sixteen: these span the
    /// looks the app can produce, and the rest stay reachable from the full list.
    public static let featured = [
        "Hypsometric Relief",
        "Contour Study",
        "Relief Sheet",
        "Night",
        "Clean Atlas",
        "Monochrome Figure Ground",
    ]

    /// Featured presets that actually exist, in order.
    public static var featuredNames: [String] {
        let available = Set(Presets.names)
        return featured.filter(available.contains)
    }

    /// A drawable description of one preset, in unit coordinates.
    public struct Swatch: Sendable, Equatable, Identifiable {
        public let name: String
        public let background: RGBAColor
        public let contourColor: RGBAColor
        public let contourWidths: [Double]
        public let accentColor: RGBAColor
        /// The hypsometric ramp, if the preset has one. Empty means it does not, and
        /// the swatch draws linework on bare ground — which is how it renders.
        public let bandColors: [RGBAColor]

        public var id: String { name }

        /// Whether the ground is dark enough that overlaid text needs to be light.
        public var isDark: Bool {
            let luminance = 0.2126 * Double(background.r)
                + 0.7152 * Double(background.g)
                + 0.0722 * Double(background.b)
            return luminance < 128
        }
    }

    /// Describe one preset as a swatch, reading its real styles.
    ///
    /// Every style is read through `StyleProfile.style(for:)` — the same accessor
    /// the scene builder uses — rather than straight out of the dictionary. It
    /// matters for presets that say nothing about contours, such as `Clean Atlas`
    /// and `Night`: the renderer draws those as a grey hairline, and a thumbnail
    /// reaching past the accessor would promise a solid dark line instead. The
    /// Python takes the dictionary route and shows the wrong thing for exactly
    /// those two.
    public static func swatch(for name: String, rings: Int = 5) -> Swatch {
        let styles = Presets.preset(name).styleProfile
        let contour = styles.style(for: "terrain_contours")
        let index = styles.layerStyles["terrain_index_contours"] ?? contour
        let accent = styles.layerStyles["water"] ?? styles.layerStyles["roads"] ?? LayerStyle()

        return Swatch(
            name: name,
            background: styles.background,
            contourColor: contour.strokeColor,
            contourWidths: ringWidths(contour: contour, index: index, rings: rings),
            accentColor: accent.fillEnabled ? accent.fillColor : accent.strokeColor,
            bandColors: bandColors(styles.layerStyles["elevation_bands"], rings: rings)
        )
    }

    public static func swatches(_ names: [String]? = nil) -> [Swatch] {
        (names ?? featuredNames).map { swatch(for: $0) }
    }

    /// One nested contour ring in unit coordinates, 0…1 on both axes.
    ///
    /// Deliberately not a circle: a lopsided ring with a shoulder reads as terrain,
    /// where concentric circles read as a target.
    public static func ringGeometry(index: Int, total: Int) -> [Coordinate] {
        let inset = 0.10 + 0.155 * Double(index)
        let points = (0..<40).map { step -> Coordinate in
            let angle = 2 * Double.pi * Double(step) / 40
            let wobble = 1.0
                + 0.16 * sin(angle * 2 + 0.6)
                + 0.07 * sin(angle * 3 + Double(index))
            let radius = Swift.max(0.02, (0.5 - inset) * wobble)
            return Coordinate(
                x: 0.5 + radius * cos(angle) * 1.18,
                y: 0.52 + radius * sin(angle) * 0.86
            )
        }
        // Closed by repeating the first point rather than by evaluating the angle
        // at 2π: `sin(2π)` is −2.4e-16, not 0, so that route leaves a gap of a few
        // hundred attometres which is nonetheless enough to make the ring open.
        return points + [points[0]]
    }

    /// Line weights per ring, with the index weight every other one.
    ///
    /// Presets that accent nothing come back uniform, which is exactly how they
    /// draw — so the picker shows the difference between a weighted sheet and a flat
    /// one without being told about it.
    static func ringWidths(contour: LayerStyle, index: LayerStyle, rings: Int) -> [Double] {
        let minor = Swift.max(0.3, contour.strokeWidth)
        let heavy = Swift.max(minor, index.strokeWidth)
        return (0..<Swift.max(1, rings)).map { $0 % 2 == 0 ? heavy : minor }
    }

    static func bandColors(_ style: LayerStyle?, rings: Int) -> [RGBAColor] {
        guard let style, style.fillEnabled, let high = style.fillColorHigh else { return [] }
        guard rings > 1 else { return [style.fillColor] }
        return (0..<rings).map { position in
            style.fillColor
                .mixed(towards: high, amount: Double(position) / Double(rings - 1))
                .withOpacity(1.0)
        }
    }
}
