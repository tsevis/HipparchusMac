import Foundation
import HipparchusGeometry
import SQLite3
import zlib

/// Read Mapbox Vector Tiles out of an MBTiles or PMTiles archive.
///
/// Replaces the Python's `mapbox_vector_tile` and `pmtiles` dependencies.
///
/// A vector tile is a protobuf holding layers of features whose coordinates are
/// integers in a tile-local grid, delivered as a *command stream* rather than as a
/// list of points. Decoding it is three small things stacked: protobuf wire format,
/// the command encoding, and the tile-to-longitude arithmetic that puts the result
/// back on the Earth.
public enum VectorTileReader {

    /// Which zoom to read. Tiles exist at many zooms and every one covers the same
    /// ground; this is the level of detail, not the area.
    public static let preferredZoom = 14

    public static func features(
        at path: URL,
        bbox: BoundingBox,
        providerID: String
    ) throws -> [Feature] {
        let archive: any TileArchive = path.pathExtension.lowercased() == "pmtiles"
            ? try PMTilesArchive(path: path)
            : try MBTilesArchive(path: path)
        defer { archive.close() }

        let zoom = archive.zoom(preferring: preferredZoom)
        var features: [Feature] = []

        for tile in tiles(for: bbox, zoom: zoom) {
            guard let raw = try archive.tile(z: tile.z, x: tile.x, y: tile.y) else { continue }
            let payload = decompressed(raw)
            let layers = (try? MVT.decode(payload)) ?? []

            for layer in layers {
                for shape in layer.features {
                    guard let geometry = shape.geometry(z: tile.z, x: tile.x, y: tile.y, extent: layer.extent),
                          !geometry.isEmpty,
                          let bounds = geometry.bounds, bounds.intersects(bbox.bounds)
                    else {
                        continue
                    }

                    var properties = shape.properties
                    // The tile's own layer name is the best hint there is, and it
                    // is usually already one of ours — "water", "buildings",
                    // "roads" — because the schemas grew out of OSM.
                    properties["layer"] = .string(layer.name)

                    guard let named = FileLayer.forProperties(
                        properties, providerID: providerID, geometry: geometry
                    ) else {
                        continue
                    }
                    features.append(Feature(
                        id: "\(providerID)/\(named)/\(features.count)",
                        layer: named,
                        source: providerID,
                        geometry: geometry,
                        provenance: .measured,
                        properties: properties
                    ))
                }
            }
        }
        return features
    }

    /// Every tile covering the area at one zoom.
    static func tiles(for bbox: BoundingBox, zoom: Int) -> [(z: Int, x: Int, y: Int)] {
        let topLeft = WebMercator.tile(lon: bbox.minLon, lat: bbox.maxLat, zoom: zoom)
        let bottomRight = WebMercator.tile(lon: bbox.maxLon, lat: bbox.minLat, zoom: zoom)

        var result: [(z: Int, x: Int, y: Int)] = []
        // A frame this big at this zoom is thousands of tiles; the caller wants a
        // map, not an afternoon.
        let limit = 400
        for x in Swift.min(topLeft.x, bottomRight.x)...Swift.max(topLeft.x, bottomRight.x) {
            for y in Swift.min(topLeft.y, bottomRight.y)...Swift.max(topLeft.y, bottomRight.y) {
                result.append((zoom, x, y))
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Tiles in an archive are usually gzipped, and sometimes not.
    static func decompressed(_ data: Data) -> Data {
        guard data.count > 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return data
        }
        return Inflate.gunzip(data) ?? data
    }
}

// MARK: - Archives

protocol TileArchive {
    func tile(z: Int, x: Int, y: Int) throws -> Data?
    func zoom(preferring: Int) -> Int
    func close()
}

/// MBTiles is a SQLite database with a `tiles` table.
///
/// Read through the system's own libsqlite3 rather than a wrapper: it is three
/// calls, and a dependency for three calls is a dependency to keep updated forever.
final class MBTilesArchive: TileArchive {
    private var handle: OpaquePointer?

    init(path: URL) throws {
        var database: OpaquePointer?
        // Read-only, because this is someone's file and we are a viewer.
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw FileSourceError(source: path.lastPathComponent, reason: "could not open the MBTiles file")
        }
        handle = database
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }

    func zoom(preferring preferred: Int) -> Int {
        // The closest zoom the archive actually holds, so asking for 14 in an
        // archive that stops at 10 reads 10 rather than nothing.
        var best: Int?
        var statement: OpaquePointer?
        let sql = "SELECT DISTINCT zoom_level FROM tiles ORDER BY zoom_level"
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let zoom = Int(sqlite3_column_int(statement, 0))
                if best == nil || abs(zoom - preferred) < abs((best ?? 0) - preferred) { best = zoom }
            }
        }
        sqlite3_finalize(statement)
        return best ?? preferred
    }

    func tile(z: Int, x: Int, y: Int) throws -> Data? {
        // MBTiles stores rows flipped: the spec uses TMS, where row 0 is the
        // *south* edge, and every other tile scheme in this app counts from north.
        let flipped = (1 << z) - 1 - y

        var statement: OpaquePointer?
        let sql = "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(z))
        sqlite3_bind_int(statement, 2, Int32(x))
        sqlite3_bind_int(statement, 3, Int32(flipped))

        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_blob(statement, 0)
        else {
            return nil
        }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, 0)))
    }
}

/// PMTiles v3: a header, then directories of entries, then the tile data.
///
/// Tiles are addressed by a Hilbert curve index rather than by (z, x, y), which is
/// what lets neighbouring tiles sit next to each other in the file — the whole
/// point of the format, and the only fiddly part of reading it.
final class PMTilesArchive: TileArchive {
    private let data: Data
    private let rootOffset: Int
    private let rootLength: Int
    private let leafOffset: Int
    private let tileOffset: Int
    private let internalCompression: UInt8
    private let minZoom: Int
    private let maxZoom: Int

    init(path: URL) throws {
        data = try Data(contentsOf: path)
        var reader = BinaryReader(data)

        let magic = try reader.read(7)
        guard String(decoding: Array(magic), as: UTF8.self) == "PMTiles" else {
            throw FileSourceError(source: path.lastPathComponent, reason: "not a PMTiles archive")
        }
        let version = try reader.readByte()
        guard version == 3 else {
            throw FileSourceError(
                source: path.lastPathComponent,
                reason: "PMTiles v\(version) is not read; v3 is"
            )
        }

        rootOffset = Int(try reader.readUInt64())
        rootLength = Int(try reader.readUInt64())
        _ = try reader.readUInt64()  // metadata offset
        _ = try reader.readUInt64()  // metadata length
        leafOffset = Int(try reader.readUInt64())
        _ = try reader.readUInt64()  // leaf directory length
        tileOffset = Int(try reader.readUInt64())
        _ = try reader.readUInt64()  // tile data length
        _ = try reader.readUInt64()  // addressed tiles
        _ = try reader.readUInt64()  // tile entries
        _ = try reader.readUInt64()  // tile contents
        _ = try reader.readByte()    // clustered
        internalCompression = try reader.readByte()
        _ = try reader.readByte()    // tile compression
        _ = try reader.readByte()    // tile type
        minZoom = Int(try reader.readByte())
        maxZoom = Int(try reader.readByte())
    }

    func close() {}

    func zoom(preferring preferred: Int) -> Int {
        Swift.min(Swift.max(preferred, minZoom), maxZoom)
    }

    func tile(z: Int, x: Int, y: Int) throws -> Data? {
        let target = Self.hilbertIndex(z: z, x: x, y: y)
        var offset = rootOffset
        var length = rootLength

        // At most a root directory and a few leaf levels; the bound stops a
        // corrupt archive from pointing a directory at itself forever.
        for _ in 0..<4 {
            guard let entries = try? directory(offset: offset, length: length) else { return nil }
            guard let entry = Self.find(target, in: entries) else { return nil }

            if entry.runLength == 0 {
                // A run length of zero means "this entry names a leaf directory".
                offset = leafOffset + Int(entry.offset)
                length = Int(entry.length)
                continue
            }
            let start = tileOffset + Int(entry.offset)
            guard start >= 0, start + Int(entry.length) <= data.count else { return nil }
            return data.subdata(in: start..<(start + Int(entry.length)))
        }
        return nil
    }

    struct Entry {
        let tileID: UInt64
        let runLength: UInt32
        let offset: UInt64
        let length: UInt32
    }

    /// Directory entries are delta-encoded in four separate runs — every tile id,
    /// then every run length, then every length, then every offset.
    private func directory(offset: Int, length: Int) throws -> [Entry] {
        guard offset >= 0, length > 0, offset + length <= data.count else { return [] }
        var raw = data.subdata(in: offset..<(offset + length))
        if internalCompression == 2, let inflated = Inflate.gunzip(raw) { raw = inflated }

        var reader = BinaryReader(raw)
        let count = Int(try reader.readVarint())
        guard count > 0, count < 5_000_000 else { return [] }

        var ids = [UInt64](repeating: 0, count: count)
        var running: UInt64 = 0
        for index in 0..<count {
            running += try reader.readVarint()
            ids[index] = running
        }

        var runs = [UInt32](repeating: 0, count: count)
        for index in 0..<count { runs[index] = UInt32(truncatingIfNeeded: try reader.readVarint()) }

        var lengths = [UInt32](repeating: 0, count: count)
        for index in 0..<count { lengths[index] = UInt32(truncatingIfNeeded: try reader.readVarint()) }

        var offsets = [UInt64](repeating: 0, count: count)
        for index in 0..<count {
            let value = try reader.readVarint()
            // 0 means "immediately after the previous entry", which is what makes
            // a clustered archive compact.
            offsets[index] = value == 0 && index > 0
                ? offsets[index - 1] + UInt64(lengths[index - 1])
                : value - 1
        }

        return (0..<count).map {
            Entry(tileID: ids[$0], runLength: runs[$0], offset: offsets[$0], length: lengths[$0])
        }
    }

    /// The last entry whose id is at or below the target, honouring run lengths.
    static func find(_ target: UInt64, in entries: [Entry]) -> Entry? {
        var low = 0
        var high = entries.count - 1
        var found: Entry?
        while low <= high {
            let middle = (low + high) / 2
            if entries[middle].tileID <= target {
                found = entries[middle]
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        guard let found else { return nil }
        if found.runLength == 0 { return found }
        return target < found.tileID + UInt64(found.runLength) ? found : nil
    }

    /// Tile id on the Hilbert curve: every tile at every lower zoom comes first,
    /// then this tile's position along the curve at its own zoom.
    static func hilbertIndex(z: Int, x: Int, y: Int) -> UInt64 {
        var accumulated: UInt64 = 0
        for level in 0..<z { accumulated += UInt64(1) << (2 * level) }

        var rx = 0
        var ry = 0
        var position: UInt64 = 0
        var tx = x
        var ty = y
        var side = 1 << (z - 1)

        while side > 0 {
            rx = (tx & side) > 0 ? 1 : 0
            ry = (ty & side) > 0 ? 1 : 0
            position += UInt64(side) * UInt64(side) * UInt64((3 * rx) ^ ry)

            // Rotate the quadrant so the curve stays continuous across it.
            if ry == 0 {
                if rx == 1 {
                    tx = side - 1 - tx
                    ty = side - 1 - ty
                }
                swap(&tx, &ty)
            }
            side /= 2
        }
        return accumulated + position
    }
}

// MARK: - Inflate

/// gzip and zlib, through the system's own libz.
enum Inflate {
    static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }

        var stream = z_stream()
        // 16 + MAX_WBITS asks for gzip framing; 32 + would auto-detect either.
        guard inflateInit2_(&stream, 32 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var input = [UInt8](data)

        return input.withUnsafeMutableBufferPointer { inputBuffer -> Data? in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(out.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }

                if status == Z_STREAM_END { return output }
                guard status == Z_OK || status == Z_BUF_ERROR else { return nil }
                if status == Z_BUF_ERROR, produced == 0 { return output.isEmpty ? nil : output }
                if stream.avail_in == 0, produced == 0 { return output.isEmpty ? nil : output }
            }
        }
    }

    /// Raw zlib, which is what an OSM PBF blob uses.
    static func zlib(_ data: Data, expecting size: Int) -> Data? {
        guard !data.isEmpty, size > 0 else { return nil }

        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        var output = [UInt8](repeating: 0, count: size)
        var input = [UInt8](data)

        let status: Int32 = input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = uInt(inputBuffer.count)
            return output.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK else { return nil }
        return Data(output)
    }
}
