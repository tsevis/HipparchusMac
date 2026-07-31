import CoreGraphics
import Foundation
import HipparchusData
import HipparchusGeometry

/// Clean, layered SVG export.
///
/// Ported from `src/hipparchus/export/svg_clean.py` and
/// `rendering/geometry_adapter.py`.
///
/// The output is the product, so it is built for Illustrator rather than for a
/// browser: one named `<g>` per layer, in draw order, holding plain `M`/`L`/`Z`
/// paths. Named groups become named layers on import, which is the whole point —
/// a map you cannot take apart is a picture, not a drawing.
public struct SVGExporter: Sendable {

    /// Map furniture and page composition. Ported from `MapComposition` in
    /// `export/profiles.py`.
    ///
    /// **Everything is off by default**, matching the Python: the map is the
    /// product, and furniture is asked for. The paper preset and orientation are
    /// declarations for whatever opens the file, not instructions to this
    /// exporter — the SVG is composed for them, never resized by them.
    public struct Composition: Codable, Sendable, Equatable {
        public var title = ""
        public var subtitle = ""
        public var includeTitle = false
        public var includeScaleBar = false
        public var includeNorthArrow = false
        public var includeLegend = false
        /// Fraction of the page kept clear around the furniture, clamped to
        /// 0.02…0.18 when used.
        public var marginRatio = 0.06
        public var paperPreset = "Canvas"
        public var orientation = "Landscape"

        public init() {}

        public var wantsAnything: Bool {
            (includeTitle && !(title.isEmpty && subtitle.isEmpty))
                || includeScaleBar || includeNorthArrow || includeLegend
        }

        /// The paper sizes the export dialog offers, in pixels — A4 and A3 at
        /// 300 dpi. Ported from the Python's `PAPER_PRESETS`; "Canvas" means
        /// whatever size the caller was already using.
        public static let paperPresets: [(name: String, width: Int, height: Int)] = [
            ("Canvas", 0, 0),
            ("Square 2048", 2048, 2048),
            ("A4", 2480, 3508),
            ("A3", 3508, 4961),
            ("Poster", 5400, 7200),
        ]

        public static let orientations = ["Landscape", "Portrait"]

        /// The pixel size this composition asks the export to be. The orientation
        /// turns the sheet, not the map, so it swaps the axes; an unknown preset
        /// behaves as Canvas rather than as a zero-size page.
        public func exportSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
            let preset = Self.paperPresets.first { $0.name == paperPreset }
            var width = preset?.width ?? 0
            var height = preset?.height ?? 0
            if width <= 0 || height <= 0 {
                width = max(1024, canvasWidth)
                height = max(1024, canvasHeight)
            }
            if orientation == "Landscape", height > width {
                swap(&width, &height)
            } else if orientation == "Portrait", width > height {
                swap(&width, &height)
            }
            return (width, height)
        }
    }

    public struct Options: Sendable {
        public var width = 4096
        public var height = 4096
        /// Decimal places. Five is about a centimetre at Web Mercator scale, and
        /// more only inflates the file.
        public var precision = 5
        /// Paint the ground. Without it a dark preset exports pale strokes onto a
        /// transparent canvas, which reads as blank on white paper.
        public var includeBackground = true
        public var composition = Composition()

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func svg(for scene: RenderScene) -> String {
        let size = CGSize(width: Double(options.width), height: Double(options.height))
        let transform = CanvasTransform(contentBounds: scene.contentBounds, size: size)

        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\""
        out += " width=\"\(options.width)\" height=\"\(options.height)\""
        out += " viewBox=\"0 0 \(options.width) \(options.height)\""
        // Provenance travels with the file. A generated map that is separated from
        // its diagnostics must still be able to say what it is.
        for (key, value) in dataAttributes(for: scene).sorted(by: { $0.key < $1.key }) {
            out += " \(key)=\"\(escape(value))\""
        }
        out += ">\n"

        if options.includeBackground {
            out += "  <rect id=\"map_background\" x=\"0\" y=\"0\""
            out += " width=\"\(options.width)\" height=\"\(options.height)\""
            out += " fill=\"\(scene.background.hex)\""
            out += " opacity=\"\(format(Double(scene.background.a) / 255.0))\"/>\n"
        }

        out += "  <g id=\"map_layers\">\n"
        for layer in scene.layers {
            out += group(for: layer, transform: transform)
        }
        out += "  </g>\n"
        out += furniture(for: scene, transform: transform)
        out += "</svg>\n"
        return out
    }

    public func write(_ scene: RenderScene, to url: URL) throws -> ExportDiagnostics {
        try svg(for: scene).write(to: url, atomically: true, encoding: .utf8)
        return diagnostics(for: scene, format: "svg")
    }

    // MARK: -

    private func group(for layer: RenderLayer, transform: CanvasTransform?) -> String {
        let identifier = svgID(layer.name)
        var out = "    <g id=\"\(identifier)\" data-layer-name=\"\(escape(layer.name))\""
        if layer.style.opacity != 1.0 {
            out += " opacity=\"\(format(layer.style.opacity))\""
        }
        if !layer.style.visible {
            // Kept rather than dropped: an unticked layer is still part of the map,
            // and hiding it in the file lets it be switched back on in Illustrator.
            out += " display=\"none\""
        }
        out += ">\n"

        guard let transform else {
            return out + "    </g>\n"
        }

        let style = layer.style
        let stroke = style.strokeColor.hex

        if style.casingWidth > 0 && !layer.geometries.isEmpty {
            out += "      <g id=\"\(identifier)_casing\">\n"
            for geometry in layer.geometries {
                for data in pathData(for: geometry, transform: transform) {
                    out += "        <path d=\"\(data)\" fill=\"none\" stroke=\"\(style.casingColor.hex)\""
                    out += " stroke-width=\"\(format(style.casingWidth))\" vector-effect=\"non-scaling-stroke\""
                    out += " stroke-linejoin=\"round\" stroke-linecap=\"round\"/>\n"
                }
            }
            out += "      </g>\n"
        }

        for (index, geometry) in layer.geometries.enumerated() {
            // Per-path width and fill, read from the arrays that were built in
            // lockstep with the geometry.
            let width = style.strokeWidth * layer.weight(at: index)
            // `hasArea`, not just the style: a layer that fills may still hold open
            // lines, and an editor filling one closes it with an invisible chord.
            let isFilled = style.fillEnabled && geometry.hasArea
            let fill = isFilled ? layer.fillColor(at: index).hex : "none"

            for data in pathData(for: geometry, transform: transform) {
                out += "      <path d=\"\(data)\" fill=\"\(fill)\""
                if isFilled {
                    // Even-odd, so a hole in an elevation band stays a hole.
                    out += " fill-rule=\"evenodd\""
                }
                if width > 0 && style.strokeColor.a > 0 {
                    out += " stroke=\"\(stroke)\" stroke-width=\"\(format(width))\""
                    out += " vector-effect=\"non-scaling-stroke\""
                    out += " stroke-linejoin=\"round\" stroke-linecap=\"\(style.lineCap.rawValue)\""
                } else {
                    out += " stroke=\"none\""
                }
                out += "/>\n"
            }
        }

        // Each label is a halo/text pair, as the Python exports it: the halo is
        // the same string stroked wide in the ground colour behind the fill text,
        // which is what keeps a street name legible over the linework it sits on.
        for label in layer.labels where !label.name.isEmpty {
            let point = transform.worldToScreen(label.position)
            var shared = "x=\"\(format(point.x))\" y=\"\(format(point.y))\""
            shared += " font-family=\"Arial, Helvetica, sans-serif\" font-size=\"12\""
            shared += " text-anchor=\"middle\" dominant-baseline=\"central\""
            if label.rotation != 0 {
                shared += " transform=\"rotate(\(format(label.rotation)) \(format(point.x)) \(format(point.y)))\""
            }
            let name = escape(label.name)
            let halo = style.labelHaloColor.hex
            out += "      <text \(shared) fill=\"\(halo)\" stroke=\"\(halo)\""
            out += " stroke-width=\"\(format(style.labelHaloWidth))\" stroke-linejoin=\"round\">\(name)</text>\n"
            out += "      <text \(shared) fill=\"\(style.strokeColor.hex)\" stroke=\"none\">\(name)</text>\n"
        }

        return out + "    </g>\n"
    }

    // MARK: - Furniture

    /// Title, north arrow, scale bar and legend, ported from
    /// `_add_composition_furniture`. Drawn after the map so they sit above it,
    /// and inverted on a dark ground so they do not vanish into it.
    private func furniture(for scene: RenderScene, transform: CanvasTransform?) -> String {
        let composition = options.composition
        guard composition.wantsAnything else { return "" }

        let width = Double(options.width)
        let height = Double(options.height)
        let short = min(width, height)
        let margin = max(18.0, short * min(0.18, max(0.02, composition.marginRatio)))

        // Rec. 709 luminance on the 0–255 scale decides which way to invert.
        let background = scene.background
        let luminance = 0.2126 * Double(background.r)
            + 0.7152 * Double(background.g) + 0.0722 * Double(background.b)
        let darkGround = luminance < 128.0
        let text = darkGround ? "#f2f2f2" : "#222222"
        let halo = darkGround ? "#101010" : "#ffffff"
        let panelFill = darkGround ? "#12151c" : "#ffffff"
        let panelStroke = darkGround ? "#3a4050" : "#d0d0d0"
        let subtitleColor = darkGround ? "#b8bdc9" : "#555555"

        var out = "  <g id=\"map_furniture\">\n"

        if composition.includeTitle, !(composition.title.isEmpty && composition.subtitle.isEmpty) {
            out += "    <g id=\"map_title\">\n"
            var titleY = margin
            if !composition.title.isEmpty {
                out += "      <text x=\"\(format(margin))\" y=\"\(format(titleY))\""
                out += " font-family=\"Arial, Helvetica, sans-serif\""
                out += " font-size=\"\(format(max(18.0, short * 0.028)))\" font-weight=\"700\""
                out += " fill=\"\(text)\">\(escape(composition.title))</text>\n"
                titleY += max(18.0, short * 0.032)
            }
            if !composition.subtitle.isEmpty {
                out += "      <text x=\"\(format(margin))\" y=\"\(format(titleY))\""
                out += " font-family=\"Arial, Helvetica, sans-serif\""
                out += " font-size=\"\(format(max(11.0, short * 0.015)))\""
                out += " fill=\"\(subtitleColor)\">\(escape(composition.subtitle))</text>\n"
            }
            out += "    </g>\n"
        }

        if composition.includeNorthArrow {
            let size = max(36.0, short * 0.055)
            let cx = width - margin - size * 0.5
            let cy = margin + size * 0.55
            let points = [
                (cx, cy - size * 0.55),
                (cx - size * 0.22, cy + size * 0.28),
                (cx, cy + size * 0.12),
                (cx + size * 0.22, cy + size * 0.28),
            ]
            out += "    <g id=\"north_arrow\">\n"
            out += "      <polygon points=\""
            out += points.map { "\(format($0.0)),\(format($0.1))" }.joined(separator: " ")
            out += "\" fill=\"\(text)\" stroke=\"\(halo)\""
            out += " stroke-width=\"\(format(max(1.0, size * 0.035)))\" stroke-linejoin=\"round\"/>\n"
            out += "      <text x=\"\(format(cx))\" y=\"\(format(cy + size * 0.62))\""
            out += " font-family=\"Arial, Helvetica, sans-serif\""
            out += " font-size=\"\(format(max(10.0, size * 0.24)))\" font-weight=\"700\""
            out += " text-anchor=\"middle\" fill=\"\(text)\">N</text>\n"
            out += "    </g>\n"
        }

        if composition.includeScaleBar, let transform {
            // The bar is drawn a round number of pixels long and *labelled* with
            // the ground distance it happens to span, not the other way round —
            // the label is derived from the transform, so it cannot lie.
            let barPx = max(90.0, short * 0.18)
            let worldDistance = barPx / max(transform.fitScale, 1e-9)
            let label = Self.formatDistance(worldDistance, renderCRS: scene.projection.renderCRS)
            let x = margin
            let y = height - margin
            out += "    <g id=\"scale_bar\">\n"
            out += "      <rect x=\"\(format(x - 6))\" y=\"\(format(y - 28))\""
            out += " width=\"\(format(barPx + 12))\" height=\"38\" fill=\"\(panelFill)\" opacity=\"0.78\"/>\n"
            out += "      <line x1=\"\(format(x))\" y1=\"\(format(y))\" x2=\"\(format(x + barPx))\""
            out += " y2=\"\(format(y))\" stroke=\"\(text)\" stroke-width=\"3\"/>\n"
            out += "      <line x1=\"\(format(x))\" y1=\"\(format(y - 8))\" x2=\"\(format(x))\""
            out += " y2=\"\(format(y + 8))\" stroke=\"\(text)\" stroke-width=\"2\"/>\n"
            out += "      <line x1=\"\(format(x + barPx))\" y1=\"\(format(y - 8))\" x2=\"\(format(x + barPx))\""
            out += " y2=\"\(format(y + 8))\" stroke=\"\(text)\" stroke-width=\"2\"/>\n"
            out += "      <text x=\"\(format(x + barPx * 0.5))\" y=\"\(format(y - 12))\""
            out += " font-family=\"Arial, Helvetica, sans-serif\" font-size=\"12\""
            out += " text-anchor=\"middle\" fill=\"\(text)\">\(escape(label))</text>\n"
            out += "    </g>\n"
        }

        if composition.includeLegend {
            // The first ten visible layers with anything in them. The legend
            // names them what the layer panel names them — one vocabulary; the
            // Python keeps a second map in `svg_clean.py` that differs from its
            // panel in casing, and carrying that fork over would port a bug.
            let layers = scene.layers
                .filter { $0.style.visible && (!$0.geometries.isEmpty || !$0.labels.isEmpty) }
                .prefix(10)
            if !layers.isEmpty {
                let rowHeight = 20.0
                let legendWidth = min(260.0, width * 0.32)
                let legendHeight = 22.0 + rowHeight * Double(layers.count)
                let x = width - margin - legendWidth
                let y = height - margin - legendHeight
                out += "    <g id=\"map_legend\">\n"
                out += "      <rect x=\"\(format(x))\" y=\"\(format(y))\""
                out += " width=\"\(format(legendWidth))\" height=\"\(format(legendHeight))\""
                out += " fill=\"\(panelFill)\" opacity=\"0.84\" stroke=\"\(panelStroke)\"/>\n"
                for (index, layer) in layers.enumerated() {
                    let rowY = y + 18.0 + rowHeight * Double(index)
                    let stroke = layer.style.strokeColor.hex
                    let fill = layer.style.fillEnabled ? layer.style.fillColor.hex : "none"
                    out += "      <rect x=\"\(format(x + 12))\" y=\"\(format(rowY - 10))\""
                    out += " width=\"18\" height=\"10\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"1\"/>\n"
                    out += "      <text x=\"\(format(x + 38))\" y=\"\(format(rowY))\""
                    out += " font-family=\"Arial, Helvetica, sans-serif\" font-size=\"11\""
                    out += " fill=\"\(text)\">\(escape(LayerInventory.label(for: layer.name)))</text>\n"
                }
                out += "    </g>\n"
            }
        }

        return out + "  </g>\n"
    }

    /// The scale bar's label, in the projection's own units. Ported from
    /// `_format_distance`: degrees stay degrees, metres grow into kilometres, and
    /// anything smaller than a metre admits to being mere units.
    static func formatDistance(_ worldUnits: Double, renderCRS: String) -> String {
        let value = abs(worldUnits)
        if renderCRS == "EPSG:4326" {
            return value >= 1.0
                ? String(format: "%.2f deg", value)
                : String(format: "%.4f deg", value)
        }
        if value >= 1000.0 {
            let km = value / 1000.0
            return km >= 10.0
                ? String(format: "%.0f km", km)
                : String(format: "%.1f km", km)
        }
        if value >= 1.0 { return String(format: "%.0f m", value) }
        return String(format: "%.2f units", value)
    }

    /// One path string per ring or line.
    ///
    /// **Every vertex is written.** Kickoff detail 9: truncating a vertex list and
    /// jumping to the last vertex rules a chord straight across the shape.
    private func pathData(for geometry: Geometry, transform: CanvasTransform) -> [String] {
        var paths: [String] = []

        func ring(_ coordinates: [Coordinate], close: Bool) {
            guard coordinates.count >= 2 else { return }
            var commands: [String] = []
            commands.reserveCapacity(coordinates.count + 1)
            for (index, coordinate) in coordinates.enumerated() {
                let point = transform.worldToScreen(coordinate)
                commands.append("\(index == 0 ? "M" : "L") \(format(point.x)) \(format(point.y))")
            }
            if close { commands.append("Z") }
            paths.append(commands.joined(separator: " "))
        }

        func add(_ geometry: Geometry) {
            switch geometry {
            case .empty:
                break
            case .point(let coordinate):
                let point = transform.worldToScreen(coordinate)
                // A tiny closed circle, so a point survives as an object a vector
                // editor can select. Matches what the canvas renderer draws.
                let radius = 0.5
                let left = point.x - radius
                let right = point.x + radius
                paths.append(
                    "M \(format(left)) \(format(point.y)) "
                    + "A \(format(radius)) \(format(radius)) 0 1 0 \(format(right)) \(format(point.y)) "
                    + "A \(format(radius)) \(format(radius)) 0 1 0 \(format(left)) \(format(point.y)) Z"
                )
            case .multiPoint(let coordinates):
                for coordinate in coordinates { add(.point(coordinate)) }
            case .lineString(let line):
                ring(line.coordinates, close: false)
            case .multiLineString(let lines):
                for line in lines { ring(line.coordinates, close: false) }
            case .polygon(let polygon):
                ring(polygon.exterior.coordinates, close: true)
                for hole in polygon.holes { ring(hole.coordinates, close: true) }
            case .multiPolygon(let polygons):
                for polygon in polygons { add(.polygon(polygon)) }
            case .collection(let parts):
                for part in parts { add(part) }
            }
        }

        add(geometry)
        return paths.filter { !$0.isEmpty }
    }

    private func dataAttributes(for scene: RenderScene) -> [String: String] {
        var attributes = [
            "data-hipparchus-render-crs": scene.projection.renderCRS,
            "data-hipparchus-source-crs": scene.projection.sourceCRS,
            // Declared whether or not furniture is on, so an importer can honour
            // the intended page without parsing anything else.
            "data-hipparchus-paper": options.composition.paperPreset,
            "data-hipparchus-orientation": options.composition.orientation,
        ]
        if let provenance = scene.metadata["provenance"]?.stringValue {
            attributes["data-hipparchus-provenance"] = provenance
        }
        if let bbox = scene.bbox {
            attributes["data-hipparchus-bbox"] =
                "\(bbox.minLon),\(bbox.minLat),\(bbox.maxLon),\(bbox.maxLat)"
        }
        if let interval = scene.metadata["contour_interval_metres"]?.doubleValue {
            attributes["data-hipparchus-contour-interval-m"] = format(interval)
        }
        if let model = scene.metadata["elevation_model"]?.stringValue {
            attributes["data-hipparchus-elevation-model"] = model
        }
        return attributes
    }

    func diagnostics(for scene: RenderScene, format: String) -> ExportDiagnostics {
        ExportDiagnostics(
            format: format,
            width: options.width,
            height: options.height,
            renderCRS: scene.projection.renderCRS,
            sourceCRS: scene.projection.sourceCRS,
            provenance: scene.metadata["provenance"]?.stringValue,
            bbox: scene.bbox.map { [$0.minLon, $0.minLat, $0.maxLon, $0.maxLat] },
            layers: scene.layers.map {
                ExportDiagnostics.Layer(
                    name: $0.name,
                    geometries: $0.geometries.count,
                    rawFeatures: $0.rawFeatureCount,
                    labels: $0.labels.count,
                    visible: $0.style.visible
                )
            },
            metadata: scene.metadata.compactMapValues { $0.stringValue },
            diagnostics: scene.diagnostics.compactMapValues { $0.stringValue },
            composition: options.composition
        )
    }

    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.\(options.precision)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.isEmpty || text == "-0" ? "0" : text
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A layer id an editor will accept and a person can read.
    private func svgID(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        let text = String(cleaned)
        return text.first?.isNumber == true ? "layer_\(text)" : text
    }
}

/// What was exported, recorded beside the file.
///
/// Provenance is on here as well as in the SVG because this is the machine-readable
/// half: it is what lets someone check later whether a map was a survey or a
/// generated picture.
public struct ExportDiagnostics: Codable, Sendable, Equatable {
    public struct Layer: Codable, Sendable, Equatable {
        public let name: String
        public let geometries: Int
        /// What the provider returned, before clipping, capping and illumination
        /// changed the count. Both numbers are recorded because neither answers the
        /// other's question: `geometries` is what was drawn, `rawFeatures` is what
        /// was found.
        public let rawFeatures: Int
        public let labels: Int
        public let visible: Bool
    }

    public let format: String
    public let width: Int
    public let height: Int
    public let renderCRS: String
    public let sourceCRS: String
    public let provenance: String?
    public let bbox: [Double]?
    public let layers: [Layer]
    public let metadata: [String: String]
    public let diagnostics: [String: String]
    /// How the page was composed, when the exporter was told. Optional so a
    /// diagnostics file from before composition existed still decodes.
    public let composition: SVGExporter.Composition?

    public var totalGeometries: Int { layers.reduce(0) { $0 + $1.geometries } }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}