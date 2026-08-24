import Foundation
import HipparchusGeometry

/// Read an ESRI shapefile.
///
/// Replaces the Python's `fiona` dependency, which pulls in GDAL. Natural Earth
/// ships as shapefiles, and the format is small enough to read directly: a `.shp`
/// of geometry records and a `.dbf` of attributes, matched by position.
///
/// Only the 2D shape types are read. `Z` and `M` variants carry their extra
/// ordinates *after* the 2D ones, so the same code reads their geometry and ignores
/// the rest — which is exactly what a map wants from an elevation-tagged coastline.
public enum ShapefileReader {

    /// Shape type codes, from the ESRI specification.
    enum ShapeType: Int32 {
        case null = 0
        case point = 1
        case polyline = 3
        case polygon = 5
        case multiPoint = 8
        case pointZ = 11
        case polylineZ = 13
        case polygonZ = 15
        case multiPointZ = 18
        case pointM = 21
        case polylineM = 23
        case polygonM = 25
        case multiPointM = 28

        /// The 2D shape this is, ignoring any Z or M ordinates.
        var planar: ShapeType {
            switch self {
            case .point, .pointZ, .pointM: .point
            case .polyline, .polylineZ, .polylineM: .polyline
            case .polygon, .polygonZ, .polygonM: .polygon
            case .multiPoint, .multiPointZ, .multiPointM: .multiPoint
            case .null: .null
            }
        }
    }

    public static func features(
        at path: URL,
        bbox: BoundingBox,
        providerID: String
    ) throws -> [Feature] {
        var features: [Feature] = []
        for shapefile in try sources(at: path) {
            features.append(contentsOf: try read(
                shapefile, bbox: bbox, providerID: providerID, startingAt: features.count
            ))
        }
        return features
    }

    /// Natural Earth arrives as one `.shp`, as a folder of them, or — which is
    /// how the site actually hands it over — as a folder of *folders*, one per
    /// dataset, because each download unzips into a directory of its own.
    ///
    /// **The third shape is the one a reader is most likely to point at**, and
    /// it used to find nothing: `ne_10m/` holds no `.shp`, only
    /// `ne_10m_coastline/` and its siblings. The source then reported
    /// "Unrecognised format" for a folder of perfectly good Natural Earth, and
    /// the size refusal's advice to use Natural Earth could not be followed.
    /// One level down is enough for every layout the site produces.
    static func sources(at path: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
        guard isDirectory.boolValue else { return [path] }

        let manager = FileManager.default
        let children = try manager.contentsOfDirectory(
            at: path, includingPropertiesForKeys: [.isDirectoryKey]
        )
        func shapefiles(in urls: [URL]) -> [URL] {
            urls.filter { $0.pathExtension.lowercased() == "shp" }
        }

        let here = shapefiles(in: children)
        if !here.isEmpty { return here.sorted { $0.lastPathComponent < $1.lastPathComponent } }

        let nested = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .flatMap { folder in
                shapefiles(in: (try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil
                )) ?? [])
            }
        return nested.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func read(
        _ path: URL,
        bbox: BoundingBox,
        providerID: String,
        startingAt firstIndex: Int
    ) throws -> [Feature] {
        var reader = BinaryReader(try Data(contentsOf: path))

        // The header mixes byte orders: the file code and length are big-endian,
        // everything after them little-endian. Reading it all one way is the
        // classic way to get a shapefile reader subtly wrong.
        guard try reader.readInt32(bigEndian: true) == 9994 else {
            throw FileSourceError(source: path.lastPathComponent, reason: "not a shapefile")
        }
        try reader.seek(to: 100)

        let attributes = (try? DBaseReader.records(at: path.deletingPathExtension()
            .appendingPathExtension("dbf"))) ?? []

        var features: [Feature] = []
        // Counted separately from `features`, and that distinction is the whole
        // of a bug this had for as long as it could read a file. The `.dbf` is
        // matched to the `.shp` **by position**, so the attributes belong to the
        // record's place in the file — not to how many records have been kept.
        // A bbox query skips nearly every record in a world-wide file, and
        // indexing by the kept count handed each surviving feature the
        // attributes of one near the start of the file instead of its own. A
        // European frame came back with Agra and Albuquerque drawn in Europe.
        var recordIndex = 0
        while reader.remaining >= 8 {
            _ = try reader.readInt32(bigEndian: true)  // record number, 1-based
            let contentWords = try reader.readInt32(bigEndian: true)
            let contentBytes = Int(contentWords) * 2
            guard contentBytes > 0, reader.remaining >= contentBytes else { break }

            let end = reader.offset + contentBytes
            let geometry = try? shape(&reader)
            try reader.seek(to: end)

            let index = recordIndex
            recordIndex += 1

            guard let geometry, !geometry.isEmpty else { continue }
            // Feature bounds against the query, not "any vertex inside": a country
            // outline crossing the frame may place no vertex in it.
            guard let bounds = geometry.bounds, bounds.intersects(bbox.bounds) else { continue }

            let properties = index < attributes.count ? attributes[index] : [:]
            guard let layer = FileLayer.forProperties(
                properties, providerID: providerID, geometry: geometry
            ) else {
                continue
            }

            features.append(Feature(
                // The feature's own ordinal, not the record's: ids have to stay
                // distinct across the several files a folder source reads, and
                // each of those starts counting records from zero again.
                id: "\(providerID)/\(layer)/\(firstIndex + features.count)",
                layer: layer,
                source: providerID,
                geometry: geometry,
                provenance: .measured,
                properties: properties
            ))
        }
        return features
    }

    // MARK: - Geometry

    static func shape(_ reader: inout BinaryReader) throws -> Geometry? {
        let raw = try reader.readInt32()
        guard let type = ShapeType(rawValue: raw) else { return nil }

        switch type.planar {
        case .null:
            return nil

        case .point:
            let x = try reader.readDouble()
            let y = try reader.readDouble()
            return x.isFinite && y.isFinite ? .point(Coordinate(x: x, y: y)) : nil

        case .multiPoint:
            try reader.skip(32)  // the record's own bounding box
            let count = Int(try reader.readInt32())
            var points: [Coordinate] = []
            for _ in 0..<Swift.max(0, count) {
                let x = try reader.readDouble()
                let y = try reader.readDouble()
                if x.isFinite, y.isFinite { points.append(Coordinate(x: x, y: y)) }
            }
            return points.isEmpty ? nil : .multiPoint(points)

        case .polyline, .polygon:
            let parts = try readParts(&reader)
            guard !parts.isEmpty else { return nil }

            if type.planar == .polyline {
                let lines = parts.filter { $0.count >= 2 }.map { LineString($0) }
                guard !lines.isEmpty else { return nil }
                return lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines)
            }
            return assemble(rings: parts)

        default:
            return nil
        }
    }

    /// Parts are given as start indices into one flat coordinate list.
    static func readParts(_ reader: inout BinaryReader) throws -> [[Coordinate]] {
        try reader.skip(32)  // the record's own bounding box
        let partCount = Int(try reader.readInt32())
        let pointCount = Int(try reader.readInt32())
        guard partCount > 0, pointCount > 0, partCount <= pointCount else { return [] }

        var starts: [Int] = []
        for _ in 0..<partCount { starts.append(Int(try reader.readInt32())) }

        var points: [Coordinate] = []
        points.reserveCapacity(pointCount)
        for _ in 0..<pointCount {
            let x = try reader.readDouble()
            let y = try reader.readDouble()
            points.append(Coordinate(x: x, y: y))
        }

        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : pointCount
            guard start >= 0, end <= points.count, start < end else { return nil }
            return Array(points[start..<end]).filter(\.isFinite)
        }
    }

    /// Turn a shapefile polygon's rings into polygons with holes.
    ///
    /// The format carries no nesting: it says only that outer rings wind clockwise
    /// and holes anti-clockwise, in a y-up frame. So the winding decides, and each
    /// hole goes to the smallest outer ring containing it — the same rule the OSM
    /// relation assembler uses, and for the same reason.
    static func assemble(rings: [[Coordinate]]) -> Geometry? {
        let usable = rings.filter { $0.count >= 3 }.map { Ring($0) }
        guard !usable.isEmpty else { return nil }

        // Signed area is positive anti-clockwise in a y-up frame, so an outer ring
        // — clockwise — is negative.
        let outer = usable.filter { $0.signedDoubleArea < 0 }
        let inner = usable.filter { $0.signedDoubleArea >= 0 }

        // A file whose winding is wrong throughout would otherwise vanish. Falling
        // back to "every ring is an outline" draws something rather than nothing.
        guard !outer.isEmpty else {
            return Geometry.polygons(usable.map { Polygon(exterior: $0) })
        }
        return Geometry.polygons(RingAssembly.polygons(outer: outer, inner: inner))
    }
}

/// Read the attribute table beside a shapefile.
///
/// dBASE III: a header of fixed-width field descriptors, then fixed-width records
/// of ASCII. Ancient, and completely specified in a page.
enum DBaseReader {

    static func records(at path: URL) throws -> [[String: PropertyValue]] {
        var reader = BinaryReader(try Data(contentsOf: path))

        try reader.skip(4)  // version byte and last-updated date
        let recordCount = Int(try reader.readUInt32())
        let headerLength = Int(try reader.readUInt16())
        let recordLength = Int(try reader.readUInt16())
        guard recordCount >= 0, headerLength > 32, recordLength > 0 else { return [] }

        try reader.seek(to: 32)
        var fields: [(name: String, length: Int, type: Character)] = []
        while reader.offset + 32 <= headerLength {
            // 0x0D terminates the descriptor array.
            if bytesPeek(reader) == 0x0D { break }
            let raw = try reader.read(32)
            let nameBytes = raw.prefix(11).prefix { $0 != 0 }
            let name = String(decoding: Array(nameBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let type = Character(UnicodeScalar(raw[raw.startIndex + 11]))
            let length = Int(raw[raw.startIndex + 16])
            if !name.isEmpty, length > 0 { fields.append((name, length, type)) }
        }
        guard !fields.isEmpty else { return [] }

        try reader.seek(to: headerLength)
        var records: [[String: PropertyValue]] = []

        for _ in 0..<recordCount {
            guard reader.remaining >= recordLength else { break }
            let start = reader.offset
            let deleted = try reader.readByte() == 0x2A  // '*'

            var record: [String: PropertyValue] = [:]
            for field in fields {
                guard reader.remaining >= field.length else { break }
                let raw = try reader.read(field.length)
                let text = String(decoding: Array(raw), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                switch field.type {
                case "N", "F":
                    // Numeric fields are right-aligned ASCII; a blank one is absent
                    // rather than zero, which matters for a population count.
                    if let value = Double(text) {
                        record[field.name] = value == value.rounded() && abs(value) < 1e15
                            ? .int(Int(value)) : .double(value)
                    }
                case "L":
                    record[field.name] = .bool("YyTt".contains(text.first ?? "?"))
                default:
                    record[field.name] = .string(text)
                }
            }
            try reader.seek(to: start + recordLength)
            // A deleted row still occupies its slot, and dropping it would shift
            // every later record out of step with its geometry.
            records.append(deleted ? [:] : record)
        }
        return records
    }

    private static func bytesPeek(_ reader: BinaryReader) -> UInt8? {
        reader.offset < reader.count ? reader.bytes[reader.offset] : nil
    }
}
