import Foundation

/// How big the exported sheet actually is, in inches on paper.
///
/// **No Python counterpart.** There, and here until now, paper was a table of
/// *pixel* sizes — "A4" meant 2480 × 3508 because that is A4 at 300 dpi, and the
/// number 300 appeared nowhere. That works exactly as long as nobody wants a
/// different resolution, and it left the other two exporters with no notion of
/// physical size at all: PNG was hardcoded to 2400 × 1800 and PDF to A4 in
/// points, whatever the page controls said.
///
/// Saying it in inches instead makes one description serve all three. Pixels are
/// inches × dpi for the bitmap, points are inches × 72 for the PDF, and SVG
/// keeps taking pixels because that is what an SVG viewport is. A sheet asked
/// for at 24 × 36 is the same sheet in every format, which is the whole point of
/// having a page size rather than a canvas size.
public struct PaperSize: Sendable, Equatable {
    public let name: String
    /// Portrait: the long edge is the height. `orientation` turns the sheet.
    public let widthInches: Double
    public let heightInches: Double

    public init(name: String, widthInches: Double, heightInches: Double) {
        self.name = name
        self.widthInches = widthInches
        self.heightInches = heightInches
    }

    /// The sheet that means "keep whatever size the canvas already was".
    public static let canvas = PaperSize(name: "Canvas", widthInches: 0, heightInches: 0)
    public var isCanvas: Bool { widthInches <= 0 || heightInches <= 0 }

    /// The sheet whose size the reader states outright.
    ///
    /// **The named sheets are all document and poster proportions**, and a map
    /// is not always either: a whole earth wants 2:1, and someone framing one
    /// may want 5:3. Rather than guess at more names, this one carries whatever
    /// two numbers `PageSpec` is holding — so an aspect is expressible exactly,
    /// and the same two numbers decide the pixels once the resolution is
    /// applied.
    public static let customName = "Custom"
    /// A placeholder so the name resolves and appears in the picker; the real
    /// dimensions come from `PageSpec.customWidthInches`/`customHeightInches`.
    ///
    /// Declared portrait like every other sheet here, even though nothing reads
    /// these numbers — the invariant is what lets `orientation` turn a sheet
    /// without asking which way it was written down, and an exception to it
    /// would be a trap for the next sheet added rather than a saving here.
    public static let customPlaceholder = PaperSize(name: customName, widthInches: 12, heightInches: 20)
    public var isCustom: Bool { name == Self.customName }

    /// The offered sheets. ISO and US paper for documents, then the three sizes
    /// people actually frame — the last is the 24 × 36 that a print shop treats
    /// as a standard poster.
    public static let all: [PaperSize] = [
        canvas,
        customPlaceholder,
        PaperSize(name: "Square", widthInches: 20, heightInches: 20),
        PaperSize(name: "A4", widthInches: 8.268, heightInches: 11.693),
        PaperSize(name: "A3", widthInches: 11.693, heightInches: 16.535),
        PaperSize(name: "A2", widthInches: 16.535, heightInches: 23.386),
        PaperSize(name: "Letter", widthInches: 8.5, heightInches: 11),
        PaperSize(name: "Tabloid", widthInches: 11, heightInches: 17),
        PaperSize(name: "12 × 18 in", widthInches: 12, heightInches: 18),
        PaperSize(name: "18 × 24 in", widthInches: 18, heightInches: 24),
        PaperSize(name: "24 × 36 in", widthInches: 24, heightInches: 36),
    ]

    public static let names: [String] = all.map(\.name)

    /// An unknown name behaves as Canvas rather than as a zero-size page — the
    /// same rule the SVG composition already used, kept because a preset or a
    /// restored session can name a sheet a later build has renamed.
    public static func named(_ name: String) -> PaperSize {
        all.first { $0.name == name } ?? canvas
    }
}

/// The resolutions offered, and what each is for.
///
/// Not a free number: a text field invites 1200 dpi on a 24 × 36 sheet, which is
/// 1.2 gigapixels and several minutes of drawing before it fails.
public enum Resolution {
    public static let all: [Double] = [72, 150, 300, 600]
    public static let `default`: Double = 300

    public static func label(_ dpi: Double) -> String {
        switch dpi {
        case 72: return "72 dpi · screen"
        case 150: return "150 dpi · proof"
        case 300: return "300 dpi · print"
        case 600: return "600 dpi · fine"
        default: return "\(Int(dpi)) dpi"
        }
    }
}

/// A page: a sheet, which way up, and how finely to draw it.
public struct PageSpec: Sendable, Equatable {
    public var paperName: String
    public var orientation: String
    public var dpi: Double
    /// The Custom sheet's two numbers, in inches. Read only when `paperName` is
    /// `PaperSize.customName`, and kept while another sheet is selected so
    /// coming back to Custom finds what was last typed.
    public var customWidthInches: Double
    public var customHeightInches: Double

    public static let orientations = ["Landscape", "Portrait"]

    /// The smallest and largest a custom edge may be. A sheet of zero is not a
    /// sheet, and one of a thousand inches is a bitmap nobody can allocate —
    /// the resolution picker is deliberately not a free number for the same
    /// reason, and this is the other half of that.
    public static let customInchRange = 1.0...200.0

    public init(
        paperName: String = PaperSize.canvas.name,
        orientation: String = "Landscape",
        dpi: Double = Resolution.default,
        customWidthInches: Double = 20,
        customHeightInches: Double = 12
    ) {
        self.paperName = paperName
        self.orientation = orientation
        self.dpi = dpi
        self.customWidthInches = customWidthInches
        self.customHeightInches = customHeightInches
    }

    public var paper: PaperSize {
        let named = PaperSize.named(paperName)
        guard named.isCustom else { return named }
        let range = Self.customInchRange
        return PaperSize(
            name: PaperSize.customName,
            widthInches: Swift.min(Swift.max(customWidthInches, range.lowerBound), range.upperBound),
            heightInches: Swift.min(Swift.max(customHeightInches, range.lowerBound), range.upperBound)
        )
    }

    /// The custom sheet's proportions, said the way someone asks for them.
    public var customAspectDescription: String {
        let width = customWidthInches, height = customHeightInches
        guard width > 0, height > 0 else { return "—" }
        return String(format: "%.3g:1", width / height)
    }

    /// The sheet in inches, turned to the chosen orientation.
    ///
    /// The orientation turns the *sheet*, not the map — the same rule the SVG
    /// composition has always used, so a landscape A4 is 11.7 × 8.3 rather than a
    /// rotated drawing.
    public func inches(canvasAspect: Double) -> (width: Double, height: Double)? {
        let paper = self.paper
        guard !paper.isCanvas else { return nil }
        var width = paper.widthInches
        var height = paper.heightInches
        // A custom sheet states its own orientation: the two numbers *are* the
        // request, and turning them would quietly refuse what was typed.
        guard !paper.isCustom else { return (width, height) }
        if orientation == "Landscape", height > width {
            swap(&width, &height)
        } else if orientation == "Portrait", width > height {
            swap(&width, &height)
        }
        _ = canvasAspect
        return (width, height)
    }

    /// Pixels, for a bitmap. Canvas falls back to the size the caller had.
    public func pixelSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        guard let inches = inches(canvasAspect: Double(canvasWidth) / Double(max(1, canvasHeight))) else {
            return (Swift.max(1, canvasWidth), Swift.max(1, canvasHeight))
        }
        let resolution = Swift.max(1.0, dpi)
        return (
            Swift.max(1, Int((inches.width * resolution).rounded())),
            Swift.max(1, Int((inches.height * resolution).rounded()))
        )
    }

    /// PostScript points, for a PDF. 72 to the inch, by definition — so a PDF
    /// carries the physical size rather than a resolution, and prints at the
    /// requested dimensions on any device.
    public func pointSize(canvasWidth: Int, canvasHeight: Int) -> (width: Double, height: Double) {
        guard let inches = inches(canvasAspect: Double(canvasWidth) / Double(max(1, canvasHeight))) else {
            // A canvas-sized PDF is the canvas read as 96 dpi CSS pixels, which
            // is what turns a 2400-pixel canvas into a sensible 25-inch sheet
            // instead of a 33-foot one.
            return (Double(Swift.max(1, canvasWidth)) * 72.0 / 96.0,
                    Double(Swift.max(1, canvasHeight)) * 72.0 / 96.0)
        }
        return (inches.width * 72.0, inches.height * 72.0)
    }

    /// What a bitmap of this page would cost, before drawing it.
    ///
    /// A 24 × 36 sheet at 600 dpi is 311 megapixels and 1.2 GB of premultiplied
    /// RGBA. Core Graphics does not fail politely at that size — it returns a nil
    /// context, and the export reports "could not render" for what is really a
    /// request nobody could satisfy. Measuring first means the refusal can say
    /// what it actually costs.
    public func bitmapCost(canvasWidth: Int, canvasHeight: Int) -> (megapixels: Double, megabytes: Double) {
        let size = pixelSize(canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        let pixels = Double(size.width) * Double(size.height)
        return (pixels / 1_000_000.0, pixels * 4.0 / 1_000_000.0)
    }

    /// The ceiling a bitmap export refuses past. Chosen so 24 × 36 at 300 dpi —
    /// the sheet this feature exists for, at 78 megapixels — is comfortably
    /// inside it, and 600 dpi on the same sheet is not.
    public static let maximumMegapixels = 120.0

    public func exceedsBitmapLimit(canvasWidth: Int, canvasHeight: Int) -> Bool {
        bitmapCost(canvasWidth: canvasWidth, canvasHeight: canvasHeight).megapixels > Self.maximumMegapixels
    }
}

extension PageSpec {
    /// Two inch numbers, said the way someone types them: `20x12`, `5:3`,
    /// `20,12`. Nil if that is not what the text is.
    ///
    /// Lives here rather than in the command line tool because the tool cannot
    /// be imported by a test — and the rule for reading a sheet is worth
    /// testing on its own, separately from whatever asked for one.
    public static func customInches(parsing text: String) -> (width: Double, height: Double)? {
        let parts = text.lowercased().split(whereSeparator: { $0 == "x" || $0 == ":" || $0 == "," })
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width > 0, height > 0
        else { return nil }
        return (width: width, height: height)
    }

    /// The same page, on a sheet of exactly these inches. A copy rather than a
    /// mutation, so the caller's page is still the page they had.
    public func settingCustomSize(widthInches: Double, heightInches: Double) -> PageSpec {
        var page = self
        page.paperName = PaperSize.customName
        page.customWidthInches = widthInches
        page.customHeightInches = heightInches
        return page
    }
}
