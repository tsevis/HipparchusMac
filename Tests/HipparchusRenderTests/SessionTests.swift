import XCTest
import HipparchusData
import HipparchusGeometry
@testable import HipparchusRender

/// Ported from `tests/test_project_state.py` and `tests/test_config.py`.
final class SessionTests: XCTestCase {

    private func temporaryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hipparchus-session-\(UUID().uuidString)")
            .appendingPathComponent("session.json")
    }

    func testASessionSurvivesARoundTripThroughDisk() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)
        stack.setSetting(SourceID.terrainTiles, "interval", .number(50))
        stack.setSetting(SourceID.terrainTiles, "bands", .integer(6))

        let session = Session(
            stack: stack,
            area: Session.Area(west: 23.2, south: 36.3, east: 24.2, north: 37.1),
            placeName: "Myrtoan Sea",
            preset: "Contour Study",
            quality: "export_print",
            hiddenLayers: ["buildings"],
        )
        try session.write(to: url)

        let restored = Session.read(from: url)
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.placeName, "Myrtoan Sea")
        XCTAssertEqual(restored.presetName, "Contour Study")
        XCTAssertEqual(restored.hiddenLayers, ["buildings"])
        XCTAssertEqual(restored.area.bbox, BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1))
    }

    /// Ticks and inline settings must both come back, or the map redraws differently
    /// from the one that was saved.
    func testTheSourceStackComesBackAsItWasLeft() throws {
        var stack = SourceStack()
        stack.setEnabled(SourceID.terrainTiles, true)
        stack.setEnabled(SourceID.usgsEarthquakes, true)
        stack.setSetting(SourceID.terrainTiles, "interval", .number(50))
        stack.setSetting(SourceID.usgsEarthquakes, "magnitude", .number(4.5))
        stack.setSetting(SourceID.gibsImagery, "layer", .text("VIIRS_Black_Marble"))

        let restored = Session(
            stack: stack, area: Session.Area(BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)),
            placeName: "", preset: "Night", quality: "preview_fast", hiddenLayers: []
        ).stack()

        XCTAssertEqual(restored.enabledIDs, stack.enabledIDs)
        XCTAssertEqual(
            restored.providerOverrides(for: SourceID.terrainTiles),
            ["contourIntervalMetres": .number(50)]
        )
        XCTAssertEqual(
            restored.providerOverrides(for: SourceID.usgsEarthquakes),
            ["minMagnitude": .number(4.5)]
        )
        XCTAssertEqual(
            restored.providerOverrides(for: SourceID.gibsImagery),
            ["layer": .text("VIIRS_Black_Marble")]
        )
    }

    /// A band count is an integer and must not come back as `6.0 bands`.
    func testASettingKeepsItsDeclaredShape() throws {
        var stack = SourceStack()
        stack.setSetting(SourceID.terrainTiles, "bands", .integer(6))

        let restored = Session(
            stack: stack, area: Session.Area(BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)),
            placeName: "", preset: "Night", quality: "preview_fast", hiddenLayers: []
        ).stack()

        let bands = try XCTUnwrap(restored.settings(for: SourceID.terrainTiles).first { $0.key == "bands" })
        XCTAssertEqual(bands.value, .integer(6))
        XCTAssertEqual(bands.display, "6")
    }

    /// A file-backed source cannot be ticked before its file is known, so the path
    /// has to be restored first.
    func testAFileBackedSourceComesBackTicked() throws {
        var stack = SourceStack()
        stack.setPath(SourceID.localOSMPBF, "/data/greece.osm.pbf")
        stack.setEnabled(SourceID.localOSMPBF, true)

        let restored = Session(
            stack: stack, area: Session.Area(BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1)),
            placeName: "", preset: "Night", quality: "preview_fast", hiddenLayers: []
        ).stack()

        XCTAssertEqual(restored.path(SourceID.localOSMPBF), "/data/greece.osm.pbf")
        XCTAssertTrue(restored.isEnabled(SourceID.localOSMPBF), "the tick was lost with the path")
    }

    /// Losing the settings must not stop the app opening.
    func testAnUnreadableFileGivesTheDefaults() {
        let url = temporaryURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try? Data("this is not JSON".utf8).write(to: url)
        XCTAssertEqual(Session.read(from: url), Session())
        XCTAssertEqual(Session.read(from: URL(fileURLWithPath: "/nowhere/at/all.json")), Session())
    }

    /// Quietly swapping the numbers would hide whatever produced them.
    func testABackwardsAreaIsRejectedRatherThanCorrected() {
        XCTAssertNil(Session.Area(west: 10, south: 0, east: 5, north: 1).bbox)
        XCTAssertNil(Session.Area(west: 0, south: 5, east: 1, north: 0).bbox)
        XCTAssertNil(Session.Area(west: -200, south: 0, east: 5, north: 1).bbox)
        XCTAssertNotNil(Session.Area(west: 0, south: 0, east: 1, north: 1).bbox)
    }

    /// The derived-layer switches are choices the app holds, so the session holds

    /// A session written before the derived block existed still reads — losing
    /// every other choice because one new field is absent would make an update


    /// The defaults have to be a map that works, not a blank.
    func testTheDefaultSessionIsUsable() {
        let session = Session()
        XCTAssertNotNil(session.area.bbox)
        XCTAssertEqual(session.stack().enabledIDs, [SourceID.overpass])
        XCTAssertEqual(Presets.preset(session.presetName).name, session.presetName)
        XCTAssertEqual(Quality.profile(session.qualityKey).key, session.qualityKey)
    }
}
