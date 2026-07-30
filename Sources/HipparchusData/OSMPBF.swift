import Foundation
import HipparchusGeometry

/// Read an `.osm.pbf` extract.
///
/// Replaces the Python's `osmium` dependency.
///
/// The file is a sequence of length-prefixed blobs, each a zlib-compressed
/// protobuf. Inside are *primitive groups* of nodes, ways and relations. Two things
/// make it compact and awkward in equal measure:
///
/// - **Dense nodes.** Almost every node in an extract is untagged, so they are not
///   stored as messages at all: ids, latitudes, longitudes and tags arrive as four
///   parallel delta-encoded arrays, with the tags run together in one list
///   separated by zeros.
/// - **Ways reference nodes by id**, so a way cannot be drawn until its nodes are
///   known. That is why this reads in two passes.
///
/// The two passes are the cost of not holding a continent in memory: the first
/// keeps only the ids a way actually asks for, the second fills in their positions.
public enum OSMPBFReader {

    /// A guard against opening a planet file by accident. A country extract is
    /// comfortably inside this; the planet is a hundred times over.
    public static let maximumNodes = 12_000_000

    public static func features(
        at path: URL,
        bbox: BoundingBox,
        providerID: String
    ) throws -> [Feature] {
        let data = try Data(contentsOf: path)
        let blobs = try blobs(in: data)

        // Pass one: which node ids the ways in range need, and every tagged node
        // that is itself in range.
        var wanted = Set<Int64>()
        var features: [Feature] = []
        var pendingWays: [(id: Int64, refs: [Int64], tags: [String: String])] = []

        for blob in blobs {
            guard let block = try? primitiveBlock(blob) else { continue }
            for group in block.groups {
                for node in group.nodes where bbox.bounds.contains(node.coordinate) {
                    guard !node.tags.isEmpty else { continue }
                    append(&features, tags: node.tags, geometry: .point(node.coordinate),
                           providerID: providerID, osmID: "node/\(node.id)")
                }
                for way in group.ways where !way.refs.isEmpty {
                    pendingWays.append(way)
                    wanted.formUnion(way.refs)
                }
            }
            guard wanted.count <= maximumNodes else {
                throw FileSourceError(
                    source: path.lastPathComponent,
                    reason: "extract is too large — \(wanted.count) nodes and counting"
                )
            }
        }

        // Pass two: the positions of exactly those ids.
        var positions: [Int64: Coordinate] = [:]
        positions.reserveCapacity(wanted.count)
        for blob in blobs {
            guard let block = try? primitiveBlock(blob) else { continue }
            for group in block.groups {
                for node in group.nodes where wanted.contains(node.id) {
                    positions[node.id] = node.coordinate
                }
            }
        }

        for way in pendingWays {
            let coordinates = way.refs.compactMap { positions[$0] }
            guard coordinates.count >= 2 else { continue }

            let closed = coordinates.count >= 4 && coordinates.first == coordinates.last
            let geometry: Geometry = closed && OverpassDecode.canBePolygon(tags: way.tags)
                ? .polygon(Polygon(exterior: coordinates))
                : .lineString(LineString(coordinates))

            // Bounds against the frame rather than "any vertex inside": a way
            // crossing the frame may place no vertex in it.
            guard let bounds = geometry.bounds, bounds.intersects(bbox.bounds) else { continue }
            append(&features, tags: way.tags, geometry: geometry,
                   providerID: providerID, osmID: "way/\(way.id)")
        }

        return features
    }

    private static func append(
        _ features: inout [Feature],
        tags: [String: String],
        geometry: Geometry,
        providerID: String,
        osmID: String
    ) {
        let properties = OverpassDecode.properties(from: tags)
        guard let layer = FileLayer.forProperties(
            properties, providerID: providerID, geometry: geometry
        ) else {
            return
        }
        features.append(Feature(
            id: "\(providerID)/\(osmID)",
            layer: layer,
            source: providerID,
            geometry: geometry,
            provenance: .measured,
            properties: properties
        ))
    }

    // MARK: - Blobs

    /// Each blob is a big-endian length, a `BlobHeader`, then a `Blob`.
    static func blobs(in data: Data) throws -> [Data] {
        var reader = BinaryReader(data)
        var payloads: [Data] = []

        while reader.remaining > 4 {
            let headerLength = Int(try reader.readUInt32(bigEndian: true))
            guard headerLength > 0, headerLength < 64 * 1024, reader.remaining >= headerLength else { break }

            let header = Data(try reader.read(headerLength))
            var headerReader = BinaryReader(header)
            var type = ""
            var bodyLength = 0
            while !headerReader.isAtEnd {
                let (field, wire) = try MVT.tag(&headerReader)
                switch (field, wire) {
                case (1, 2):  // type
                    let length = Int(try headerReader.readVarint())
                    type = String(decoding: Array(try headerReader.read(length)), as: UTF8.self)
                case (3, 0):  // datasize
                    bodyLength = Int(try headerReader.readVarint())
                default:
                    try MVT.skip(&headerReader, wire: wire)
                }
            }

            guard bodyLength > 0, reader.remaining >= bodyLength else { break }
            let body = Data(try reader.read(bodyLength))
            // The first blob is an `OSMHeader` carrying bounds and required
            // features; only the data blocks hold geometry.
            guard type == "OSMData" else { continue }
            if let payload = try? decoded(blob: body) { payloads.append(payload) }
        }
        return payloads
    }

    /// A blob is either raw or zlib-compressed, and says which.
    static func decoded(blob data: Data) throws -> Data {
        var reader = BinaryReader(data)
        var raw: Data?
        var zlibData: Data?
        var rawSize = 0

        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            switch (field, wire) {
            case (1, 2):  // raw
                let length = Int(try reader.readVarint())
                raw = Data(try reader.read(length))
            case (2, 0):  // raw_size
                rawSize = Int(try reader.readVarint())
            case (3, 2):  // zlib_data
                let length = Int(try reader.readVarint())
                zlibData = Data(try reader.read(length))
            default:
                try MVT.skip(&reader, wire: wire)
            }
        }

        if let raw { return raw }
        guard let zlibData, rawSize > 0, let inflated = Inflate.zlib(zlibData, expecting: rawSize) else {
            throw BinaryError.malformed("blob is neither raw nor zlib, or would not inflate")
        }
        return inflated
    }

    // MARK: - Primitive blocks

    struct Node {
        let id: Int64
        let coordinate: Coordinate
        let tags: [String: String]
    }

    struct Group {
        var nodes: [Node] = []
        var ways: [(id: Int64, refs: [Int64], tags: [String: String])] = []
    }

    struct Block {
        let groups: [Group]
    }

    static func primitiveBlock(_ data: Data) throws -> Block {
        var reader = BinaryReader(data)
        var strings: [String] = []
        var groupBodies: [Data] = []
        // Coordinates are integers in units of `granularity` nanodegrees, offset by
        // lat_offset/lon_offset. Both default to values that make the common case
        // 100 nanodegrees and no offset.
        var granularity = 100.0
        var latOffset = 0.0
        var lonOffset = 0.0

        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            switch (field, wire) {
            case (1, 2):  // stringtable
                let length = Int(try reader.readVarint())
                strings = try stringTable(Data(try reader.read(length)))
            case (2, 2):  // primitivegroup
                let length = Int(try reader.readVarint())
                groupBodies.append(Data(try reader.read(length)))
            case (17, 0):  // granularity
                granularity = Double(try reader.readVarint())
            case (19, 0):  // lat_offset
                latOffset = Double(Int64(bitPattern: try reader.readVarint()))
            case (20, 0):  // lon_offset
                lonOffset = Double(Int64(bitPattern: try reader.readVarint()))
            default:
                try MVT.skip(&reader, wire: wire)
            }
        }

        let scale = Scale(granularity: granularity, latOffset: latOffset, lonOffset: lonOffset)
        return Block(groups: groupBodies.compactMap { try? group($0, strings: strings, scale: scale) })
    }

    struct Scale {
        let granularity: Double
        let latOffset: Double
        let lonOffset: Double

        /// Nanodegrees to degrees.
        func coordinate(lat: Int64, lon: Int64) -> Coordinate {
            Coordinate(
                lon: 1e-9 * (lonOffset + granularity * Double(lon)),
                lat: 1e-9 * (latOffset + granularity * Double(lat))
            )
        }
    }

    static func stringTable(_ data: Data) throws -> [String] {
        var reader = BinaryReader(data)
        var strings: [String] = []
        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            guard field == 1, wire == 2 else {
                try MVT.skip(&reader, wire: wire)
                continue
            }
            let length = Int(try reader.readVarint())
            strings.append(String(decoding: Array(try reader.read(length)), as: UTF8.self))
        }
        return strings
    }

    static func group(_ data: Data, strings: [String], scale: Scale) throws -> Group {
        var reader = BinaryReader(data)
        var group = Group()

        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            switch (field, wire) {
            case (2, 2):  // dense
                let length = Int(try reader.readVarint())
                group.nodes.append(contentsOf: try dense(
                    Data(try reader.read(length)), strings: strings, scale: scale
                ))
            case (3, 2):  // ways
                let length = Int(try reader.readVarint())
                if let way = try? way(Data(try reader.read(length)), strings: strings) {
                    group.ways.append(way)
                }
            default:
                try MVT.skip(&reader, wire: wire)
            }
        }
        return group
    }

    /// Dense nodes: four parallel delta-encoded arrays, plus one run-together tag
    /// list where a zero ends the current node's tags.
    static func dense(_ data: Data, strings: [String], scale: Scale) throws -> [Node] {
        var reader = BinaryReader(data)
        var ids: [Int64] = []
        var lats: [Int64] = []
        var lons: [Int64] = []
        var keyValues: [Int] = []

        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            switch (field, wire) {
            case (1, 2):  // id, packed zig-zag deltas
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                var running: Int64 = 0
                while !packed.isAtEnd {
                    running += try packed.readZigZag()
                    ids.append(running)
                }
            case (8, 2):  // lat
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                var running: Int64 = 0
                while !packed.isAtEnd {
                    running += try packed.readZigZag()
                    lats.append(running)
                }
            case (9, 2):  // lon
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                var running: Int64 = 0
                while !packed.isAtEnd {
                    running += try packed.readZigZag()
                    lons.append(running)
                }
            case (10, 2):  // keys_vals
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                while !packed.isAtEnd { keyValues.append(Int(try packed.readVarint())) }
            default:
                try MVT.skip(&reader, wire: wire)
            }
        }

        let count = Swift.min(ids.count, Swift.min(lats.count, lons.count))
        var nodes: [Node] = []
        nodes.reserveCapacity(count)

        var cursor = 0
        for index in 0..<count {
            var tags: [String: String] = [:]
            // A zero ends this node's tags. An empty keys_vals means no node has
            // any, which is the usual case for the bulk of an extract.
            while cursor < keyValues.count, keyValues[cursor] != 0 {
                guard cursor + 1 < keyValues.count else { break }
                let key = keyValues[cursor]
                let value = keyValues[cursor + 1]
                cursor += 2
                if key < strings.count, value < strings.count { tags[strings[key]] = strings[value] }
            }
            cursor += 1  // step over the terminating zero

            nodes.append(Node(
                id: ids[index],
                coordinate: scale.coordinate(lat: lats[index], lon: lons[index]),
                tags: tags
            ))
        }
        return nodes
    }

    static func way(
        _ data: Data,
        strings: [String]
    ) throws -> (id: Int64, refs: [Int64], tags: [String: String]) {
        var reader = BinaryReader(data)
        var id: Int64 = 0
        var keys: [Int] = []
        var values: [Int] = []
        var refs: [Int64] = []

        while !reader.isAtEnd {
            let (field, wire) = try MVT.tag(&reader)
            switch (field, wire) {
            case (1, 0):  // id
                id = Int64(bitPattern: try reader.readVarint())
            case (2, 2):  // keys, packed
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                while !packed.isAtEnd { keys.append(Int(try packed.readVarint())) }
            case (3, 2):  // vals, packed
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                while !packed.isAtEnd { values.append(Int(try packed.readVarint())) }
            case (8, 2):  // refs, packed zig-zag deltas
                let length = Int(try reader.readVarint())
                var packed = BinaryReader(Data(try reader.read(length)))
                var running: Int64 = 0
                while !packed.isAtEnd {
                    running += try packed.readZigZag()
                    refs.append(running)
                }
            default:
                try MVT.skip(&reader, wire: wire)
            }
        }

        var tags: [String: String] = [:]
        for (key, value) in zip(keys, values) where key < strings.count && value < strings.count {
            tags[strings[key]] = strings[value]
        }
        return (id, refs, tags)
    }
}
