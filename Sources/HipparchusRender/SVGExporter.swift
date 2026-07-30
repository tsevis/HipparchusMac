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

    public struct Options: Sendable {
        public var width = 4096
        public var height = 4096
        /// Decimal places. Five is about a centimetre at Web Mercator scale, and
        /// more only inflates the file.
        public var precision = 5
        /// Paint the ground. Without it a dark preset exports pale strokes onto a
        /// transparent canvas, which reads as blank on white paper.
        public var includeBackground = true

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

        for label in layer.labels where !label.name.isEmpty {
            let point = transform.worldToScreen(label.position)
            out += "      <text x=\"\(format(point.x))\" y=\"\(format(point.y))\""
            out += " fill=\"\(style.strokeColor.hex)\" font-size=\"\(format(9.0))\""
            out += " text-anchor=\"middle\" dominant-baseline=\"middle\""
            if label.rotation != 0 {
                out += " transform=\"rotate(\(format(label.rotation)) \(format(point.x)) \(format(point.y)))\""
            }
            out += ">\(escape(label.name))</text>\n"
        }

        return out + "    </g>\n"
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
            diagnostics: scene.diagnostics.compactMapValues { $0.stringValue }
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

    public var totalGeometries: Int { layers.reduce(0) { $0 + $1.geometries } }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}