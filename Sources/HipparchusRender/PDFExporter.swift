import CoreGraphics
import Foundation

/// PDF export, over the same renderer that draws the canvas.
///
/// Nearly free: a `CGPDFContext` is a `CGContext`, so the drawing code is the one
/// already in use and there is no second code path to keep in step with the first.
/// What you see on screen is what lands in the file, by construction.
///
/// SVG is still the primary format — it is what Illustrator opens with named,
/// editable layers. PDF is for printing and for handing to someone who does not
/// want to edit anything.
public struct PDFExporter: Sendable {

    public struct Options: Sendable {
        /// Points. A4 landscape by default; 1 pt = 1/72 inch.
        public var width: Double = 842
        public var height: Double = 595
        public var title = "Hipparchus map"

        public init() {}
    }

    public let options: Options
    private let renderer: CoreGraphicsRenderer

    public init(options: Options = Options(), renderer: CoreGraphicsRenderer = CoreGraphicsRenderer()) {
        self.options = options
        self.renderer = renderer
    }

    public func write(_ scene: RenderScene, to url: URL) throws {
        let size = CGSize(width: options.width, height: options.height)
        var mediaBox = CGRect(origin: .zero, size: size)

        var info: [CFString: Any] = [kCGPDFContextTitle: options.title]
        info[kCGPDFContextCreator] = "HipparchusMac"
        // Provenance follows the file here too. A printed map that cannot say
        // whether it was measured or generated is the thing this guards against.
        if let provenance = scene.metadata["provenance"]?.stringValue {
            info[kCGPDFContextSubject] = "provenance: \(provenance)"
        }

        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw PDFExportError.couldNotCreateContext(url)
        }

        context.beginPDFPage(nil)
        // PDF has a bottom-left origin; the canvas transform assumes y grows
        // downward. One flip, in the same place and for the same reason as in the
        // bitmap renderer.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        renderer.draw(scene, in: context, size: size)
        context.endPDFPage()
        context.closePDF()
    }
}

public enum PDFExportError: Error, CustomStringConvertible {
    case couldNotCreateContext(URL)

    public var description: String {
        switch self {
        case .couldNotCreateContext(let url):
            return "could not open \(url.path) for PDF output"
        }
    }
}
