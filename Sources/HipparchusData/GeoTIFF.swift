import Foundation
import HipparchusGeometry

/// Enough of GeoTIFF to read a depth grid, and no more.
///
/// **Written here because Swift has none of it**, the same reason `MVT`,
/// `OSMPBFReader`, `ShapefileReader` and the PMTiles reader are written here.
/// A general GeoTIFF reader is a large thing — a dozen compressions, tiled and
/// stripped, planar and chunky, colour maps, sub-files, BigTIFF. This is the
/// subset that a coverage service actually returns, and it refuses the rest by
/// name rather than by producing a grid of nonsense.
///
/// What decided the subset was looking at what EMODnet's WCS answers with:
/// uncompressed, one sample per pixel, IEEE float32, tiled, north-up, EPSG:4326.
/// That is the easiest possible GeoTIFF, and it is why this file is short enough
/// to be worth having rather than a reason to make the user run GDAL first.
///
/// Integer samples are handled too, because a service is entitled to change its
/// mind about that and the cost of supporting it is a switch.
public struct GeoTIFFGrid: Sendable {
    /// Row 0 is north, matching `Field2D` everywhere else here.
    public let field: Field2D
    public let bounds: BoundingBox
}

public enum GeoTIFFError: Error, CustomStringConvertible, Equatable {
    case notATIFF
    case truncated
    case unsupported(String)
    case noGeoreference

    public var description: String {
        switch self {
        case .notATIFF: "not a TIFF: the file does not begin with II* or MM*"
        case .truncated: "the file ends in the middle of something"
        case .unsupported(let what): "this reader does not handle \(what)"
        case .noGeoreference:
            "the image carries no ModelTransformation and no tie point, so there "
            + "is no way to say where on Earth it is"
        }
    }
}

public enum GeoTIFF {

    // The tags this reader looks at. Everything else in the directory is skipped.
    private enum Tag: UInt16 {
        case imageWidth = 256, imageLength = 257, bitsPerSample = 258
        case compression = 259, photometric = 262
        case stripOffsets = 273, samplesPerPixel = 277, rowsPerStrip = 278
        case stripByteCounts = 279
        case planarConfiguration = 284
        case tileWidth = 322, tileLength = 323, tileOffsets = 324, tileByteCounts = 325
        case sampleFormat = 339
        case modelPixelScale = 33550, modelTiepoint = 33922, modelTransformation = 34264
        case gdalNoData = 42113
    }

    private struct Entry {
        let type: UInt16
        let count: Int
        /// The raw four bytes: either the value itself or where to find it.
        let payload: UInt32
    }

    public static func read(_ data: Data) throws -> GeoTIFFGrid {
        var reader = BinaryReader(data)

        let byteOrder = try reader.readUInt16()
        let bigEndian: Bool
        switch byteOrder {
        case 0x4949: bigEndian = false   // "II"
        case 0x4D4D: bigEndian = true    // "MM"
        default: throw GeoTIFFError.notATIFF
        }
        guard try reader.readUInt16(bigEndian: bigEndian) == 42 else {
            // 43 is BigTIFF, which is a different layout rather than a bigger one.
            throw GeoTIFFError.notATIFF
        }

        let directoryOffset = Int(try reader.readUInt32(bigEndian: bigEndian))
        var entries: [UInt16: Entry] = [:]
        try reader.seek(to: directoryOffset)
        let count = Int(try reader.readUInt16(bigEndian: bigEndian))
        for _ in 0..<count {
            let tag = try reader.readUInt16(bigEndian: bigEndian)
            let type = try reader.readUInt16(bigEndian: bigEndian)
            let valueCount = Int(try reader.readUInt32(bigEndian: bigEndian))
            let payload = try reader.readUInt32(bigEndian: bigEndian)
            entries[tag] = Entry(type: type, count: valueCount, payload: payload)
        }

        func integers(_ tag: Tag) throws -> [Int] {
            guard let entry = entries[tag.rawValue] else { return [] }
            return try readIntegers(entry, from: data, bigEndian: bigEndian)
        }
        func integer(_ tag: Tag) throws -> Int? { try integers(tag).first }
        func doubles(_ tag: Tag) throws -> [Double] {
            guard let entry = entries[tag.rawValue] else { return [] }
            return try readDoubles(entry, from: data, bigEndian: bigEndian)
        }

        guard let columns = try integer(.imageWidth), let rows = try integer(.imageLength),
              columns > 0, rows > 0 else {
            throw GeoTIFFError.unsupported("an image with no size")
        }

        let compression = try integer(.compression) ?? 1
        guard compression == 1 else {
            throw GeoTIFFError.unsupported("compression \(compression) — ask the service for an uncompressed coverage")
        }
        let samples = try integer(.samplesPerPixel) ?? 1
        guard samples == 1 else {
            throw GeoTIFFError.unsupported("\(samples) samples per pixel; this reads a single band")
        }
        if let planar = try integer(.planarConfiguration), planar != 1 {
            throw GeoTIFFError.unsupported("planar configuration \(planar)")
        }

        let bits = try integer(.bitsPerSample) ?? 8
        // 1 unsigned, 2 signed, 3 float. Absent means unsigned, which is the
        // default the specification states.
        let format = try integer(.sampleFormat) ?? 1
        let sample = try SampleKind(bits: bits, format: format)

        let noData = try noDataValue(entries[Tag.gdalNoData.rawValue], from: data, bigEndian: bigEndian)

        // MARK: The pixels

        var values = ContiguousArray<Double>(repeating: .nan, count: rows * columns)

        let tileWidth = try integer(.tileWidth)
        let tileLength = try integer(.tileLength)
        if let tileWidth, let tileLength, tileWidth > 0, tileLength > 0 {
            let offsets = try integers(.tileOffsets)
            let across = (columns + tileWidth - 1) / tileWidth
            for (index, offset) in offsets.enumerated() {
                let originColumn = (index % across) * tileWidth
                let originRow = (index / across) * tileLength
                try readBlock(
                    from: data, at: offset, sample: sample, bigEndian: bigEndian,
                    blockRows: tileLength, blockColumns: tileWidth,
                    originRow: originRow, originColumn: originColumn,
                    rows: rows, columns: columns, noData: noData, into: &values
                )
            }
        } else {
            let offsets = try integers(.stripOffsets)
            guard !offsets.isEmpty else { throw GeoTIFFError.unsupported("an image with no pixels") }
            let perStrip = try integer(.rowsPerStrip) ?? rows
            for (index, offset) in offsets.enumerated() {
                try readBlock(
                    from: data, at: offset, sample: sample, bigEndian: bigEndian,
                    blockRows: perStrip, blockColumns: columns,
                    originRow: index * perStrip, originColumn: 0,
                    rows: rows, columns: columns, noData: noData, into: &values
                )
            }
        }

        // MARK: Where on Earth it is

        let bounds = try georeference(
            transformation: try doubles(.modelTransformation),
            pixelScale: try doubles(.modelPixelScale),
            tiepoint: try doubles(.modelTiepoint),
            rows: rows, columns: columns
        )

        return GeoTIFFGrid(
            field: Field2D(rows: rows, columns: columns, values: values),
            bounds: bounds
        )
    }

    // MARK: - Samples

    enum SampleKind {
        case float32, float64, int16, uint16, int32, uint32, uint8, int8

        var bytes: Int {
            switch self {
            case .float64, .int32, .uint32: self == .float64 ? 8 : 4
            case .float32: 4
            case .int16, .uint16: 2
            case .uint8, .int8: 1
            }
        }

        init(bits: Int, format: Int) throws {
            switch (bits, format) {
            case (32, 3): self = .float32
            case (64, 3): self = .float64
            case (16, 2): self = .int16
            case (16, 1): self = .uint16
            case (32, 2): self = .int32
            case (32, 1): self = .uint32
            case (8, 1): self = .uint8
            case (8, 2): self = .int8
            default:
                throw GeoTIFFError.unsupported("\(bits)-bit samples of format \(format)")
            }
        }
    }

    /// One tile or strip, written into the grid at its own corner.
    ///
    /// A tile's edge runs past the image when the image is not a whole number of
    /// tiles wide — the Cyprus coverage is 200 columns in 208-wide tiles — so
    /// the parts that fall outside are read and dropped rather than wrapping
    /// onto the next row, which is the classic way to produce a sheared map.
    private static func readBlock(
        from data: Data, at offset: Int, sample: SampleKind, bigEndian: Bool,
        blockRows: Int, blockColumns: Int,
        originRow: Int, originColumn: Int,
        rows: Int, columns: Int, noData: Double?,
        into values: inout ContiguousArray<Double>
    ) throws {
        var reader = BinaryReader(data)
        try reader.seek(to: offset)
        for row in 0..<blockRows {
            let target = originRow + row
            for column in 0..<blockColumns {
                let value = try readSample(&reader, sample, bigEndian: bigEndian)
                let targetColumn = originColumn + column
                guard target < rows, targetColumn < columns else { continue }
                values[target * columns + targetColumn] = clean(value, noData: noData)
            }
        }
    }

    private static func readSample(
        _ reader: inout BinaryReader, _ kind: SampleKind, bigEndian: Bool
    ) throws -> Double {
        switch kind {
        case .float32:
            return Double(Float(bitPattern: try reader.readUInt32(bigEndian: bigEndian)))
        case .float64:
            return try reader.readDouble(bigEndian: bigEndian)
        case .int16:
            return Double(Int16(bitPattern: try reader.readUInt16(bigEndian: bigEndian)))
        case .uint16:
            return Double(try reader.readUInt16(bigEndian: bigEndian))
        case .int32:
            return Double(Int32(bitPattern: try reader.readUInt32(bigEndian: bigEndian)))
        case .uint32:
            return Double(try reader.readUInt32(bigEndian: bigEndian))
        case .uint8:
            return Double(try reader.readByte())
        case .int8:
            return Double(Int8(bitPattern: try reader.readByte()))
        }
    }

    /// A missing cell has to *stay* missing all the way through, because the
    /// contour tracer and the band sampler both read NaN as "no ground here" and
    /// anything else as a depth. A no-data sentinel left as -32767 would draw a
    /// trench thirty-two kilometres deep along every coastline.
    static func clean(_ value: Double, noData: Double?) -> Double {
        guard value.isFinite else { return .nan }
        if let noData, abs(value - noData) < 1e-6 { return .nan }
        // Beyond the deepest trench and the highest summit by a wide margin.
        // Services differ about their sentinel and some state none at all.
        guard value > -12_000, value < 9_500 else { return .nan }
        return value
    }

    private static func noDataValue(
        _ entry: Entry?, from data: Data, bigEndian: Bool
    ) throws -> Double? {
        guard let entry, entry.type == 2, entry.count > 0 else { return nil }
        let bytes: [UInt8]
        if entry.count <= 4 {
            bytes = withUnsafeBytes(of: bigEndian ? entry.payload.bigEndian : entry.payload.littleEndian) {
                Array($0.prefix(entry.count))
            }
        } else {
            var reader = BinaryReader(data)
            try reader.seek(to: Int(entry.payload))
            bytes = Array(try reader.read(entry.count))
        }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return Double(text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Georeference

    /// The image's corners in longitude and latitude.
    ///
    /// Two ways of saying the same thing, and a coverage service may use either:
    /// a full 4×4 `ModelTransformation`, or a pixel scale plus one tie point.
    /// Rotation is refused rather than ignored — a rotated grid read as an
    /// north-up one is a map of somewhere else.
    static func georeference(
        transformation: [Double], pixelScale: [Double], tiepoint: [Double],
        rows: Int, columns: Int
    ) throws -> BoundingBox {
        if transformation.count >= 16 {
            let scaleX = transformation[0], rotationX = transformation[1]
            let rotationY = transformation[4], scaleY = transformation[5]
            let originX = transformation[3], originY = transformation[7]
            guard abs(rotationX) < 1e-12, abs(rotationY) < 1e-12 else {
                throw GeoTIFFError.unsupported("a rotated grid")
            }
            return box(originX: originX, originY: originY,
                       scaleX: scaleX, scaleY: scaleY, rows: rows, columns: columns)
        }

        if pixelScale.count >= 2, tiepoint.count >= 6 {
            // The tie point maps a raster point to a model point; the usual one
            // is raster (0,0) — the outer corner of the top-left pixel.
            let originX = tiepoint[3], originY = tiepoint[4]
            return box(originX: originX, originY: originY,
                       scaleX: pixelScale[0], scaleY: -abs(pixelScale[1]),
                       rows: rows, columns: columns)
        }

        throw GeoTIFFError.noGeoreference
    }

    private static func box(
        originX: Double, originY: Double, scaleX: Double, scaleY: Double,
        rows: Int, columns: Int
    ) -> BoundingBox {
        let farX = originX + scaleX * Double(columns)
        let farY = originY + scaleY * Double(rows)
        return BoundingBox(
            minLon: Swift.min(originX, farX), minLat: Swift.min(originY, farY),
            maxLon: Swift.max(originX, farX), maxLat: Swift.max(originY, farY)
        )
    }

    // MARK: - Directory values

    private static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12: 8
        default: 0
        }
    }

    private static func readIntegers(
        _ entry: Entry, from data: Data, bigEndian: Bool
    ) throws -> [Int] {
        let size = typeSize(entry.type)
        guard size > 0 else { return [] }
        // Four bytes or fewer live in the directory entry itself.
        if entry.count * size <= 4 {
            var out: [Int] = []
            let raw = bigEndian ? entry.payload.bigEndian : entry.payload.littleEndian
            var bytes = withUnsafeBytes(of: raw) { Array($0) }
            if !bigEndian { bytes = withUnsafeBytes(of: entry.payload.littleEndian) { Array($0) } }
            var reader = BinaryReader(bytes)
            for _ in 0..<entry.count {
                out.append(Int(try scalar(&reader, type: entry.type, bigEndian: bigEndian)))
            }
            return out
        }
        var reader = BinaryReader(data)
        try reader.seek(to: Int(entry.payload))
        var out: [Int] = []
        for _ in 0..<entry.count {
            out.append(Int(try scalar(&reader, type: entry.type, bigEndian: bigEndian)))
        }
        return out
    }

    private static func scalar(
        _ reader: inout BinaryReader, type: UInt16, bigEndian: Bool
    ) throws -> UInt64 {
        switch type {
        case 1, 2, 6, 7: UInt64(try reader.readByte())
        case 3, 8: UInt64(try reader.readUInt16(bigEndian: bigEndian))
        case 4, 9: UInt64(try reader.readUInt32(bigEndian: bigEndian))
        case 16, 17: try reader.readUInt64(bigEndian: bigEndian)
        default: throw GeoTIFFError.unsupported("directory type \(type)")
        }
    }

    private static func readDoubles(
        _ entry: Entry, from data: Data, bigEndian: Bool
    ) throws -> [Double] {
        guard entry.type == 12 else { return [] }
        var reader = BinaryReader(data)
        try reader.seek(to: Int(entry.payload))
        var out: [Double] = []
        for _ in 0..<entry.count {
            out.append(try reader.readDouble(bigEndian: bigEndian))
        }
        return out
    }
}
