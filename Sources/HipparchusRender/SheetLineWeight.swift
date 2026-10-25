import Foundation

/// Line weights and type that keep their look on a bigger sheet.
///
/// A preset's widths are pixels on the 1600 × 1200 canvas they were drawn on, and
/// nothing scaled them to the sheet: a print at 24 × 36 and 300 dpi drew the same
/// three-pixel road across 7,200 pixels instead of 1,600, and every line on it
/// came out a hairline. A file bigger than that canvas now draws the same picture
/// enlarged.
///
/// Applied per file, at the size that file is written in, and never to the
/// window, which draws at whatever size it is dragged to.
extension RenderScene {

    /// The canvas a preset's line weights are stated for.
    public static let referenceSheet = (width: 1600.0, height: 1200.0)

    /// How much wider lines draw on a sheet of this size, in that sheet's own
    /// units: pixels for a bitmap or an SVG, points for a PDF.
    ///
    /// The square root of the area ratio, so a sheet of another shape is weighed
    /// by its size rather than by whichever edge happens to be longer.
    public static func sheetLineScale(width: Double, height: Double) -> Double {
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return 1.0 }
        let ratio = ((width * height) / (referenceSheet.width * referenceSheet.height)).squareRoot()
        // Never below one: a sheet fitted inside the reference is the very canvas
        // the preset was drawn on, and drawing it thinner would undo the preset.
        return max(1.0, ratio)
    }

    /// This scene with its line weights and its labels scaled for a sheet of
    /// this size.
    public func scaledForSheet(width: Double, height: Double) -> RenderScene {
        let scale = Self.sheetLineScale(width: width, height: height)
        var sheet = scalingLineWeights(by: scale)
        sheet.labelScale = labelScale * scale
        return sheet
    }
}
