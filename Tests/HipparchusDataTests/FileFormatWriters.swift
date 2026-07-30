import Foundation
import SQLite3
import HipparchusGeometry
@testable import HipparchusData

/// Writers that build each format byte by byte, for the readers to be tested on.
///
/// Deliberately not recorded fixtures. A blob nobody can inspect tells you a reader
/// changed but not what it should have done; a writer spelled out to the published
/// layout puts the specification in the repository beside the code that reads it —
/// the same reasoning as `encodeTerrariumPNG` beside the terrarium decoder.

// MARK: - Protobuf

/// Just enough protobuf to write the two schemas under test.
enum ProtobufWriter {

    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    static func zigZag(_ value: Int64) -> [UInt8] {
        varint(UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    static func tag(_ field: Int, _ wire: Int) -> [UInt8] {
        varint(UInt64(field << 3 | wire))
    }

    static func lengthDelimited(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ field: Int, _ text: String) -> [UInt8] {
        lengthDelimited(field, Array(text.utf8))
    }

    static func varintField(_ field: Int, _ value: UInt64) -> [UInt8] {
        tag(field, 0) + varint(value)
    }

    static func packed(_ field: Int, _ values: [UInt64]) -> [UInt8] {
        lengthDelimited(field, values.flatMap(varint))
    }

    static func packedZigZag(_ field: Int, _ values: [Int64]) -> [UInt8] {
        lengthDelimited(field, values.flatMap(zigZag))
    }
}

extension MVT {
    /// The encoder matching `zigZag`, so tests can state a command stream in the
    /// coordinates they mean rather than in encoded integers.
    static func zigZagEncode(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }
}

// MARK: - Vector tiles

enum MVTWriter {

    /// One tile holding one square building in a `buildings` layer.
    static func oneBuilding() -> Data {
        // A ring near the middle of the tile, in the 4096 extent grid.
        let commands: [UInt64] = [
            9, MVT.zigZagEncode(2000), MVT.zigZagEncode(2000),   // MoveTo
            18, MVT.zigZagEncode(100), MVT.zigZagEncode(0),      // LineTo x2
            MVT.zigZagEncode(0), MVT.zigZagEncode(100),
            15,                                                   // ClosePath
        ]

        let feature = ProtobufWriter.packed(2, [0, 0])            // tags: key 0, value 0
            + ProtobufWriter.varintField(3, 3)                    // type: polygon
            + ProtobufWriter.packed(4, commands)                  // geometry

        let layer = ProtobufWriter.string(1, "buildings")
            + ProtobufWriter.lengthDelimited(2, feature)
            + ProtobufWriter.string(3, "building")                // keys[0]
            + ProtobufWriter.lengthDelimited(4, ProtobufWriter.string(1, "yes"))  // values[0]
            + ProtobufWriter.varintField(5, 4096)                 // extent

        return Data(ProtobufWriter.lengthDelimited(3, layer))
    }
}

enum MBTilesWriter {

    static func write(to path: URL, zoom: Int, x: Int, y: Int, tile: Data) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK else {
            throw FileSourceError(source: path.lastPathComponent, reason: "could not create the database")
        }
        defer { sqlite3_close(handle) }

        sqlite3_exec(handle, """
            CREATE TABLE tiles (
              zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB
            );
            """, nil, nil, nil)

        var statement: OpaquePointer?
        let sql = "INSERT INTO tiles VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw FileSourceError(source: path.lastPathComponent, reason: "could not prepare the insert")
        }
        defer { sqlite3_finalize(statement) }

        // Written flipped, because that is what the format says: TMS counts rows
        // from the south.
        let flipped = (1 << zoom) - 1 - y
        sqlite3_bind_int(statement, 1, Int32(zoom))
        sqlite3_bind_int(statement, 2, Int32(x))
        sqlite3_bind_int(statement, 3, Int32(flipped))
        _ = tile.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(tile.count), nil)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FileSourceError(source: path.lastPathComponent, reason: "could not insert the tile")
        }
    }
}

// MARK: - Shapefile

enum ShapefileWriter {

    /// A point shapefile with a `.dbf` of names beside it, which is the shape
    /// Natural Earth's populated-places layer takes.
    static func write(to path: URL, points: [(Coordinate, String)]) throws -> URL {
        var shp: [UInt8] = []

        func bigEndian32(_ value: Int32) -> [UInt8] {
            let raw = UInt32(bitPattern: value)
            return [24, 16, 8, 0].map { UInt8((raw >> $0) & 0xFF) }
        }
        func littleEndian32(_ value: Int32) -> [UInt8] {
            let raw = UInt32(bitPattern: value)
            return [0, 8, 16, 24].map { UInt8((raw >> $0) & 0xFF) }
        }
        func double(_ value: Double) -> [UInt8] {
            let raw = value.bitPattern
            return (0..<8).map { UInt8((raw >> (8 * $0)) & 0xFF) }
        }

        // 100-byte header. File code is big-endian; everything after byte 28 is not.
        shp += bigEndian32(9994)
        shp += [UInt8](repeating: 0, count: 20)
        shp += bigEndian32(0)                 // file length, unused by the reader
        shp += littleEndian32(1000)           // version
        shp += littleEndian32(1)              // shape type: point
        for _ in 0..<8 { shp += double(0) }   // bounding box and z/m range

        for (index, item) in points.enumerated() {
            let content = littleEndian32(1) + double(item.0.lon) + double(item.0.lat)
            shp += bigEndian32(Int32(index + 1))
            shp += bigEndian32(Int32(content.count / 2))  // in 16-bit words
            shp += content
        }
        try Data(shp).write(to: path)

        try writeDBase(
            to: path.deletingPathExtension().appendingPathExtension("dbf"),
            names: points.map(\.1)
        )
        return path
    }

    /// dBASE III: a header of field descriptors, then fixed-width ASCII records.
    private static func writeDBase(to path: URL, names: [String]) throws {
        let fieldLength = 32
        let recordLength = 1 + fieldLength      // deletion flag plus one field
        let headerLength = 32 + 32 + 1          // header, one descriptor, terminator

        var dbf: [UInt8] = [0x03, 125, 1, 1]    // version, then a yy/mm/dd date
        dbf += (0..<4).map { UInt8((UInt32(names.count) >> (8 * $0)) & 0xFF) }
        dbf += [UInt8(headerLength & 0xFF), UInt8(headerLength >> 8)]
        dbf += [UInt8(recordLength & 0xFF), UInt8(recordLength >> 8)]
        dbf += [UInt8](repeating: 0, count: 20)

        var descriptor = Array("NAME".utf8) + [UInt8](repeating: 0, count: 7)
        descriptor += [UInt8(ascii: "C")]                    // character field
        descriptor += [UInt8](repeating: 0, count: 4)        // field data address
        descriptor += [UInt8(fieldLength), 0]                // length, decimals
        descriptor += [UInt8](repeating: 0, count: 14)
        dbf += descriptor
        dbf += [0x0D]                                        // end of descriptors

        for name in names {
            dbf += [0x20]                                    // not deleted
            var field = Array(name.utf8).prefix(fieldLength)
            field += [UInt8](repeating: 0x20, count: fieldLength - field.count)
            dbf += field
        }
        dbf += [0x1A]                                        // end of file
        try Data(dbf).write(to: path)
    }
}

// MARK: - OSM PBF

enum OSMPBFWriter {

    /// A `PrimitiveBlock` with four dense nodes and one way.
    ///
    /// The first node carries tags; the rest do not, which is the shape a real
    /// extract takes and the case the run-together tag list exists for.
    static func primitiveBlock(closedBuilding: Bool = false) -> Data {
        let strings = ["", "place", "city", "name", "Athina", "highway", "residential", "building", "yes"]
        let stringTable = strings.flatMap { ProtobufWriter.string(1, $0) }

        // Coordinates are in units of granularity (100 nanodegrees by default).
        func nano(_ degrees: Double) -> Int64 { Int64((degrees * 1e9 / 100).rounded()) }

        let latitudes = [nano(37.98), nano(37.90), nano(37.91), nano(37.92)]
        let longitudes = [nano(23.73), nano(23.70), nano(23.71), nano(23.70)]

        func deltas(_ values: [Int64]) -> [Int64] {
            var running: Int64 = 0
            return values.map { value in
                defer { running = value }
                return value - running
            }
        }

        // keys_vals: node 0 has place=city and name=Athina, then a zero; each of
        // the others is a bare zero.
        let keysVals: [UInt64] = [1, 2, 3, 4, 0, 0, 0, 0]

        let dense = ProtobufWriter.packedZigZag(1, deltas([1, 2, 3, 4]))
            + ProtobufWriter.packedZigZag(8, deltas(latitudes))
            + ProtobufWriter.packedZigZag(9, deltas(longitudes))
            + ProtobufWriter.packed(10, keysVals)

        // A way over nodes 2, 3, 4 — closed back to 2 when it is a building.
        let refs: [Int64] = closedBuilding ? [2, 3, 4, 2] : [2, 3, 4]
        var running: Int64 = 0
        let refDeltas = refs.map { value -> Int64 in
            defer { running = value }
            return value - running
        }
        let way = ProtobufWriter.varintField(1, 100)
            + ProtobufWriter.packed(2, closedBuilding ? [7] : [5])   // keys
            + ProtobufWriter.packed(3, closedBuilding ? [8] : [6])   // vals
            + ProtobufWriter.packedZigZag(8, refDeltas)

        let group = ProtobufWriter.lengthDelimited(2, dense)
            + ProtobufWriter.lengthDelimited(3, way)

        return Data(
            ProtobufWriter.lengthDelimited(1, stringTable)
                + ProtobufWriter.lengthDelimited(2, group)
        )
    }

    /// A whole file: an `OSMHeader` blob, then one `OSMData` blob.
    static func write(to path: URL, closedBuilding: Bool = false) throws {
        var file: [UInt8] = []

        func blob(type: String, body: Data) -> [UInt8] {
            // Stored raw rather than deflated: the reader accepts either, and a
            // raw blob is one less thing between the test and what it is testing.
            let payload = ProtobufWriter.lengthDelimited(1, [UInt8](body))
                + ProtobufWriter.varintField(2, UInt64(body.count))
            let header = ProtobufWriter.string(1, type)
                + ProtobufWriter.varintField(3, UInt64(payload.count))

            let length = UInt32(header.count)
            return [24, 16, 8, 0].map { UInt8((length >> $0) & 0xFF) } + header + payload
        }

        file += blob(type: "OSMHeader", body: Data(ProtobufWriter.string(4, "OsmSchema-V0.6")))
        file += blob(type: "OSMData", body: primitiveBlock(closedBuilding: closedBuilding))
        try Data(file).write(to: path)
    }
}
