import CoreGraphics
import CoreText
import Foundation
import HipparchusGeometry

/// Draws a scene with Core Graphics.
///
/// Replaces the Python's skia renderer. Skia appeared in only three places there
/// and none of them needed a second rasteriser.
///
/// The same code draws into a window, into a bitmap for tests, and into a PDF
/// context: they are all `CGContext`. That is what makes "does it actually draw?"
/// answerable without a GUI — the Python could not test its render path at all,
/// and a UI edit once disabled rendering entirely while every test still passed.
public struct CoreGraphicsRenderer: Sendable {

    public struct Options: Sendable {
        public var drawBackground = true
        public var drawLabels = true
        /// **On by default**, and only ever drawn on a sheet carrying the sea.
        /// Off for the on-screen preview, where the canvas is not the artefact
        /// and the status bar is already saying what the map is made of.
        public var drawNotForNavigation = true
        /// Points. Summit heights are small type on a busy sheet.
        public var labelFontSize: Double = 9.0

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Draw the scene, and return the transform used so a caller can map clicks
    /// back to coordinates.
    @discardableResult
    public func draw(
        _ scene: RenderScene,
        in context: CGContext,
        size: CGSize,
        viewport: ViewportState = ViewportState()
    ) -> CanvasTransform? {
        if options.drawBackground {
            context.setFillColor(scene.background.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }

        guard let transform = CanvasTransform(contentBounds: scene.contentBounds, size: size, viewport: viewport) else {
            return nil
        }

        for layer in scene.visibleLayers {
            draw(layer: layer, in: context, transform: transform)
        }
        if options.drawLabels {
            for layer in scene.visibleLayers {
                drawLabels(of: layer, in: context, transform: transform)
            }
        }
        // The one thing this renderer draws that is not the map.
        //
        // Furniture is otherwise an SVG idea — the scale bar, the legend and the
        // title block all live in the exporter. This does not, because a PNG is
        // the artefact that actually gets shared, and a sheet that looks like a
        // chart in an SVG looks exactly as much like one as a picture.
        if options.drawNotForNavigation, NotForNavigation.applies(to: scene) {
            drawNotForNavigation(
                NotForNavigation.notice(for: scene),
                in: context, size: size, background: scene.background
            )
        }
        return transform
    }

    /// The notice, bottom centre, on a panel that keeps it legible over a dark
    /// sea or a busy coast.
    private func drawNotForNavigation(
        _ notice: String, in context: CGContext, size: CGSize, background: RGBAColor
    ) {
        let luminance = 0.2126 * Double(background.r)
            + 0.7152 * Double(background.g) + 0.0722 * Double(background.b)
        let dark = luminance < 128.0
        let ink = dark ? RGBAColor(242, 242, 242) : RGBAColor(34, 34, 34)
        let panel = dark ? RGBAColor(18, 21, 28) : RGBAColor(255, 255, 255)

        let short = min(size.width, size.height)
        let fontSize = max(9.0, short * 0.014)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attributed = CFAttributedStringCreate(
            nil, notice as CFString,
            [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: ink.cgColor,
            ] as CFDictionary
        )
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let padding = fontSize * 0.6
        let centre = CGPoint(x: size.width / 2, y: size.height - max(14.0, short * 0.026))

        context.saveGState()
        context.setFillColor(panel.withOpacity(0.82).cgColor)
        context.fill(CGRect(
            x: centre.x - bounds.width / 2 - padding,
            y: centre.y - bounds.height / 2 - padding * 0.6,
            width: bounds.width + padding * 2,
            height: bounds.height + padding * 1.2
        ))
        // Text draws in its own upright frame regardless of the canvas flip, the
        // same dance the labels do.
        context.translateBy(x: centre.x, y: centre.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Render to an image, for tests and for thumbnails.
    ///
    /// This is the headless half of the answer to "did the change break drawing?".
    /// **Rasterised once, at the size asked for, deliberately.**
    ///
    /// Drawing large and averaging down — the Python's `supersample`, and the
    /// obvious thing to reach for — makes these maps *worse*, and it was measured
    /// rather than assumed. On a Santorini sheet at `export_clean`, oversampling
    /// cost local contrast monotonically: 2.77 at 1×, 2.21 at 1.5×, 1.74 at 2×,
    /// while total ink fell with it. Contours on these sheets sit a pixel or two
    /// apart, so averaging merges neighbouring lines into a smear and lightens
    /// every hairline; Core Graphics antialiases against the real pixel grid and
    /// keeps each line's contrast instead. Type softens too.
    ///
    /// A synthetic measurement said the opposite, by scoring each candidate
    /// against a 4× downsample as though it were ground truth — but that
    /// reference *is* the smear, so it rewarded the blur it should have caught.
    /// The visual check settled it. See "What is not here" in the README.
    public func image(of scene: RenderScene, size: CGSize, viewport: ViewportState = ViewportState()) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return nil
        }
        // Core Graphics has a bottom-left origin; the transform assumes canvas y
        // grows downward, as a window does. Flip once, here.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        draw(scene, in: context, size: size, viewport: viewport)
        return context.makeImage()
    }

    // MARK: -

    private func draw(layer: RenderLayer, in context: CGContext, transform: CanvasTransform) {
        guard !layer.geometries.isEmpty else { return }
        let style = layer.style

        context.saveGState()
        context.setAlpha(style.opacity)
        context.setLineJoin(.round)
        context.setLineCap(style.lineCap == .round ? .round : .butt)

        // Casing first, so the road colour lands on top of it.
        if style.casingWidth > 0 {
            context.setStrokeColor(style.casingColor.cgColor)
            context.setLineWidth(style.casingWidth)
            for geometry in layer.geometries {
                guard let path = path(for: geometry, transform: transform) else { continue }
                context.addPath(path)
                context.strokePath()
            }
        }

        for (index, geometry) in layer.geometries.enumerated() {
            guard let path = path(for: geometry, transform: transform) else { continue }

            // `hasArea`, not just the style: a layer that fills may still hold open
            // lines, and filling one closes it with an invisible chord and paints
            // the wedge behind it.
            if style.fillEnabled, geometry.hasArea {
                context.setFillColor(layer.fillColor(at: index).cgColor)
                context.addPath(path)
                // Even-odd, so a hole in a band stays a hole.
                context.fillPath(using: .evenOdd)
            }

            let width = style.strokeWidth * layer.weight(at: index)
            if width > 0 && style.strokeColor.a > 0 {
                context.setStrokeColor(style.strokeColor.cgColor)
                context.setLineWidth(width)
                context.addPath(path)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    private func drawLabels(of layer: RenderLayer, in context: CGContext, transform: CanvasTransform) {
        guard !layer.labels.isEmpty else { return }
        let font = CTFontCreateWithName("HelveticaNeue" as CFString, options.labelFontSize, nil)

        for label in layer.labels where !label.name.isEmpty {
            let point = transform.worldToScreen(label.position)
            // CoreText's own attribute keys, not AppKit's: this target has to build
            // and draw with no UI framework so the CLI and the tests can use it.
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: layer.style.strokeColor.cgColor,
            ]
            let attributed = CFAttributedStringCreate(
                nil, label.name as CFString, attributes as CFDictionary
            )
            guard let attributed else { continue }
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [])

            context.saveGState()
            // Labels read the same transform as the geometry. In the Python they
            // did not, and a rotated map left every label behind.
            context.translateBy(x: point.x, y: point.y)
            if label.rotation != 0 {
                context.rotate(by: label.rotation * .pi / 180.0)
            }
            // Text draws in its own upright frame regardless of the canvas flip.
            context.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)

            // Halo behind, then text on top — two passes, not `fillStroke`.
            //
            // `fillStroke` strokes and fills the same glyphs, so half the halo lands
            // *over* the letters. At 2 pt around 9 pt type that swallowed them
            // whole: the first real render of Santorini showed the summit heights
            // as white blobs. Stroking first and filling second puts the halo where
            // a halo goes, and the width follows the font size rather than being an
            // absolute that only looks right at one scale.
            if layer.style.labelHaloWidth > 0 {
                context.saveGState()
                context.textPosition = origin
                context.setLineWidth(options.labelFontSize * 0.22)
                context.setLineJoin(.round)
                context.setStrokeColor(layer.style.labelHaloColor.cgColor)
                context.setTextDrawingMode(.stroke)
                CTLineDraw(line, context)
                context.restoreGState()
            }

            context.textPosition = origin
            context.setTextDrawingMode(.fill)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    /// Build a path for one geometry.
    ///
    /// **Every vertex is emitted.** Kickoff detail 9: cutting a vertex list short
    /// and jumping to the final vertex rules a chord straight across the shape, and
    /// seven of Santorini's contours exceed five thousand vertices. There is no
    /// vertex budget here, and there must not be one.
    func path(for geometry: Geometry, transform: CanvasTransform) -> CGPath? {
        let path = CGMutablePath()
        var wroteAnything = false

        func addLine(_ coordinates: [Coordinate], close: Bool) {
            guard coordinates.count >= 2 else { return }
            path.move(to: transform.worldToScreen(coordinates[0]))
            for coordinate in coordinates.dropFirst() {
                path.addLine(to: transform.worldToScreen(coordinate))
            }
            if close { path.closeSubpath() }
            wroteAnything = true
        }

        func addPolygon(_ polygon: Polygon) {
            addLine(polygon.exterior.coordinates, close: true)
            for hole in polygon.holes {
                addLine(hole.coordinates, close: true)
            }
        }

        func add(_ geometry: Geometry) {
            switch geometry {
            case .empty:
                break
            case .point(let coordinate):
                // A point needs an area to be visible at all; a half-point dot is
                // what the SVG exporter writes too, so the two agree.
                let screen = transform.worldToScreen(coordinate)
                path.addEllipse(in: CGRect(x: screen.x - 0.5, y: screen.y - 0.5, width: 1, height: 1))
                wroteAnything = true
            case .multiPoint(let coordinates):
                for coordinate in coordinates { add(.point(coordinate)) }
            case .lineString(let line):
                addLine(line.coordinates, close: false)
            case .multiLineString(let lines):
                for line in lines { addLine(line.coordinates, close: false) }
            case .polygon(let polygon):
                addPolygon(polygon)
            case .multiPolygon(let polygons):
                for polygon in polygons { addPolygon(polygon) }
            case .collection(let parts):
                for part in parts { add(part) }
            }
        }

        add(geometry)
        return wroteAnything ? path : nil
    }
}

extension RGBAColor {
    public var cgColor: CGColor {
        CGColor(
            srgbRed: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            alpha: Double(a) / 255.0
        )
    }
}
