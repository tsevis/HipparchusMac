import Foundation
import HipparchusGeometry

/// Decode a Mapbox Vector Tile.
///
/// The schema is small and fixed, so this reads the protobuf wire format directly
/// rather than generating code from a `.proto`. Field numbers are from the MVT 2.1
/// specification and are spelled out where they are used.
///
/// The interesting part is the geometry: a tile does not carry points, it carries a
/// **command stream** — MoveTo, LineTo, ClosePath — with zig-zag deltas between
/// them. That is what makes tiles small, and it is the only part of this that is
/// not bookkeeping.
public enum MVT {

    public struct Layer: Sendable {
        public let name: String
        public let extent: Int
        public let features: [TileFeature]
    }

    public struct TileFeature: Sendable {
        public let properties: [String: PropertyValue]
        public let kind: Kind
        /// Tile-local integer coordinates, in the layer's own extent grid.
        public let rings: [[Coordinate]]

        public enum Kind: UInt64, Sendable {
            case unknown = 0
            case point = 1
            case line = 2
            case polygon = 3
        }

        /// Put the tile-local coordinates back on the Earth.
        public func geometry(z: Int, x: Int, y: Int, extent: Int) -> Geometry? {
            // A tile's grid is `extent` units across — 4096 by convention — while
            // `lonLatForPixel` works in the 256-per-tile world the raster schemes
            // use. One scale factor reconciles them, rather than a second copy of
            // the projection.
            let scale = WebMercator.worldPixels(zoom: z) / (Double(1 << z) * Double(extent))
            let placed = rings.map { ring in
                ring.map { local in
                    WebMercator.lonLatForPixel(
                        // The tile grid runs y-down from the tile's north edge,
                        // the same convention as a pixel in a raster tile.
                        x: (Double(x) * Double(extent) + local.x) * scale,
                        y: (Double(y) * Double(extent) + local.y) * scale,
                        zoom: z
                    )
                }
            }

            switch kind {
            case .point:
                let points = placed.flatMap { $0 }
                guard !points.isEmpty else { return nil }
                return points.count == 1 ? .point(points[0]) : .multiPoint(points)

            case .line:
                let lines = placed.filter { $0.count >= 2 }.map { LineString($0) }
                guard !lines.isEmpty else { return nil }
                return lines.count == 1 ? .lineString(lines[0]) : .multiLineString(lines)

            case .polygon:
                let rings = placed.filter { $0.count >= 3 }.map { Ring($0) }
                guard !rings.isEmpty else { return nil }
                // MVT winding: an exterior ring is clockwise in the tile's y-down
                // grid, which is anti-clockwise once y points north — so a positive
                // signed area is an outline here.
                let outer = rings.filter { $0.signedDoubleArea > 0 }
                let inner = rings.filter { $0.signedDoubleArea <= 0 }
                guard !outer.isEmpty else {
                    return Geometry.polygons(rings.map { Polygon(exterior: $0) })
                }
                return Geometry.polygons(RingAssembly.polygons(outer: outer, inner: inner))

            case .unknown:
                return nil
            }
        }
    }

    // MARK: - Wire format

    public static func decode(_ data: Data) throws -> [Layer] {
        var reader = BinaryReader(data)
        var layers: [Layer] = []

        while !reader.isAtEnd {
            let (field, wire) = try tag(&reader)
            // Tile.layers = 3
            if field == 3, wire == 2 {
                let length = Int(try reader.readVarint())
                let body = Data(try reader.read(length))
                if let layer = try? layer(from: body) { layers.append(layer) }
            } else {
                try skip(&reader, wire: wire)
            }
        }
        return layers
    }

    static func layer(from data: Data) throws -> Layer {
        var reader = BinaryReader(data)
        var name = ""
        var extent = 4096
        var keys: [String] = []
        var values: [PropertyValue] = []
        var featureBodies: [Data] = []

        while !reader.isAtEnd {
            let (field, wire) = try tag(&reader)
            switch (field, wire) {
            case (1, 2):  // name
                let length = Int(try reader.readVarint())
                name = String(decoding: Array(try reader.read(length)), as: UTF8.self)
            case (2, 2):  // features
                let length = Int(try reader.readVarint())
                featureBodies.append(Data(try reader.read(length)))
            case (3, 2):  // keys
                let length = Int(try reader.readVarint())
                keys.append(String(decoding: Array(try reader.read(length)), as: UTF8.self))
            case (4, 2):  // values
                let length = Int(try reader.readVarint())
                values.append(try value(from: Data(try reader.read(length))))
            case (5, 0):  // extent
                extent = Int(try reader.readVarint())
            default:
                try skip(&reader, wire: wire)
            }
        }

        let features = featureBodies.compactMap { try? feature(from: $0, keys: keys, values: values) }
        return Layer(name: name, extent: Swift.max(1, extent), features: features)
    }

    /// A value is a one-of: whichever field is present is the type.
    static func value(from data: Data) throws -> PropertyValue {
        var reader = BinaryReader(data)
        while !reader.isAtEnd {
            let (field, wire) = try tag(&reader)
            switch (field, wire) {
            case (1, 2):
                let length = Int(try reader.readVarint())
                return .string(String(decoding: Array(try reader.read(length)), as: UTF8.self))
            case (2, 5):
                let bits = try reader.readUInt32()
                return .double(Double(Float(bitPattern: bits)))
            case (3, 1):
                return .double(try reader.readDouble())
            case (4, 0):
                return .int(Int(Int64(bitPattern: try reader.readVarint())))
            case (5, 0):
                return .int(Int(try reader.readVarint()))
            case (6, 0):
                return .int(Int(try reader.readZigZag()))
            case (7, 0):
                return .bool(try reader.readVarint() != 0)
            default:
                try skip(&reader, wire: wire)
            }
        }
        return .string("")
    }

    static func feature(
        from data: Data,
        keys: [String],
        values: [PropertyValue]
    ) throws -> TileFeature {
        var reader = BinaryReader(data)
        var tags: [UInt64] = []
        var kind = TileFeature.Kind.unknown
        var commands: [UInt64] = []

        while !reader.isAtEnd {
            let (field, wire) = try tag(&reader)
            switch (field, wire) {
            case (2, 2):  // tags, packed
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                while !packed.isAtEnd { tags.append(try packed.readVarint()) }
            case (3, 0):  // type
                kind = TileFeature.Kind(rawValue: try reader.readVarint()) ?? .unknown
            case (4, 2):  // geometry, packed
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                while !packed.isAtEnd { commands.append(try packed.readVarint()) }
            default:
                try skip(&reader, wire: wire)
            }
        }

        var properties: [String: PropertyValue] = [:]
        // Tags are pairs of indices into the layer's shared key and value tables.
        for pair in stride(from: 0, to: tags.count - 1, by: 2) {
            let keyIndex = Int(tags[pair])
            let valueIndex = Int(tags[pair + 1])
            guard keyIndex < keys.count, valueIndex < values.count else { continue }
            properties[keys[keyIndex]] = values[valueIndex]
        }

        return TileFeature(properties: properties, kind: kind, rings: rings(from: commands))
    }

    /// Walk the command stream.
    ///
    /// Each command word packs an id in its low three bits and a repeat count in
    /// the rest. MoveTo starts a new ring, LineTo extends it, ClosePath closes it —
    /// and every coordinate is a zig-zag delta from the one before, which is why
    /// the cursor is carried across commands rather than reset per ring.
    static func rings(from commands: [UInt64]) -> [[Coordinate]] {
        var rings: [[Coordinate]] = []
        var current: [Coordinate] = []
        var x = 0.0
        var y = 0.0
        var index = 0

        while index < commands.count {
            let word = commands[index]
            index += 1
            let id = word & 0x7
            let count = Int(word >> 3)

            switch id {
            case 1:  // MoveTo
                for _ in 0..<count {
                    guard index + 1 < commands.count else { break }
                    x += Double(zigZag(commands[index]))
                    y += Double(zigZag(commands[index + 1]))
                    index += 2
                    // A MoveTo inside a multipart feature starts the next part.
                    if !current.isEmpty { rings.append(current) }
                    current = [Coordinate(x: x, y: y)]
                }
            case 2:  // LineTo
                for _ in 0..<count {
                    guard index + 1 < commands.count else { break }
                    x += Double(zigZag(commands[index]))
                    y += Double(zigZag(commands[index + 1]))
                    index += 2
                    current.append(Coordinate(x: x, y: y))
                }
            case 7:  // ClosePath, which carries no coordinates
                if let first = current.first, current.count >= 3 { current.append(first) }
            default:
                // An unknown command means the rest of the stream cannot be trusted.
                index = commands.count
            }
        }
        if !current.isEmpty { rings.append(current) }
        return rings
    }

    static func zigZag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }

    // MARK: -

    static func tag(_ reader: inout BinaryReader) throws -> (field: UInt64, wire: UInt64) {
        let key = try reader.readVarint()
        return (key >> 3, key & 0x7)
    }

    /// Step over a field this decoder does not want.
    static func skip(_ reader: inout BinaryReader, wire: UInt64) throws {
        switch wire {
        case 0: _ = try reader.readVarint()
        case 1: try reader.skip(8)
        case 2: try reader.skip(Int(try reader.readVarint()))
        case 5: try reader.skip(4)
        default: throw BinaryError.malformed("unknown protobuf wire type \(wire)")
        }
    }
}
