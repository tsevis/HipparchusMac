import Foundation

/// A bounds-checked cursor over bytes.
///
/// Every file format below this is binary and none of them is trusted: a truncated
/// shapefile, a vector tile with a bad varint, an OSM extract that stops mid-blob.
/// Reading through one cursor that refuses to run off the end turns all of those
/// from a crash into an error with a position in it.
struct BinaryReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.bytes = [UInt8](data)
        self.offset = offset
    }

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var count: Int { bytes.count }
    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func seek(to position: Int) throws {
        guard position >= 0, position <= bytes.count else {
            throw BinaryError.outOfBounds(at: position, of: bytes.count)
        }
        offset = position
    }

    mutating func skip(_ amount: Int) throws {
        try seek(to: offset + amount)
    }

    mutating func read(_ amount: Int) throws -> ArraySlice<UInt8> {
        guard amount >= 0, offset + amount <= bytes.count else {
            throw BinaryError.outOfBounds(at: offset + amount, of: bytes.count)
        }
        defer { offset += amount }
        return bytes[offset..<(offset + amount)]
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw BinaryError.outOfBounds(at: offset, of: bytes.count)
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    // MARK: - Fixed width

    /// Shapefiles mix byte orders *within one header*, so both are spelled out
    /// rather than assumed.
    mutating func readUInt32(bigEndian: Bool = false) throws -> UInt32 {
        let slice = try read(4)
        var value: UInt32 = 0
        if bigEndian {
            for byte in slice { value = (value << 8) | UInt32(byte) }
        } else {
            for (shift, byte) in slice.enumerated() { value |= UInt32(byte) << (8 * shift) }
        }
        return value
    }

    mutating func readInt32(bigEndian: Bool = false) throws -> Int32 {
        Int32(bitPattern: try readUInt32(bigEndian: bigEndian))
    }

    mutating func readUInt64(bigEndian: Bool = false) throws -> UInt64 {
        let slice = try read(8)
        var value: UInt64 = 0
        if bigEndian {
            for byte in slice { value = (value << 8) | UInt64(byte) }
        } else {
            for (shift, byte) in slice.enumerated() { value |= UInt64(byte) << (8 * shift) }
        }
        return value
    }

    mutating func readUInt16(bigEndian: Bool = false) throws -> UInt16 {
        let slice = try read(2)
        let first = slice[slice.startIndex]
        let second = slice[slice.startIndex + 1]
        return bigEndian
            ? (UInt16(first) << 8) | UInt16(second)
            : (UInt16(second) << 8) | UInt16(first)
    }

    mutating func readDouble(bigEndian: Bool = false) throws -> Double {
        Double(bitPattern: try readUInt64(bigEndian: bigEndian))
    }

    // MARK: - Varints

    /// Protocol Buffers base-128 varint. Used by vector tiles and by OSM PBF.
    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readByte()
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else { throw BinaryError.malformed("varint longer than 64 bits") }
        }
        return value
    }

    /// Zig-zag, which is how both formats carry signed numbers: small negatives
    /// stay one byte instead of becoming ten.
    mutating func readZigZag() throws -> Int64 {
        let raw = try readVarint()
        return Int64(bitPattern: (raw >> 1)) ^ -Int64(bitPattern: raw & 1)
    }
}

enum BinaryError: Error, CustomStringConvertible {
    case outOfBounds(at: Int, of: Int)
    case malformed(String)

    var description: String {
        switch self {
        case .outOfBounds(let at, let of): "read past the end of the data at \(at) of \(of) bytes"
        case .malformed(let reason): "malformed data: \(reason)"
        }
    }
}
