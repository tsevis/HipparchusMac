import Foundation
import HipparchusGeometry

/// Map data read from a file on disk rather than fetched over the network.
///
/// Ported from `data_sources/optional_providers.py`.
///
/// One provider that dispatches on what the file turns out to be, rather than four
/// that each know one format. That is how the Python does it, and the reason is
/// **GeoJSON**: every file-backed source accepts it, so a format this app cannot
/// read natively is still reachable by converting it once with `ogr2ogr` or `duckdb`.
/// It is the escape hatch that keeps a long tail from being a wall.
///
/// The Python reaches for `osmium`, `fiona`, `pyarrow`, `mapbox_vector_tile` and
/// `pmtiles`, and reports a missing one as an unavailable source. Swift has none of
/// those, so the readers are written here — see `ShapefileReader`, `VectorTileReader`
/// and `OSMPBFReader` — and what cannot be read says so plainly rather than
/// pretending the file was empty.
public struct FileSourceProvider: MapProvider {
    public let providerID: String
    public let label: String
    public let provenance: Provenance
    public let path: URL?

    public init(providerID: String, label: String, provenance: Provenance = .measured, path: URL? = nil) {
        self.providerID = providerID
        self.label = label
        self.provenance = provenance
        self.path = path
    }

    // MARK: - The four sources the stack offers

    public static func localOSMPBF(path: URL? = nil) -> FileSourceProvider {
        FileSourceProvider(
            providerID: SourceID.localOSMPBF, label: "Local OSM extract", provenance: .measured, path: path
        )
    }

    public static func vectorTiles(path: URL? = nil) -> FileSourceProvider {
        FileSourceProvider(
            providerID: SourceID.vectorTiles, label: "Vector tiles", provenance: .measured, path: path
        )
    }

    public static func naturalEarth(path: URL? = nil) -> FileSourceProvider {
        FileSourceProvider(
            providerID: SourceID.naturalEarth, label: "Natural Earth", provenance: .measured, path: path
        )
    }

    public static func overture(path: URL? = nil) -> FileSourceProvider {
        FileSourceProvider(
            providerID: SourceID.overture, label: "Overture", provenance: .measured, path: path
        )
    }

    // MARK: - Availability

    /// What a file source can say about itself before anyone asks it to fetch.
    ///
    /// Reported rather than thrown, because "no file chosen yet" is the normal
    /// state of a source sitting in the sidebar, not an error.
    public struct Availability: Sendable, Equatable {
        public let isAvailable: Bool
        public let detail: String
    }

    public var availability: Availability {
        guard let path else {
            return Availability(isAvailable: false, detail: "No file chosen")
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
            return Availability(isAvailable: false, detail: "Not found: \(path.lastPathComponent)")
        }
        switch FileFormat.of(path) {
        case .geoJSON:
            return Availability(isAvailable: true, detail: "GeoJSON")
        case .shapefile:
            return Availability(isAvailable: true, detail: "Shapefile")
        case .mbtiles:
            return Availability(isAvailable: true, detail: "MBTiles vector tiles")
        case .pmtiles:
            return Availability(isAvailable: true, detail: "PMTiles vector tiles")
        case .osmPBF:
            return Availability(isAvailable: true, detail: "OSM PBF extract")
        case .parquet:
            // Said plainly, and with the way out. An empty map and no explanation
            // is the worst of the three answers available here.
            //
            // Not read natively because Parquet's compression is the obstacle, not
            // its structure: Overture writes ZSTD, Parquet commonly writes Snappy,
            // and macOS ships neither — Apple's Compression framework offers
            // Brotli, LZ4, LZFSE and LZMA, none of which Parquet uses. Reading it
            // here would mean writing a ZSTD decoder from scratch, with no real
            // archive to check it against, for one source that converts in one
            // command. See the README.
            return Availability(
                isAvailable: false,
                detail: "GeoParquet is not read directly. Convert it first: "
                    + "duckdb -c \"COPY (SELECT * FROM 'in.parquet') TO 'out.geojson' "
                    + "WITH (FORMAT GDAL, DRIVER 'GeoJSON')\""
            )
        case .unknown:
            return Availability(
                isAvailable: false,
                detail: "Unrecognised format: .\(path.pathExtension)"
            )
        }
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        guard let path else {
            throw FileSourceError(source: label, reason: "no file chosen")
        }
        let format = FileFormat.of(path)
        guard availability.isAvailable else {
            throw FileSourceError(source: label, reason: availability.detail)
        }

        let features: [Feature]
        switch format {
        case .geoJSON:
            features = try GeoJSONReader.features(at: path, bbox: query.bbox, providerID: providerID)
        case .shapefile:
            features = try ShapefileReader.features(at: path, bbox: query.bbox, providerID: providerID)
        case .mbtiles, .pmtiles:
            features = try VectorTileReader.features(at: path, bbox: query.bbox, providerID: providerID)
        case .osmPBF:
            features = try OSMPBFReader.features(at: path, bbox: query.bbox, providerID: providerID)
        case .parquet, .unknown:
            throw FileSourceError(source: label, reason: availability.detail)
        }

        var featuresByLayer: [String: [Feature]] = [:]
        for layer in FileLayer.all { featuresByLayer[layer] = [] }
        for feature in features {
            featuresByLayer[feature.layer, default: []].append(feature)
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "format": .string(format.rawValue),
                "path": .string(path.lastPathComponent),
                "feature_count": .int(features.count),
            ],
            bbox: query.bbox,
            provenance: provenance
        )
    }
}

public struct FileSourceError: Error, CustomStringConvertible {
    public let source: String
    public let reason: String

    public init(source: String, reason: String) {
        self.source = source
        self.reason = reason
    }

    public var description: String { "\(source) is unavailable: \(reason)" }
}

// MARK: - Format

/// What a file on disk turns out to be.
///
/// Decided by extension, and for a directory by what it holds. Sniffing the bytes
/// would be more robust, but every one of these formats is conventionally named and
/// a mis-sniffed file is harder to explain than a mis-named one.
public enum FileFormat: String, Sendable, Equatable {
    case geoJSON = "geojson"
    case shapefile
    case mbtiles
    case pmtiles
    case osmPBF = "osm_pbf"
    case parquet
    case unknown

    public static func of(_ path: URL) -> FileFormat {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
            // A directory of GeoJSON is how a converted extract usually arrives:
            // one file per layer, dropped in a folder.
            if children.contains(where: { ["geojson", "json"].contains(($0 as NSString).pathExtension.lowercased()) }) {
                return .geoJSON
            }
            if children.contains(where: { ($0 as NSString).pathExtension.lowercased() == "shp" }) {
                return .shapefile
            }
            return .unknown
        }

        let name = path.lastPathComponent.lowercased()
        // `.osm.pbf` is two extensions, and `pathExtension` only sees the last.
        if name.hasSuffix(".osm.pbf") || name.hasSuffix(".pbf") { return .osmPBF }

        switch path.pathExtension.lowercased() {
        case "geojson", "json", "ndjson", "geojsonl": return .geoJSON
        case "shp": return .shapefile
        case "mbtiles": return .mbtiles
        case "pmtiles": return .pmtiles
        case "parquet": return .parquet
        default: return .unknown
        }
    }
}

/// The layers a file source may produce.
///
/// The Overpass set plus the ones only a file can carry — administrative
/// boundaries, and the terrain layers a DEM or a converted contour set brings.
public enum FileLayer {
    public static let adminBoundaries = "admin_boundaries"

    public static let all: [String] = OverpassQuery.supportedLayers + [
        adminBoundaries,
        TerrainLayer.minorContours,
        TerrainLayer.indexContours,
        TerrainLayer.elevationBands,
        TerrainLayer.bathymetry,
        TerrainLayer.summits,
        NightLightsLayer.name,
    ]

    static let known = Set(all)

    /// Which layer a feature's properties put it in.
    ///
    /// A file may say outright, which is what makes a hand-authored GeoJSON usable
    /// without arguing with a tag classifier. Otherwise the source's own vocabulary
    /// is tried — Natural Earth's `featurecla`, Overture's `theme` — and finally the
    /// OSM tags, because most converted data still carries them.
    public static func forProperties(
        _ properties: [String: PropertyValue],
        providerID: String,
        geometry: Geometry
    ) -> String? {
        func value(_ key: String) -> String? {
            if let exact = properties[key]?.stringValue, !exact.isEmpty { return exact }
            for (name, item) in properties where name.lowercased() == key.lowercased() {
                if let text = item.stringValue, !text.isEmpty { return text }
            }
            return nil
        }

        for key in ["hipparchus_layer", "layer", "layer_name"] {
            if let named = value(key), known.contains(named) { return named }
        }

        switch providerID {
        case SourceID.naturalEarth:
            let featureClass = (value("featurecla") ?? value("type") ?? "").lowercased()
            if case .point = geometry, featureClass.contains("capital")
                || featureClass.contains("populated") || value("name") != nil {
                return "places"
            }
            if featureClass.contains("admin") || featureClass.contains("country")
                || value("admin") != nil {
                return adminBoundaries
            }
            if featureClass.contains("river") || featureClass.contains("lake")
                || featureClass.contains("ocean") || featureClass.contains("coastline") {
                return "water"
            }
        case SourceID.overture:
            let theme = (value("theme") ?? value("type") ?? value("subtype") ?? "").lowercased()
            if theme.contains("building") { return "buildings" }
            if theme.contains("place") { return "places" }
            if theme.contains("water") { return "water" }
            if theme.contains("segment") || theme.contains("road") { return "roads" }
        default:
            break
        }

        // Most converted data still carries OSM tags, so the same reading works.
        var tags: [String: Any] = [:]
        for (key, item) in properties {
            if let text = item.stringValue { tags[key] = text }
        }
        return OverpassDecode.classify(tags: tags)
    }
}

// MARK: - GeoJSON

/// The universal path: every file-backed source accepts GeoJSON.
///
/// A format this app cannot read natively is still reachable by converting it once,
/// which is what stops the long tail from being a wall.
public enum GeoJSONReader {

    public static func features(
        at path: URL,
        bbox: BoundingBox,
        providerID: String
    ) throws -> [Feature] {
        var features: [Feature] = []
        for file in try sources(at: path) {
            let data = try Data(contentsOf: file)
            // A `.geojsonl`/`.ndjson` file is one feature per line, which is how
            // large exports arrive; a plain `.geojson` is one object.
            if ["ndjson", "geojsonl"].contains(file.pathExtension.lowercased()) {
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any] else { continue }
                    collect(object, into: &features, bbox: bbox, providerID: providerID)
                }
            } else {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                collect(object, into: &features, bbox: bbox, providerID: providerID)
            }
        }
        return features
    }

    static func sources(at path: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return [path] }

        let children = try FileManager.default.contentsOfDirectory(
            at: path, includingPropertiesForKeys: nil
        )
        return children
            .filter { ["geojson", "json", "ndjson", "geojsonl"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func collect(
        _ payload: [String: Any],
        into features: inout [Feature],
        bbox: BoundingBox,
        providerID: String
    ) {
        for object in objects(in: payload) {
            guard let geometryObject = object["geometry"] as? [String: Any],
                  let geometry = GeoJSONGeometry.decode(geometryObject),
                  !geometry.isEmpty
            else {
                continue
            }
            // Feature bounds against the query, not "any vertex inside it": the
            // latter silently drops a long way that crosses the frame without
            // placing a vertex in it.
            guard let bounds = geometry.bounds, bounds.intersects(bbox.bounds) else { continue }

            let properties = OverpassDecode.properties(
                from: (object["properties"] as? [String: Any]) ?? [:]
            )
            guard let layer = FileLayer.forProperties(
                properties, providerID: providerID, geometry: geometry
            ) else {
                continue
            }

            features.append(Feature(
                id: object["id"].map { "\($0)" } ?? "\(providerID)/\(layer)/\(features.count)",
                layer: layer,
                source: providerID,
                geometry: geometry,
                provenance: .measured,
                properties: properties
            ))
        }
    }

    static func objects(in payload: [String: Any]) -> [[String: Any]] {
        switch payload["type"] as? String {
        case "FeatureCollection": return payload["features"] as? [[String: Any]] ?? []
        case "Feature": return [payload]
        default: return payload["features"] as? [[String: Any]] ?? []
        }
    }
}

/// GeoJSON geometry objects, in and out.
public enum GeoJSONGeometry {

    public static func decode(_ object: [String: Any]) -> Geometry? {
        guard let type = object["type"] as? String else { return nil }

        if type == "GeometryCollection" {
            let parts = (object["geometries"] as? [[String: Any]] ?? []).compactMap(decode)
            // Flattened rather than modelled: nothing downstream draws a collection
            // as a unit, and a collection of one is the common case.
            let polygons = parts.flatMap(\.polygons)
            if !polygons.isEmpty { return Geometry.polygons(polygons) }
            let lines = parts.flatMap(\.lineStrings)
            if !lines.isEmpty { return lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines) }
            return parts.first
        }

        guard let coordinates = object["coordinates"] else { return nil }

        switch type {
        case "Point":
            return point(coordinates).map { .point($0) }
        case "MultiPoint":
            let points = (coordinates as? [Any] ?? []).compactMap(point)
            return points.isEmpty ? nil : .multiPoint(points)
        case "LineString":
            let line = ring(coordinates)
            return line.count >= 2 ? .lineString(LineString(line)) : nil
        case "MultiLineString":
            let lines = (coordinates as? [Any] ?? []).map(ring).filter { $0.count >= 2 }
            guard !lines.isEmpty else { return nil }
            let strings = lines.map { LineString($0) }
            return strings.count == 1 ? .lineString(strings[0]) : .multiLineString(strings)
        case "Polygon":
            return polygon(coordinates).map { .polygon($0) }
        case "MultiPolygon":
            let polygons = (coordinates as? [Any] ?? []).compactMap(polygon)
            return polygons.isEmpty ? nil : Geometry.polygons(polygons)
        default:
            return nil
        }
    }

    static func point(_ value: Any) -> Coordinate? {
        guard let pair = value as? [Any], pair.count >= 2,
              let lon = (pair[0] as? NSNumber)?.doubleValue,
              let lat = (pair[1] as? NSNumber)?.doubleValue,
              lon.isFinite, lat.isFinite
        else {
            return nil
        }
        return Coordinate(lon: lon, lat: lat)
    }

    static func ring(_ value: Any) -> [Coordinate] {
        (value as? [Any] ?? []).compactMap(point)
    }

    static func polygon(_ value: Any) -> Polygon? {
        let rings = (value as? [Any] ?? []).map(ring).filter { $0.count >= 3 }
        guard let exterior = rings.first else { return nil }
        return Polygon(exterior: exterior, holes: Array(rings.dropFirst()))
    }
}
