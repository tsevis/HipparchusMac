import Foundation
import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// The GeoJSON export is the way out of this application and into every other one,
/// so these check the file a GIS will actually open — not the intent behind it.
final class GeoJSONExportTests: XCTestCase {

    private func text() throws -> String {
        GeoJSONExporter().featureCollection(for: try Sample.scene())
    }

    private func parsed() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(try text().utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func features(in payload: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(payload["features"] as? [[String: Any]])
    }

    private func properties(of feature: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(feature["properties"] as? [String: Any])
    }

    private func layerName(of feature: [String: Any]) throws -> String {
        try XCTUnwrap(properties(of: feature)["hipparchus_layer"] as? String)
    }

    /// Every coordinate in the document, however deeply nested.
    private func coordinates(in payload: [String: Any]) throws -> [Coordinate] {
        var found: [Coordinate] = []
        func walk(_ value: Any) {
            if let pair = value as? [Any], pair.count == 2,
               let lon = (pair[0] as? NSNumber)?.doubleValue,
               let lat = (pair[1] as? NSNumber)?.doubleValue {
                found.append(Coordinate(lon: lon, lat: lat))
                return
            }
            if let list = value as? [Any] { list.forEach(walk) }
        }
        for feature in try features(in: payload) {
            guard let geometry = feature["geometry"] as? [String: Any] else { continue }
            walk(geometry["coordinates"] ?? [])
        }
        return found
    }

    // MARK: - The document

    func testTheDocumentIsAWellFormedFeatureCollection() throws {
        let payload = try parsed()
        XCTAssertEqual(payload["type"] as? String, "FeatureCollection")
        XCTAssertFalse(try features(in: payload).isEmpty, "the sample scene has geometry to export")
        for feature in try features(in: payload) {
            XCTAssertEqual(feature["type"] as? String, "Feature")
            XCTAssertNotNil(feature["geometry"], "a feature with no geometry is not worth writing")
            XCTAssertNotNil(feature["properties"])
        }
    }

    /// RFC 7946 has one coordinate reference system and it is not the one the map
    /// was drawn in. The scene holds Web Mercator metres — six-figure numbers — and
    /// writing those as if they were degrees puts Cyprus somewhere past Neptune.
    func testGeometryIsUnprojectedBackIntoLongitudeAndLatitude() throws {
        let payload = try parsed()
        let coordinates = try self.coordinates(in: payload)
        XCTAssertFalse(coordinates.isEmpty)
        for coordinate in coordinates {
            XCTAssertTrue(coordinate.isFinite, "a non-finite vertex is not a position")
            XCTAssertTrue((-180.0...180.0).contains(coordinate.lon), "lon \(coordinate.lon) is not a longitude")
            XCTAssertTrue((-90.0...90.0).contains(coordinate.lat), "lat \(coordinate.lat) is not a latitude")
        }

        // And it is the *right* ground, not merely plausible ground: the sample
        // scene's own bbox should contain what came out of it.
        let bbox = try XCTUnwrap(Sample.scene().bbox)
        let inside = coordinates.filter {
            $0.lon >= bbox.minLon - 0.5 && $0.lon <= bbox.maxLon + 0.5
                && $0.lat >= bbox.minLat - 0.5 && $0.lat <= bbox.maxLat + 0.5
        }
        XCTAssertEqual(inside.count, coordinates.count, "the export landed off the requested area")
    }

    func testTheCollectionCarriesTheRequestedAreaAsABoundingBox() throws {
        let payload = try parsed()
        let bbox = try XCTUnwrap(payload["bbox"] as? [Double])
        XCTAssertEqual(bbox.count, 4)
        let requested = try XCTUnwrap(Sample.scene().bbox)
        XCTAssertEqual(bbox[0], requested.minLon, accuracy: 1e-6)
        XCTAssertEqual(bbox[1], requested.minLat, accuracy: 1e-6)
        XCTAssertEqual(bbox[2], requested.maxLon, accuracy: 1e-6)
        XCTAssertEqual(bbox[3], requested.maxLat, accuracy: 1e-6)
    }

    // MARK: - Layers

    /// The reason this exporter exists: a scene is a stack of named layers, and a
    /// file that forgets which layer a line came from is a heap of lines.
    func testEveryFeatureNamesTheLayerItCameFrom() throws {
        let payload = try parsed()
        var seen: Set<String> = []
        for feature in try features(in: payload) {
            seen.insert(try layerName(of: feature))
        }
        for name in Sample.layerOrder where !name.isEmpty {
            XCTAssertTrue(seen.contains(name), "\(name) is not named on any feature")
        }
    }

    func testFeaturesComeOutInDrawOrder() throws {
        let payload = try parsed()
        let names = try features(in: payload).map { try layerName(of: $0) }
        // The first appearance of each layer must follow the scene's own order.
        var firstAppearance: [String: Int] = [:]
        for (index, name) in names.enumerated() where firstAppearance[name] == nil {
            firstAppearance[name] = index
        }
        let ordered = try Sample.scene().layers.map(\.name).compactMap { firstAppearance[$0] }
        XCTAssertEqual(ordered, ordered.sorted(), "the layer stack lost its order on the way out")
    }

    /// Mirrors the SVG, which keeps an unticked layer rather than dropping it: the
    /// layer is still part of the map, and something downstream may want it back.
    func testAHiddenLayerIsKeptButMarked() throws {
        var scene = try Sample.scene()
        let hidden = scene.layers[0].name
        scene.layers[0].style.visible = false
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(GeoJSONExporter().featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        var found = false
        for feature in try features(in: payload) where try layerName(of: feature) == hidden {
            XCTAssertEqual(try properties(of: feature)["visible"] as? Bool, false)
            found = true
        }
        XCTAssertTrue(found, "the hidden layer was dropped instead of marked")
    }

    // MARK: - Style

    /// Elevation bands are the test case that matters. Their colours come from a
    /// ramp, feature by feature, not from the layer style — an export that reads
    /// the style instead flattens a hypsometric map to one colour.
    func testEachFeatureCarriesItsOwnFillSoTheRampSurvives() throws {
        let payload = try parsed()
        var fills: Set<String> = []
        for feature in try features(in: payload)
        where try layerName(of: feature) == TerrainLayer.elevationBands {
            fills.insert(try XCTUnwrap(properties(of: feature)["fill"] as? String))
        }
        XCTAssertGreaterThan(fills.count, 1, "every band exported the same colour; the ramp was lost")
        for fill in fills {
            XCTAssertTrue(fill.hasPrefix("#") && fill.count == 7, "\(fill) is not a hex colour")
        }
    }

    /// simplestyle-spec, because it is the one styling convention a GeoJSON file
    /// can carry that other tools already read.
    func testStrokesAreWrittenInTheConventionOtherToolsRead() throws {
        let payload = try parsed()
        let contours = try features(in: payload)
            .filter { try layerName(of: $0) == TerrainLayer.minorContours }
        XCTAssertFalse(contours.isEmpty)
        let style = Sample.style(TerrainLayer.minorContours)
        let properties = try self.properties(of: try XCTUnwrap(contours.first))
        XCTAssertEqual(properties["stroke"] as? String, style.strokeColor.hex)
        let width = try XCTUnwrap((properties["stroke-width"] as? NSNumber)?.doubleValue)
        XCTAssertGreaterThan(width, 0)
    }

    /// A line layer that says `fill` invites every viewer to close the line with an
    /// invisible chord and paint the wedge behind it — the pale triangle across the
    /// sea the SVG exporter already learned about.
    func testOpenLinesAreNotGivenAFill() throws {
        let payload = try parsed()
        for feature in try features(in: payload) {
            let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
            let type = try XCTUnwrap(geometry["type"] as? String)
            guard type == "LineString" || type == "MultiLineString" else { continue }
            XCTAssertNil(try properties(of: feature)["fill"], "an open line was given a fill")
        }
    }

    // MARK: - Geometry

    func testAHoleInABandStaysAHole() throws {
        let payload = try parsed()
        let polygons = try features(in: payload)
            .filter { try layerName(of: $0) == TerrainLayer.elevationBands }
            .compactMap { $0["geometry"] as? [String: Any] }
            .filter { ($0["type"] as? String) == "Polygon" }
        let withHoles = polygons.filter { (($0["coordinates"] as? [Any])?.count ?? 0) > 1 }
        XCTAssertFalse(withHoles.isEmpty, "the sample band has a hole and the export filled it in")
    }

    /// RFC 7946 §3.1.6: exterior rings counter-clockwise, holes clockwise. Ignored
    /// by plenty of readers and not by MapLibre, which is what GeoLibre draws with —
    /// a wrongly wound ring there fills the whole world and knocks a hole in the map.
    func testRingsFollowTheRightHandRule() throws {
        let payload = try parsed()
        var checked = 0
        for feature in try features(in: payload) {
            let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
            let type = try XCTUnwrap(geometry["type"] as? String)
            let polygons: [[Any]]
            switch type {
            case "Polygon":
                polygons = [try XCTUnwrap(geometry["coordinates"] as? [Any])]
            case "MultiPolygon":
                polygons = try XCTUnwrap(geometry["coordinates"] as? [[Any]])
            default:
                continue
            }
            for polygon in polygons {
                for (index, ring) in polygon.enumerated() {
                    let coordinates = (ring as? [[Double]] ?? []).map { Coordinate(lon: $0[0], lat: $0[1]) }
                    guard coordinates.count >= 4 else { continue }
                    let area = Ring(coordinates).signedDoubleArea
                    guard area != 0 else { continue }
                    checked += 1
                    if index == 0 {
                        XCTAssertGreaterThan(area, 0, "an exterior ring is wound clockwise")
                    } else {
                        XCTAssertLessThan(area, 0, "a hole is wound counter-clockwise")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "no rings were checked, so this proved nothing")
    }

    func testRingsAreClosed() throws {
        let payload = try parsed()
        for feature in try features(in: payload) {
            let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
            guard (geometry["type"] as? String) == "Polygon" else { continue }
            for ring in try XCTUnwrap(geometry["coordinates"] as? [[[Double]]]) {
                XCTAssertGreaterThanOrEqual(ring.count, 4, "a ring needs four positions")
                XCTAssertEqual(ring.first ?? [], ring.last ?? [], "an unclosed ring is not a ring")
            }
        }
    }

    func testEmptyGeometryIsSkippedRatherThanWrittenAsNull() throws {
        var scene = try Sample.scene()
        var layer = RenderLayer(name: TerrainLayer.summits)
        layer.append(.empty)
        layer.append(.point(Coordinate(lon: .nan, lat: .nan)))
        layer.append(.lineString(LineString([])))
        scene.layers = [layer]
        let exporter = GeoJSONExporter()
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(exporter.featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(try features(in: payload).count, 0)
        XCTAssertFalse(exporter.featureCollection(for: scene).contains("null"))
    }

    func testCoordinatesAreRoundedSoTheFileDoesNotBloat() throws {
        var options = GeoJSONExporter.Options()
        options.precision = 5
        let text = GeoJSONExporter(options: options).featureCollection(for: try Sample.scene())
        // Every number in a coordinate array, as written.
        let numbers = text.split(whereSeparator: { "[], ".contains($0) })
            .filter { Double($0) != nil }
        XCTAssertFalse(numbers.isEmpty)
        for number in numbers {
            guard let dot = number.firstIndex(of: ".") else { continue }
            let decimals = number.distance(from: number.index(after: dot), to: number.endIndex)
            XCTAssertLessThanOrEqual(decimals, 5, "\(number) is written past the requested precision")
        }
    }

    // MARK: - Labels

    func testLabelsBecomePointFeaturesThatKeepTheirName() throws {
        var scene = try Sample.scene()
        var layer = RenderLayer(name: "places")
        layer.labels = [
            PlaceLabel(
                name: "Lemesós",
                position: scene.projection.project(Coordinate(lon: 33.04, lat: 34.68)),
                placeType: "city",
                rotation: 12
            )
        ]
        scene.layers = [layer]
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(GeoJSONExporter().featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        let feature = try XCTUnwrap(try features(in: payload).first)
        let geometry = try XCTUnwrap(feature["geometry"] as? [String: Any])
        XCTAssertEqual(geometry["type"] as? String, "Point")
        let position = try XCTUnwrap(geometry["coordinates"] as? [Double])
        XCTAssertEqual(position[0], 33.04, accuracy: 1e-4)
        XCTAssertEqual(position[1], 34.68, accuracy: 1e-4)
        let properties = try self.properties(of: feature)
        XCTAssertEqual(properties["name"] as? String, "Lemesós")
        XCTAssertEqual(properties["place_type"] as? String, "city")
        XCTAssertEqual((properties["rotation"] as? NSNumber)?.doubleValue, 12)
    }

    /// A name with a quote in it must not end the string it is written into.
    func testANameIsEscapedRatherThanTrusted() throws {
        var scene = try Sample.scene()
        var layer = RenderLayer(name: "places")
        layer.labels = [
            PlaceLabel(name: "The \"Old\" Harbour\\Port\u{0007}", position: Coordinate(x: 0, y: 0))
        ]
        scene.layers = [layer]
        let text = GeoJSONExporter().featureCollection(for: scene)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let properties = try self.properties(of: try XCTUnwrap(try features(in: payload).first))
        XCTAssertEqual(properties["name"] as? String, "The \"Old\" Harbour\\Port\u{0007}")
    }


    /// Natural Earth's places arrive as a point *and* a label at the same spot:
    /// the renderer draws a dot and then the name beside it, which is two marks
    /// on paper and one place on the ground. Written naively that is six cities
    /// exported as twelve points, half of them anonymous — as a real Cyprus
    /// export was, until this.
    func testANameLandsOnTheMarkItBelongsToRatherThanBesideItAsASecondPoint() throws {
        var scene = try Sample.scene()
        let position = scene.projection.project(Coordinate(lon: 33.36, lat: 35.17))
        var layer = RenderLayer(name: "places")
        layer.append(.point(position))
        layer.labels = [PlaceLabel(name: "Nicosia", position: position, placeType: "city")]
        scene.layers = [layer]

        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(GeoJSONExporter().featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        let written = try features(in: payload)
        XCTAssertEqual(written.count, 1, "the place was written twice, once anonymously")
        XCTAssertEqual(try properties(of: written[0])["name"] as? String, "Nicosia")
        XCTAssertEqual(try properties(of: written[0])["place_type"] as? String, "city")
    }

    /// A label that does not sit on a mark — set along a line, or nudged clear of
    /// the dot it names — is still its own feature. Merging is for the case where
    /// the two are the same place, not for every name in the layer.
    func testALabelAwayFromAnyMarkIsStillItsOwnFeature() throws {
        var scene = try Sample.scene()
        var layer = RenderLayer(name: "places")
        layer.append(.point(scene.projection.project(Coordinate(lon: 33.36, lat: 35.17))))
        layer.labels = [
            PlaceLabel(
                name: "Nicosia",
                position: scene.projection.project(Coordinate(lon: 33.40, lat: 35.20))
            )
        ]
        scene.layers = [layer]

        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(GeoJSONExporter().featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(try features(in: payload).count, 2)
    }
    // MARK: - What the sheet owes

    /// The About panel says attributions travel with anything published from here.
    /// A new export format is a new way for that sentence to stop being true.
    func testAttributionTravelsWithTheFile() throws {
        let scene = try Sample.scene()
        let credit = SheetAttribution.statement(for: scene)
        try XCTSkipIf(credit.isEmpty, "the sample scene credits nobody, so there is nothing to carry")
        let payload = try parsed()
        let hipparchus = try XCTUnwrap(payload["hipparchus"] as? [String: Any])
        XCTAssertEqual(hipparchus["attribution"] as? String, credit)
    }

    func testTheNavigationWarningTravelsWithTheFile() throws {
        var scene = try Sample.scene()
        scene.layers.append(RenderLayer(name: TerrainLayer.bathymetry))
        try XCTSkipUnless(NotForNavigation.applies(to: scene), "no sea on this sheet")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(GeoJSONExporter().featureCollection(for: scene).utf8)
            ) as? [String: Any]
        )
        let hipparchus = try XCTUnwrap(payload["hipparchus"] as? [String: Any])
        XCTAssertEqual(hipparchus["not_for_navigation"] as? Bool, true)
    }

    func testTheFileRecordsWhatItWasDrawnFromAndWhatItWasDrawnIn() throws {
        let payload = try parsed()
        let hipparchus = try XCTUnwrap(payload["hipparchus"] as? [String: Any])
        XCTAssertEqual(hipparchus["crs"] as? String, "EPSG:4326")
        XCTAssertEqual(hipparchus["render_crs"] as? String, try Sample.scene().projection.renderCRS)
        let layers = try XCTUnwrap(hipparchus["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, try Sample.scene().layers.count)
        let counted = layers.compactMap { ($0["features"] as? NSNumber)?.intValue }.reduce(0, +)
        XCTAssertEqual(counted, try features(in: payload).count)
    }

    // MARK: - Files

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hipparchus-geojson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWritingOneFileReportsWhatWentIntoIt() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("cyprus.geojson")
        let summary = try GeoJSONExporter().write(try Sample.scene(), to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(summary.features, 0)
        XCTAssertEqual(summary.layers, try Sample.scene().layers.filter { !$0.isEmpty }.count)
        XCTAssertEqual(summary.files, [url.lastPathComponent])
    }

    func testWritingPerLayerGivesOneFilePerPopulatedLayer() throws {
        let directory = try temporaryDirectory().appendingPathComponent("cyprus.geojson")
        let scene = try Sample.scene()
        let summary = try GeoJSONExporter().writeLayers(of: scene, into: directory)

        let written = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "geojson" }
        let populated = scene.layers.filter { !$0.isEmpty }
        XCTAssertEqual(written.count, populated.count)
        XCTAssertEqual(summary.files.count, populated.count)
        for layer in populated {
            XCTAssertTrue(
                written.contains { $0.lastPathComponent.contains(layer.name) },
                "\(layer.name) has no file of its own"
            )
        }
        // A drawing is read in draw order, so the files must sort that way too:
        // the reader sorts a directory by name and would otherwise stack the
        // contours under the ground they describe.
        XCTAssertEqual(summary.files, summary.files.sorted())
    }

    /// The strongest claim this exporter can make: what leaves comes back. It is
    /// also the round trip through another GIS in miniature — the reader here is
    /// the same one that accepts a file converted by anything else.
    func testAnExportedSceneCanBeReadBackIntoTheApplication() throws {
        let directory = try temporaryDirectory().appendingPathComponent("cyprus.geojson")
        let scene = try Sample.scene()
        try GeoJSONExporter().writeLayers(of: scene, into: directory)

        let bbox = try XCTUnwrap(scene.bbox)
        let features = try GeoJSONReader.features(
            at: directory, bbox: bbox, providerID: SourceID.naturalEarth
        )
        XCTAssertFalse(features.isEmpty, "nothing survived the round trip")

        // Every layer that went out with geometry comes back under its own name.
        let returned = Set(features.map(\.layer))
        for layer in scene.layers where !layer.geometries.isEmpty {
            XCTAssertTrue(
                returned.contains(layer.name),
                "\(layer.name) went out and came back as something else"
            )
        }
    }
}
