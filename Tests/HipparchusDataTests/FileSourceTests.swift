import Foundation
import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// Files written in each real format, then read back through the provider.
///
/// Nothing here is a recorded fixture: every file is built byte by byte to the
/// published layout, which is what makes a failure point at the reader rather than
/// at a blob nobody can inspect.
final class FileSourceTests: XCTestCase {

    private var directory: URL!
    private let athens = BBoxQuery(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.2)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hipparchus-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Availability

    /// "No file chosen" is the normal state of a source in the sidebar, not an error.
    func testASourceWithNoFileSaysSoRatherThanFailing() {
        let provider = FileSourceProvider.naturalEarth()
        XCTAssertFalse(provider.availability.isAvailable)
        XCTAssertEqual(provider.availability.detail, "No file chosen")
    }

    func testAMissingFileIsReportedByName() {
        let provider = FileSourceProvider.naturalEarth(
            path: directory.appendingPathComponent("nowhere.shp")
        )
        XCTAssertFalse(provider.availability.isAvailable)
        XCTAssertTrue(provider.availability.detail.contains("nowhere.shp"))
    }

    /// An unread format must say what it is, not return an empty map.
    func testAnUnreadableFormatExplainsItself() throws {
        let path = try write("{}", to: "places.parquet")
        let provider = FileSourceProvider.overture(path: path)

        XCTAssertFalse(provider.availability.isAvailable)
        XCTAssertTrue(provider.availability.detail.contains("GeoParquet"))
        // And it says how to get past it, rather than only that it cannot.
        XCTAssertTrue(provider.availability.detail.contains("duckdb"))
        XCTAssertTrue(provider.availability.detail.contains("geojson"))
    }

    /// A converted Overture export goes straight through the GeoJSON path, which
    /// is what makes the refusal above a detour rather than a dead end.
    func testAConvertedOvertureExportIsRead() async throws {
        let path = try write("""
            {"type": "FeatureCollection", "features": [
              {"type": "Feature", "properties": {"theme": "buildings", "subtype": "residential"},
               "geometry": {"type": "Polygon", "coordinates": [[[23.70, 37.90], [23.71, 37.90], [23.71, 37.91], [23.70, 37.91], [23.70, 37.90]]]}},
              {"type": "Feature", "properties": {"theme": "places", "names": "Kafeneio"},
               "geometry": {"type": "Point", "coordinates": [23.72, 37.92]}}
            ]}
            """, to: "overture.geojson")

        let collection = try await FileSourceProvider.overture(path: path).fetch(athens)
        XCTAssertEqual(collection.features(in: "buildings").count, 1)
        XCTAssertEqual(collection.features(in: "places").count, 1)
    }

    func testFormatsAreRecognisedByName() throws {
        XCTAssertEqual(FileFormat.of(try write("{}", to: "a.geojson")), .geoJSON)
        XCTAssertEqual(FileFormat.of(try write("{}", to: "a.json")), .geoJSON)
        XCTAssertEqual(FileFormat.of(try write("x", to: "a.mbtiles")), .mbtiles)
        XCTAssertEqual(FileFormat.of(try write("x", to: "a.pmtiles")), .pmtiles)
        XCTAssertEqual(FileFormat.of(try write("x", to: "a.parquet")), .parquet)
        XCTAssertEqual(FileFormat.of(try write("x", to: "a.tar.gz")), .unknown)
        // `.osm.pbf` is two extensions and `pathExtension` only sees the last.
        XCTAssertEqual(FileFormat.of(try write("x", to: "greece.osm.pbf")), .osmPBF)
    }

    // MARK: - GeoJSON, the path every source accepts

    private let geoJSON = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "properties": {"highway": "primary", "name": "Leoforos"},
           "geometry": {"type": "LineString", "coordinates": [[23.7, 37.9], [23.75, 37.95]]}},
          {"type": "Feature", "properties": {"building": "yes"},
           "geometry": {"type": "Polygon", "coordinates": [
             [[23.70, 37.90], [23.71, 37.90], [23.71, 37.91], [23.70, 37.91], [23.70, 37.90]],
             [[23.703, 37.903], [23.707, 37.903], [23.707, 37.907], [23.703, 37.907], [23.703, 37.903]]
           ]}},
          {"type": "Feature", "properties": {"place": "city", "name": "Athina"},
           "geometry": {"type": "Point", "coordinates": [23.73, 37.98]}},
          {"type": "Feature", "properties": {"highway": "track"},
           "geometry": {"type": "LineString", "coordinates": [[100.0, 10.0], [100.1, 10.1]]}}
        ]}
        """

    func testGeoJSONIsReadAndClassified() async throws {
        let path = try write(geoJSON, to: "extract.geojson")
        let collection = try await FileSourceProvider.localOSMPBF(path: path).fetch(athens)

        XCTAssertEqual(collection.features(in: "roads").count, 1)
        XCTAssertEqual(collection.features(in: "buildings").count, 1)
        XCTAssertEqual(collection.features(in: "places").count, 1)
        XCTAssertEqual(collection.metadata["format"]?.stringValue, "geojson")
    }

    /// Anything outside the frame is not this map's business.
    func testFeaturesOutsideTheFrameAreDropped() async throws {
        let path = try write(geoJSON, to: "extract.geojson")
        let collection = try await FileSourceProvider.localOSMPBF(path: path).fetch(athens)
        // The track at longitude 100 is in Thailand.
        XCTAssertEqual(collection.featureCount, 3)
    }

    func testAPolygonKeepsItsHole() async throws {
        let path = try write(geoJSON, to: "extract.geojson")
        let collection = try await FileSourceProvider.localOSMPBF(path: path).fetch(athens)

        guard case .polygon(let polygon) = collection.features(in: "buildings").first?.geometry else {
            return XCTFail("not a polygon")
        }
        XCTAssertEqual(polygon.holes.count, 1, "the courtyard was filled in")
    }

    /// A hand-authored file can name its own layer, so it need not argue with a
    /// tag classifier.
    func testAFileMayNameItsOwnLayer() async throws {
        let path = try write("""
            {"type": "FeatureCollection", "features": [
              {"type": "Feature", "properties": {"hipparchus_layer": "admin_boundaries"},
               "geometry": {"type": "LineString", "coordinates": [[23.7, 37.9], [23.8, 38.0]]}}
            ]}
            """, to: "borders.geojson")
        let collection = try await FileSourceProvider.naturalEarth(path: path).fetch(athens)
        XCTAssertEqual(collection.features(in: FileLayer.adminBoundaries).count, 1)
    }

    /// Every layer the Python's optional providers accept by name is accepted
    /// here — the list is `EXTRA_LAYERS` from `optional_providers.py`, verbatim.
    /// This is what makes a converted hillshade, an earthquake catalogue or a
    /// saved ground track loadable from a file: the layer only has to say what
    /// it is. `terrain_hillshade` in particular is styled and ordered by the
    /// scene, and a file is the one way anything ever lands in it.
    func testEveryExtraLayerThePythonAcceptsIsAcceptedHere() {
        let extraLayers = [
            "admin_boundaries",
            "terrain_contours", "terrain_index_contours", "terrain_hillshade",
            "elevation_bands", "night_lights",
            "earthquakes_shallow", "earthquakes_intermediate", "earthquakes_deep",
            "satellite_tracks", "satellite_footprints",
            "bathymetry", "summits",
        ]
        let line = Geometry.lineString(
            LineString([Coordinate(lon: 23.7, lat: 37.9), Coordinate(lon: 23.8, lat: 38.0)])
        )
        for layer in extraLayers {
            XCTAssertEqual(
                FileLayer.forProperties(
                    ["hipparchus_layer": .string(layer)],
                    providerID: SourceID.naturalEarth,
                    geometry: line
                ),
                layer,
                "'\(layer)' is named after the Python's EXTRA_LAYERS and was rejected"
            )
        }
    }

    /// A converted extract usually arrives as one file per layer in a folder.
    func testADirectoryOfGeoJSONIsReadAsOneSource() async throws {
        let folder = directory.appendingPathComponent("layers")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, lon) in [("a.geojson", 23.70), ("b.geojson", 23.80)] {
            try """
                {"type": "Feature", "properties": {"building": "yes"},
                 "geometry": {"type": "Polygon", "coordinates": [[[\(lon), 37.9], [\(lon + 0.01), 37.9], [\(lon + 0.01), 37.91], [\(lon), 37.91], [\(lon), 37.9]]]}}
                """.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(FileFormat.of(folder), .geoJSON)
        let collection = try await FileSourceProvider.overture(path: folder).fetch(athens)
        XCTAssertEqual(collection.features(in: "buildings").count, 2)
    }

    /// Natural Earth and Overture each speak their own vocabulary.
    func testEachSourceReadsItsOwnVocabulary() throws {
        let point = Geometry.point(Coordinate(lon: 23.7, lat: 37.9))
        XCTAssertEqual(
            FileLayer.forProperties(
                ["featurecla": .string("Admin-0 country")],
                providerID: SourceID.naturalEarth,
                geometry: .lineString(LineString([Coordinate(lon: 0, lat: 0), Coordinate(lon: 1, lat: 1)]))
            ),
            FileLayer.adminBoundaries
        )
        XCTAssertEqual(
            FileLayer.forProperties(
                ["featurecla": .string("Populated place"), "name": .string("Athens")],
                providerID: SourceID.naturalEarth, geometry: point
            ),
            "places"
        )
        XCTAssertEqual(
            FileLayer.forProperties(
                ["theme": .string("buildings")], providerID: SourceID.overture, geometry: point
            ),
            "buildings"
        )
        // And anything else still falls back to reading OSM tags.
        XCTAssertEqual(
            FileLayer.forProperties(
                ["highway": .string("residential")], providerID: SourceID.overture, geometry: point
            ),
            "roads"
        )
    }

    // MARK: - Shapefile

    func testAShapefileIsReadWithItsAttributes() async throws {
        let path = try ShapefileWriter.write(
            to: directory.appendingPathComponent("ne_places.shp"),
            points: [
                (Coordinate(lon: 23.73, lat: 37.98), "Athina"),
                (Coordinate(lon: 25.14, lat: 35.34), "Iraklio"),
            ]
        )
        let collection = try await FileSourceProvider.naturalEarth(path: path).fetch(athens)

        let places = collection.features(in: "places")
        XCTAssertEqual(places.count, 1, "Iraklio is outside the frame")
        XCTAssertEqual(places.first?.property("NAME")?.stringValue, "Athina")
        XCTAssertEqual(collection.metadata["format"]?.stringValue, "shapefile")
    }

    /// Natural Earth unzips one folder per dataset, so the folder a reader
    /// actually points at holds no `.shp` of its own — only `ne_10m_coastline/`
    /// and its siblings. That folder used to report "Unrecognised format",
    /// which made the size refusal's advice to use Natural Earth impossible to
    /// follow with the files as the site ships them.
    func testAFolderOfDatasetFoldersIsReadAsNaturalEarthDoesShipIt() async throws {
        let download = directory.appendingPathComponent("natural_earth_10m")
        for dataset in ["ne_10m_populated_places", "ne_10m_admin_0_countries"] {
            let folder = download.appendingPathComponent(dataset)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try ShapefileWriter.write(
                to: folder.appendingPathComponent("\(dataset).shp"),
                points: [(Coordinate(lon: 23.73, lat: 37.98), dataset)]
            )
        }

        XCTAssertEqual(
            FileFormat.of(download), .shapefile,
            "a folder of dataset folders is still Natural Earth"
        )

        let collection = try await FileSourceProvider.naturalEarth(path: download).fetch(athens)
        XCTAssertEqual(
            collection.features(in: "places").count, 2,
            "both dataset folders should have been read, not just the first"
        )
    }

    func testANonShapefileIsRejectedRatherThanMisread() throws {
        let path = try write("not a shapefile at all", to: "fake.shp")
        XCTAssertThrowsError(
            try ShapefileReader.features(at: path, bbox: athens.bbox, providerID: SourceID.naturalEarth)
        )
    }

    /// Shapefile polygons carry no nesting: winding decides, and a hole goes to
    /// the smallest outer ring containing it.
    func testShapefileRingWindingDecidesHoles() {
        // Clockwise in a y-up frame is an outline; anti-clockwise is a hole.
        let outer = [
            Coordinate(x: 0, y: 0), Coordinate(x: 0, y: 10),
            Coordinate(x: 10, y: 10), Coordinate(x: 10, y: 0),
        ]
        let hole = [
            Coordinate(x: 2, y: 2), Coordinate(x: 4, y: 2),
            Coordinate(x: 4, y: 4), Coordinate(x: 2, y: 4),
        ]
        guard case .polygon(let polygon)? = ShapefileReader.assemble(rings: [outer, hole]) else {
            return XCTFail("not a polygon")
        }
        XCTAssertEqual(polygon.holes.count, 1)
    }

    /// A file whose winding is wrong throughout would otherwise vanish entirely.
    func testEveryRingBecomesAnOutlineWhenNoneWindsAsOne() {
        let anticlockwise = [
            Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0),
            Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10),
        ]
        XCTAssertNotNil(ShapefileReader.assemble(rings: [anticlockwise]))
    }

    // MARK: - Vector tiles

    /// The command stream is the only part of a tile that is not bookkeeping.
    func testTheTileCommandStreamDecodesToRings() {
        // MoveTo(1) x1 -> (25, 17); LineTo(2) x2; ClosePath(7).
        let commands: [UInt64] = [
            9, MVT.zigZagEncode(25), MVT.zigZagEncode(17),
            18, MVT.zigZagEncode(10), MVT.zigZagEncode(0),
            MVT.zigZagEncode(0), MVT.zigZagEncode(10),
            15,
        ]
        let rings = MVT.rings(from: commands)

        XCTAssertEqual(rings.count, 1)
        // Three corners plus the repeated first point that closes it.
        XCTAssertEqual(rings[0].count, 4)
        XCTAssertEqual(rings[0][0], Coordinate(x: 25, y: 17))
        // Deltas accumulate across commands, not per command.
        XCTAssertEqual(rings[0][1], Coordinate(x: 35, y: 17))
        XCTAssertEqual(rings[0][2], Coordinate(x: 35, y: 27))
        XCTAssertEqual(rings[0][3], rings[0][0], "ClosePath must close it")
    }

    /// A second MoveTo starts the next part of a multipart feature.
    func testASecondMoveToStartsANewRing() {
        let commands: [UInt64] = [
            9, MVT.zigZagEncode(0), MVT.zigZagEncode(0),
            10, MVT.zigZagEncode(5), MVT.zigZagEncode(0),
            9, MVT.zigZagEncode(100), MVT.zigZagEncode(100),
            10, MVT.zigZagEncode(5), MVT.zigZagEncode(0),
        ]
        XCTAssertEqual(MVT.rings(from: commands).count, 2)
    }

    func testAMalformedCommandStopsTheStreamRatherThanLooping() {
        // Command id 4 is not a command.
        XCTAssertTrue(MVT.rings(from: [0b100]).isEmpty)
    }

    func testATileIsPlacedBackOnTheEarth() throws {
        // The tile holding Athens, derived rather than written down — a hardcoded
        // index that is one column out still looks like a plausible number, and
        // puts the map two degrees east.
        let athina = Coordinate(lon: 23.73, lat: 37.98)
        let tile = WebMercator.tile(lon: athina.lon, lat: athina.lat, zoom: 14)

        let feature = MVT.TileFeature(
            properties: [:], kind: .point,
            rings: [[Coordinate(x: 2048, y: 2048)]]  // the middle of a 4096 grid
        )
        guard case .point(let placed)? = feature.geometry(
            z: 14, x: tile.x, y: tile.y, extent: 4096
        ) else {
            return XCTFail("not a point")
        }

        // A tile at zoom 14 is about 0.022° wide, so the centre of the tile
        // holding Athens has to be within one tile of it.
        XCTAssertEqual(placed.lon, athina.lon, accuracy: 0.03)
        XCTAssertEqual(placed.lat, athina.lat, accuracy: 0.03)
    }

    func testAnMBTilesArchiveIsReadThroughSQLite() async throws {
        let tile = WebMercator.tile(lon: 23.73, lat: 37.98, zoom: 14)
        let path = directory.appendingPathComponent("greece.mbtiles")
        try MBTilesWriter.write(to: path, zoom: 14, x: tile.x, y: tile.y, tile: MVTWriter.oneBuilding())

        let collection = try await FileSourceProvider.vectorTiles(path: path).fetch(
            BBoxQuery(minLon: 23.70, minLat: 37.96, maxLon: 23.76, maxLat: 38.02)
        )
        XCTAssertEqual(collection.metadata["format"]?.stringValue, "mbtiles")
        XCTAssertEqual(collection.features(in: "buildings").count, 1)
    }

    /// MBTiles rows are TMS: row 0 is the *south* edge, and every other tile
    /// scheme here counts from the north. Reading it unflipped fetches a tile
    /// from the wrong hemisphere.
    func testMBTilesRowsAreFlipped() async throws {
        let path = directory.appendingPathComponent("flipped.mbtiles")
        let tile = WebMercator.tile(lon: 23.73, lat: 37.98, zoom: 14)
        try MBTilesWriter.write(to: path, zoom: 14, x: tile.x, y: tile.y, tile: MVTWriter.oneBuilding())

        let archive = try MBTilesArchive(path: path)
        defer { archive.close() }
        XCTAssertNotNil(try archive.tile(z: 14, x: tile.x, y: tile.y))
        XCTAssertNil(
            try archive.tile(z: 14, x: tile.x, y: (1 << 14) - 1 - tile.y),
            "reading the row unflipped found a tile, so the flip is not happening"
        )
    }

    func testTheArchiveFallsBackToTheZoomItActuallyHolds() throws {
        let path = directory.appendingPathComponent("coarse.mbtiles")
        try MBTilesWriter.write(to: path, zoom: 8, x: 146, y: 98, tile: MVTWriter.oneBuilding())

        let archive = try MBTilesArchive(path: path)
        defer { archive.close() }
        XCTAssertEqual(archive.zoom(preferring: 14), 8, "asking for 14 in an 8-only archive found nothing")
    }

    /// The Hilbert index is what makes PMTiles compact, and the one fiddly part.
    func testTheHilbertIndexMatchesTheSpecification() {
        // Published values: zoom 0 is id 0, and zoom 1 runs 1...4.
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 0, x: 0, y: 0), 0)
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 1, x: 1, y: 0), 4)
        XCTAssertEqual(PMTilesArchive.hilbertIndex(z: 2, x: 0, y: 0), 5)
    }

    /// Every tile at a zoom must get its own id, or one would shadow another.
    func testEveryTileAtAZoomHasADistinctIndex() {
        var seen = Set<UInt64>()
        for x in 0..<8 {
            for y in 0..<8 {
                XCTAssertTrue(seen.insert(PMTilesArchive.hilbertIndex(z: 3, x: x, y: y)).inserted)
            }
        }
        XCTAssertEqual(seen.count, 64)
    }

    // MARK: - OSM PBF

    func testAnOSMExtractIsReadThroughItsBlobs() async throws {
        let path = directory.appendingPathComponent("attica.osm.pbf")
        try OSMPBFWriter.write(to: path)

        let collection = try await FileSourceProvider.localOSMPBF(path: path).fetch(athens)
        XCTAssertEqual(collection.metadata["format"]?.stringValue, "osm_pbf")

        // One tagged node in range, and one way built from untagged nodes.
        XCTAssertEqual(collection.features(in: "places").count, 1)
        XCTAssertEqual(collection.features(in: "roads").count, 1)

        guard case .lineString(let road) = collection.features(in: "roads").first?.geometry else {
            return XCTFail("a highway way is a line")
        }
        XCTAssertEqual(road.coordinates.count, 3, "the way lost a node between the two passes")
    }

    func testAClosedTaggedWayBecomesAnArea() async throws {
        let path = directory.appendingPathComponent("building.osm.pbf")
        try OSMPBFWriter.write(to: path, closedBuilding: true)

        let collection = try await FileSourceProvider.localOSMPBF(path: path).fetch(athens)
        guard case .polygon = collection.features(in: "buildings").first?.geometry else {
            return XCTFail("a closed building way is an area")
        }
    }

    /// Dense nodes are four parallel delta arrays with a run-together tag list.
    func testDenseNodesDecodeTheirDeltasAndTags() throws {
        let block = try OSMPBFReader.primitiveBlock(OSMPBFWriter.primitiveBlock())
        let nodes = block.groups.flatMap(\.nodes)

        XCTAssertEqual(nodes.count, 4)
        // Ids are cumulative, not absolute.
        XCTAssertEqual(nodes.map(\.id), [1, 2, 3, 4])
        // Only the first carries tags; the rest end at their zero terminator.
        XCTAssertEqual(nodes[0].tags["place"], "city")
        XCTAssertTrue(nodes[1].tags.isEmpty)
        XCTAssertEqual(nodes[0].coordinate.lat, 37.98, accuracy: 1e-6)
        XCTAssertEqual(nodes[0].coordinate.lon, 23.73, accuracy: 1e-6)
    }

    func testATruncatedFileIsAnErrorRatherThanACrash() throws {
        let path = directory.appendingPathComponent("cut.osm.pbf")
        var data = try Data(contentsOf: try {
            let full = directory.appendingPathComponent("full.osm.pbf")
            try OSMPBFWriter.write(to: full)
            return full
        }())
        data = data.prefix(data.count / 2)
        try data.write(to: path)

        // Truncated blobs are skipped, so this reads what survived rather than
        // throwing the file away — and above all does not crash.
        XCTAssertNoThrow(
            try OSMPBFReader.features(at: path, bbox: athens.bbox, providerID: SourceID.localOSMPBF)
        )
    }

    // MARK: - The stack

    /// A file source stays listed but cannot be ticked until a file is chosen.
    func testTheStackOnlyEnablesAFileSourceOnceItHasAFile() throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.naturalEarth, true)
        XCTAssertFalse(stack.isEnabled(SourceID.naturalEarth))

        let path = try write(geoJSON, to: "ne.geojson")
        stack.setPath(SourceID.naturalEarth, path.path)
        stack.setEnabled(SourceID.naturalEarth, true)
        XCTAssertTrue(stack.isEnabled(SourceID.naturalEarth))
    }

    /// Stacking a file source onto the online ones is the whole point.
    func testAFileSourceStacksWithTheRest() async throws {
        let path = try write(geoJSON, to: "extra.geojson")
        var stack = SourceStack()
        stack.setPath(SourceID.naturalEarth, path.path)
        stack.setEnabled(SourceID.naturalEarth, true)

        let plan = try XCTUnwrap(stack.plan)
        XCTAssertEqual(plan.base, SourceID.overpass)
        XCTAssertTrue(plan.extras.contains(SourceID.naturalEarth))
    }
}

/// What a name is called, and who has to know.
///
/// The renderer speaks OpenStreetMap's vocabulary — a label comes from a
/// feature's `name`, spelled exactly that way — and every source is translated
/// into that vocabulary on the way in. Natural Earth writes `NAME`, and the
/// layer classifier was already reading it case-insensitively, so its cities
/// arrived, landed in the `places` layer, and were then dropped one step later
/// by a renderer that found no `name` on them. Two hundred and forty-three
/// populated places reached the world sheet and none of them was drawn.
final class FilePropertyNameTests: XCTestCase {

    private var directory = FileManager.default.temporaryDirectory
    private let athens = BBoxQuery(
        bbox: BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.2)
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAShapefileNameReachesTheRenderersVocabulary() async throws {
        let path = try ShapefileWriter.write(
            to: directory.appendingPathComponent("ne_places.shp"),
            points: [(Coordinate(lon: 23.73, lat: 37.98), "Athina")]
        )
        let collection = try await FileSourceProvider.naturalEarth(path: path).fetch(athens)
        let place = try XCTUnwrap(collection.features(in: "places").first)
        XCTAssertEqual(place.property("name")?.stringValue, "Athina")
        XCTAssertEqual(place.property("NAME")?.stringValue, "Athina", "the source's own spelling stays")
    }

    func testTheSourcesOwnNameIsNeverOverwritten() {
        let properties: [String: PropertyValue] = [
            "name": .string("Athina"), "NAME": .string("ATHENS"),
        ]
        XCTAssertEqual(
            FileProperties.named(properties)["name"]?.stringValue, "Athina",
            "a file that already speaks the right vocabulary is left alone"
        )
    }

    func testAFileWithNoNameAtAllGainsNothing() {
        let properties: [String: PropertyValue] = ["featurecla": .string("Admin-0 country")]
        XCTAssertNil(FileProperties.named(properties)["name"])
    }

    /// In alias order, so a country carries its common name rather than its
    /// long form.
    func testTheAliasesAreTriedInOrder() {
        XCTAssertEqual(
            FileProperties.named(["NAME_LONG": .string("French Republic"),
                                  "NAME": .string("France")])["name"]?.stringValue,
            "France"
        )
        XCTAssertEqual(
            FileProperties.named(["NAMEASCII": .string("Sao Paulo")])["name"]?.stringValue,
            "Sao Paulo"
        )
    }

    func testAnEmptyNameIsNotAName() {
        XCTAssertNil(FileProperties.named(["NAME": .string("  ")])["name"])
    }
}

/// A shapefile's attributes are matched to its geometry **by position**, and a
/// bbox query skips most of the positions.
///
/// The reader was indexing the `.dbf` by how many features it had *kept*, so the
/// first record inside the frame took the first record's attributes in the file
/// rather than its own. A whole-world Natural Earth file queried for one
/// continent skips almost everything, which put the wrong name on every city on
/// the sheet: a European frame came back labelled Agra, Albuquerque and the
/// Amundsen–Scott South Pole Station, all of them drawn in Europe. Nothing
/// failed, and nothing looked broken unless you knew where those places are.
final class ShapefileAttributePairingTests: XCTestCase {

    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testASkippedRecordDoesNotShiftEveryNameAfterIt() throws {
        // Three cities, in file order. Only the last two are in the frame.
        let path = try ShapefileWriter.write(
            to: directory.appendingPathComponent("ne_places.shp"),
            points: [
                (Coordinate(lon: -99.13, lat: 19.43), "Ciudad de Mexico"),
                (Coordinate(lon: 23.73, lat: 37.98), "Athina"),
                (Coordinate(lon: 23.80, lat: 38.05), "Acharnes"),
            ]
        )
        let features = try ShapefileReader.features(
            at: path,
            bbox: BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.2),
            providerID: SourceID.naturalEarth
        )
        XCTAssertEqual(features.count, 2)
        XCTAssertEqual(features.map { $0.property("NAME")?.stringValue }, ["Athina", "Acharnes"])
    }

    /// Ids stay unique across the run even though the attribute index no longer
    /// counts features — the two were the same number before, and are not now.
    func testIdsStayDistinct() throws {
        let path = try ShapefileWriter.write(
            to: directory.appendingPathComponent("ne_places.shp"),
            points: [
                (Coordinate(lon: -99.13, lat: 19.43), "Ciudad de Mexico"),
                (Coordinate(lon: 23.73, lat: 37.98), "Athina"),
                (Coordinate(lon: 23.80, lat: 38.05), "Acharnes"),
            ]
        )
        let features = try ShapefileReader.features(
            at: path,
            bbox: BoundingBox(minLon: 23.5, minLat: 37.8, maxLon: 24.0, maxLat: 38.2),
            providerID: SourceID.naturalEarth
        )
        XCTAssertEqual(Set(features.map(\.id)).count, features.count)
    }
}
