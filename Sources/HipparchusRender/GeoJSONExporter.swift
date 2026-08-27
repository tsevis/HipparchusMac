import Foundation
import HipparchusData
import HipparchusGeometry

/// The scene as data rather than as ink.
///
/// **No Python counterpart.** Every export this application had until now — SVG,
/// PDF, PNG — is a picture: the coordinates in them are page coordinates, and the
/// ground they came from is gone by the time the file is written. That is right
/// for the product and wrong as the only door out. A coastline assembled from
/// EMODnet's 115 m grid, a depth band, a seamark placed from OSM — none of it
/// could leave here except as a drawing, and a drawing cannot be measured,
/// queried or joined to anything.
///
/// So this writes the same scene as RFC 7946 GeoJSON: every vertex unprojected
/// back to longitude and latitude, every feature naming the layer it came from,
/// and the per-feature colours the ramp assigned carried in simplestyle-spec keys
/// that other tools already read. It is the inverse of the step `SVGExporter`
/// takes, not new geometry.
///
/// **What it cannot carry is attributes.** A `RenderScene` is the drawing: by the
/// time a feature reaches a layer its OSM tags have been read, classified and
/// discarded, and nothing downstream of `SceneBuilder` has them to give back.
/// What comes out is shape, layer and style — enough to draw, measure and filter,
/// not enough to ask what a way was tagged. Fetching that means going back to the
/// source, which is what the source is for.
public struct GeoJSONExporter: Sendable {

    public struct Options: Sendable {
        /// Decimal places, in **degrees** — not the projected metres the SVG counts
        /// in, where five places is a centimetre. Six places is about 11 cm at the
        /// equator, past anything this application's sources resolve.
        public var precision = 6
        /// Hidden layers are written and marked rather than dropped, as the SVG
        /// writes them with `display="none"`: an unticked layer is still part of
        /// the map, and something downstream may want it back.
        public var includeHiddenLayers = true
        /// Place labels, as point features carrying their name.
        public var includeLabels = true

        public init() {}
    }

    /// What went into the files. Deliberately not `ExportDiagnostics`: that record
    /// is built around a page with a pixel size, and this format has neither.
    public struct Summary: Sendable, Equatable {
        /// Features written, across every file.
        public let features: Int
        /// Layers that had anything to write.
        public let layers: Int
        /// Parts skipped because a vertex would not unproject — see `unprojected`.
        /// Nonzero means the file is missing something, which is worth saying.
        public let dropped: Int
        /// File names, in the order they were written, which is draw order.
        public let files: [String]
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Documents

    /// The whole scene as one `FeatureCollection`, layer named on every feature.
    ///
    /// One file is the shape most viewers want dropped on them; it is also the
    /// shape that makes a mixed stack of fills, lines and points awkward to style
    /// as a unit. `writeLayers(of:into:)` is the other answer to the same question.
    public func featureCollection(for scene: RenderScene) -> String {
        let built = build(scene.layers, in: scene)
        return document(built, in: scene, layers: scene.layers)
    }

    /// One layer as its own `FeatureCollection`, carrying the whole scene's
    /// provenance — a file separated from its siblings must still say what it is.
    public func featureCollection(for layer: RenderLayer, in scene: RenderScene) -> String {
        let built = build([layer], in: scene)
        return document(built, in: scene, layers: [layer])
    }

    // MARK: - Files

    /// Write the scene as a single `.geojson`.
    @discardableResult
    public func write(_ scene: RenderScene, to url: URL) throws -> Summary {
        let built = build(scene.layers, in: scene)
        let text = document(built, in: scene, layers: scene.layers)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return Summary(
            features: built.features.count,
            layers: scene.layers.filter { !$0.isEmpty }.count,
            dropped: built.dropped,
            files: [url.lastPathComponent]
        )
    }

    /// Write one file per populated layer into `directory`, which is created if it
    /// is not there.
    ///
    /// Named `000-`, `001-` and so on in draw order, because a directory is read
    /// back in name order — by `GeoJSONReader` here, and by most other things —
    /// and the alphabet would otherwise stack the contours under the ground they
    /// describe. Three digits: `100-` sorts before `99-`.
    ///
    /// Files this exporter wrote on a previous run are removed first, and only
    /// those: a stale `004-roads.geojson` left beside a shorter stack reads back
    /// as part of the map. Nothing outside that naming pattern is touched.
    @discardableResult
    public func writeLayers(of scene: RenderScene, into directory: URL) throws -> Summary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try removePreviousExport(in: directory)

        var files: [String] = []
        var features = 0
        var dropped = 0

        for (index, layer) in scene.layers.enumerated() where !layer.isEmpty {
            let built = build([layer], in: scene)
            guard !built.features.isEmpty else {
                dropped += built.dropped
                continue
            }
            let name = String(format: "%03d-%@.geojson", index, fileStem(layer.name))
            let text = document(built, in: scene, layers: [layer])
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            files.append(name)
            features += built.features.count
            dropped += built.dropped
        }

        return Summary(features: features, layers: files.count, dropped: dropped, files: files)
    }

    /// Only files this exporter's own naming pattern would have produced.
    private func removePreviousExport(in directory: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        for child in children where isPreviousExport(child.lastPathComponent) {
            try FileManager.default.removeItem(at: child)
        }
    }

    private func isPreviousExport(_ name: String) -> Bool {
        guard name.hasSuffix(".geojson"), name.count > 4 else { return false }
        let leading = name.prefix(4)
        return leading.count == 4 && leading.dropLast().allSatisfy(\.isNumber) && leading.last == "-"
    }

    /// A file name a person can read and a file system will accept.
    private func fileStem(_ name: String) -> String {
        let cleaned = name.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
                ? character : "_"
        }
        let text = String(cleaned)
        return text.isEmpty ? "layer" : text
    }

    // MARK: - Building

    private struct Built {
        var features: [String] = []
        /// Per layer, parallel to the layers the caller passed in.
        var counts: [Int] = []
        var dropped = 0
    }

    private func build(_ layers: [RenderLayer], in scene: RenderScene) -> Built {
        var built = Built()
        for layer in layers {
            guard layer.style.visible || options.includeHiddenLayers else {
                built.counts.append(0)
                continue
            }
            let before = built.features.count
            append(layer, in: scene, to: &built)
            built.counts.append(built.features.count - before)
        }
        return built
    }

    private func append(_ layer: RenderLayer, in scene: RenderScene, to built: inout Built) {
        let projection = scene.projection

        // Where the names in this layer sit, keyed by the position as it will be
        // written. Natural Earth's places arrive as a point *and* a label at the
        // same spot — the renderer draws a dot and then the name — which is two
        // marks on paper and one place on the ground. Written naively that is six
        // cities exported as twelve points, half of them anonymous, which is what
        // a real Cyprus sheet did.
        var names: [String: PlaceLabel] = [:]
        if options.includeLabels {
            for label in layer.labels where !label.name.isEmpty {
                names[position(projection.unproject(label.position))] = label
            }
        }
        var merged: Set<String> = []

        for (index, geometry) in layer.geometries.enumerated() {
            let ground = geometry.mapCoordinates(projection.unproject)
            for part in flattened(ground) {
                guard let json = geometryJSON(part) else {
                    built.dropped += 1
                    continue
                }
                var fields = properties(of: layer, at: index, geometry: part)
                // Only an exact match. A label set along a line, or nudged clear
                // of the dot it names, is a different thing in a different place
                // and stays its own feature.
                if case .point(let coordinate) = part {
                    let key = position(coordinate)
                    if let label = names[key] {
                        fields.append(contentsOf: nameFields(label))
                        merged.insert(key)
                    }
                }
                built.features.append(feature(geometry: json, properties: fields))
            }
        }

        guard options.includeLabels else { return }
        for label in layer.labels where !label.name.isEmpty {
            let ground = projection.unproject(label.position)
            guard !merged.contains(position(ground)) else { continue }
            guard let json = geometryJSON(.point(ground)) else {
                built.dropped += 1
                continue
            }
            built.features.append(
                feature(geometry: json, properties: properties(of: layer, label: label))
            )
        }
    }

    /// GeoJSON has a `GeometryCollection` and almost nothing draws one usefully.
    /// A collection is written as one feature per part instead, each keeping the
    /// layer and style it arrived with — which is also how `GeoJSONReader` reads
    /// one back, so the two agree.
    private func flattened(_ geometry: Geometry) -> [Geometry] {
        guard case .collection(let parts) = geometry else {
            return geometry.isEmpty ? [] : [geometry]
        }
        return parts.flatMap(flattened)
    }

    // MARK: - Properties

    private func properties(of layer: RenderLayer, at index: Int, geometry: Geometry) -> [Field] {
        let style = layer.style
        var fields: [Field] = [("hipparchus_layer", .string(layer.name))]

        // `hasArea`, not the style alone: a layer that fills may still hold open
        // lines, and a viewer told to fill one closes it with an invisible chord
        // and paints the wedge behind it.
        if style.fillEnabled, geometry.hasArea {
            let fill = layer.fillColor(at: index)
            fields.append(("fill", .string(fill.hex)))
            fields.append(("fill-opacity", .number(opacity(of: fill, in: style))))
        }

        let width = style.strokeWidth * layer.weight(at: index)
        if width > 0, style.strokeColor.a > 0 {
            fields.append(("stroke", .string(style.strokeColor.hex)))
            fields.append(("stroke-width", .number(width)))
            fields.append(("stroke-opacity", .number(opacity(of: style.strokeColor, in: style))))
        }
        if !style.visible {
            fields.append(("visible", .bool(false)))
        }
        return fields
    }

    private func properties(of layer: RenderLayer, label: PlaceLabel) -> [Field] {
        var fields: [Field] = [("hipparchus_layer", .string(layer.name))]
        fields.append(contentsOf: nameFields(label))
        if !layer.style.visible {
            fields.append(("visible", .bool(false)))
        }
        return fields
    }

    /// What a name contributes, whether it becomes a feature of its own or lands
    /// on the mark it belongs to.
    private func nameFields(_ label: PlaceLabel) -> [Field] {
        var fields: [Field] = [("name", .string(label.name))]
        if !label.placeType.isEmpty {
            fields.append(("place_type", .string(label.placeType)))
        }
        if label.rotation != 0 {
            fields.append(("rotation", .number(label.rotation)))
        }
        return fields
    }

    /// A colour carries its own alpha and the layer carries one over the top of it,
    /// exactly as the renderer multiplies them.
    private func opacity(of color: RGBAColor, in style: LayerStyle) -> Double {
        Double(color.a) / 255.0 * min(max(style.opacity, 0), 1)
    }

    // MARK: - Geometry

    /// `nil` when there is nothing writable left — an empty part, or one holding a
    /// vertex that would not come back out of the projection.
    ///
    /// A part with a bad vertex is dropped whole rather than repaired by leaving
    /// the vertex out: a missing shape is visible, and a shape silently short-cut
    /// across the gap is not.
    private func geometryJSON(_ geometry: Geometry) -> String? {
        switch geometry {
        case .empty, .collection:
            return nil
        case .point(let coordinate):
            guard coordinate.isFinite else { return nil }
            return object([("type", .string("Point")), ("coordinates", .raw(position(coordinate)))])
        case .multiPoint(let coordinates):
            let kept = coordinates.filter(\.isFinite)
            guard !kept.isEmpty else { return nil }
            return object([
                ("type", .string("MultiPoint")),
                ("coordinates", .raw(list(kept.map(position)))),
            ])
        case .lineString(let line):
            guard let written = self.line(line) else { return nil }
            return object([("type", .string("LineString")), ("coordinates", .raw(written))])
        case .multiLineString(let lines):
            let kept = lines.compactMap(line)
            guard !kept.isEmpty else { return nil }
            if kept.count == 1 {
                return object([("type", .string("LineString")), ("coordinates", .raw(kept[0]))])
            }
            return object([("type", .string("MultiLineString")), ("coordinates", .raw(list(kept)))])
        case .polygon(let polygon):
            guard let written = rings(of: polygon) else { return nil }
            return object([("type", .string("Polygon")), ("coordinates", .raw(written))])
        case .multiPolygon(let polygons):
            let kept = polygons.compactMap(rings)
            guard !kept.isEmpty else { return nil }
            if kept.count == 1 {
                return object([("type", .string("Polygon")), ("coordinates", .raw(kept[0]))])
            }
            return object([("type", .string("MultiPolygon")), ("coordinates", .raw(list(kept)))])
        }
    }

    private func line(_ line: LineString) -> String? {
        let coordinates = line.coordinates
        guard coordinates.count >= 2, coordinates.allSatisfy(\.isFinite) else { return nil }
        return list(coordinates.map(position))
    }

    /// RFC 7946 §3.1.6: exterior counter-clockwise, holes clockwise. Widely ignored
    /// and not by MapLibre, which is what a viewer like GeoLibre draws with — a
    /// wrongly wound exterior there fills the world and knocks a hole where the
    /// island should be.
    private func rings(of polygon: Polygon) -> String? {
        guard let exterior = ring(polygon.exterior, counterClockwise: true) else { return nil }
        let holes = polygon.holes.compactMap { ring($0, counterClockwise: false) }
        return list([exterior] + holes)
    }

    private func ring(_ ring: Ring, counterClockwise: Bool) -> String? {
        var coordinates = ring.coordinates
        guard coordinates.count >= 4, coordinates.allSatisfy(\.isFinite) else { return nil }
        // Measured on the ring as written, in degrees: the winding of a projected
        // ring and of its unprojected self are not always the same hand.
        let area = Ring(coordinates).signedDoubleArea
        if area != 0, (area > 0) != counterClockwise {
            coordinates.reverse()
        }
        return list(coordinates.map(position))
    }

    private func position(_ coordinate: Coordinate) -> String {
        "[\(format(coordinate.lon)),\(format(coordinate.lat))]"
    }

    // MARK: - The document

    private func document(_ built: Built, in scene: RenderScene, layers: [RenderLayer]) -> String {
        var out = "{\"type\":\"FeatureCollection\""
        if let bbox = scene.bbox {
            out += ",\"bbox\":[\(format(bbox.minLon)),\(format(bbox.minLat)),"
            out += "\(format(bbox.maxLon)),\(format(bbox.maxLat))]"
        }
        out += ",\"hipparchus\":\(provenance(of: scene, layers: layers, counts: built.counts))"
        out += ",\"features\":[\n"
        out += built.features.joined(separator: ",\n")
        out += "\n]}\n"
        return out
    }

    /// What the SVG carries as `data-hipparchus-*` attributes, in the one place
    /// RFC 7946 leaves for it: a foreign member on the collection.
    private func provenance(
        of scene: RenderScene, layers: [RenderLayer], counts: [Int]
    ) -> String {
        var fields: [Field] = [
            ("crs", .string("EPSG:4326")),
            ("render_crs", .string(scene.projection.renderCRS)),
        ]
        if let provenance = scene.metadata["provenance"]?.stringValue {
            fields.append(("provenance", .string(provenance)))
        }
        if let model = scene.metadata["elevation_model"]?.stringValue {
            fields.append(("elevation_model", .string(model)))
        }
        if let interval = scene.metadata["contour_interval_metres"]?.doubleValue {
            fields.append(("contour_interval_m", .number(interval)))
        }
        // **Unconditional, as on the SVG.** A file that stands on sea marks or
        // depths says so to whatever reads it, whether or not anyone drew the words.
        if NotForNavigation.applies(to: scene) {
            fields.append(("not_for_navigation", .bool(true)))
        }
        // **Also unconditional.** The About panel says the attributions travel with
        // anything published from here; a new export format is a new way for that
        // sentence to quietly stop being true.
        let credit = SheetAttribution.statement(for: scene)
        if !credit.isEmpty {
            fields.append(("attribution", .string(credit)))
        }
        let inventory = zip(layers, counts + Array(repeating: 0, count: max(0, layers.count - counts.count)))
            .map { layer, count in
                object([
                    ("name", .string(layer.name)),
                    ("features", .integer(count)),
                    ("raw_features", .integer(layer.rawFeatureCount)),
                    ("visible", .bool(layer.style.visible)),
                ])
            }
        fields.append(("layers", .raw(list(inventory))))
        return object(fields)
    }

    private func feature(geometry: String, properties: [Field]) -> String {
        "  " + object([
            ("type", .string("Feature")),
            ("geometry", .raw(geometry)),
            ("properties", .raw(object(properties))),
        ])
    }

    // MARK: - JSON

    private typealias Field = (key: String, value: Value)

    private enum Value {
        case string(String)
        case number(Double)
        case integer(Int)
        case bool(Bool)
        /// Already-written JSON, spliced in.
        case raw(String)
    }

    private func object(_ fields: [Field]) -> String {
        let body = fields.map { "\(quoted($0.key)):\(written($0.value))" }.joined(separator: ",")
        return "{\(body)}"
    }

    private func list(_ items: [String]) -> String {
        "[\(items.joined(separator: ","))]"
    }

    private func written(_ value: Value) -> String {
        switch value {
        case .string(let text): return quoted(text)
        case .number(let number): return format(number)
        case .integer(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .raw(let json): return json
        }
    }

    /// A place name is data from a map source, not something to trust into a
    /// string literal. Escaped per RFC 8259, control characters included.
    private func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }

    /// Fixed places, trailing zeros trimmed. A degree written to seventeen figures
    /// is a bigger file saying the same thing.
    private func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.\(max(0, options.precision))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.isEmpty || text == "-0" ? "0" : text
    }
}
