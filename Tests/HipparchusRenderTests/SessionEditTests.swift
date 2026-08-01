import XCTest
import HipparchusData
@testable import HipparchusRender

/// What to call the thing that just happened.
///
/// macOS puts the action name in the Edit menu — "Undo Change Preset", "Undo
/// Enable OpenStreetMap" — and a menu that only ever says "Undo" tells you
/// nothing. Naming lived in the app target, where nothing could test it; it is a
/// pure function of two `Session` values, so it lives here instead.
final class SessionEditTests: XCTestCase {

    private func describe(_ change: (inout Session) -> Void) -> SessionEdit.Description? {
        let before = Session()
        var after = before
        change(&after)
        return SessionEdit.describe(from: before, to: after)
    }

    // MARK: - Nothing happened

    /// Observation can fire without anything changing, and a no-op must not
    /// become an entry in the menu.
    func testAnUnchangedSessionDescribesNothing() {
        XCTAssertNil(SessionEdit.describe(from: Session(), to: Session()))
    }

    // MARK: - Sources

    func testTickingASourceIsNamedForTheSource() {
        let edit = describe { $0.enabledSources.append(SourceID.terrainTiles) }
        XCTAssertEqual(edit?.action, "Enable Elevation")
        XCTAssertNil(edit?.coalescingKey, "a tick is a single act, never merged with the next")
    }

    func testUntickingASourceSaysSo() {
        let edit = describe { $0.enabledSources.removeAll { $0 == SourceID.overpass } }
        XCTAssertEqual(edit?.action, "Disable OpenStreetMap")
    }

    func testChoosingAFileIsNamedForTheSourceItFeeds() {
        let edit = describe { $0.sourcePaths[SourceID.naturalEarth] = "/tmp/ne.shp" }
        XCTAssertEqual(edit?.action, "Choose File for Natural Earth")
    }

    /// A stepper drag is one intention, so the setting's own key coalesces.
    func testASourceSettingIsNamedAndCoalesces() {
        let edit = describe { $0.sourceSettings["terrain_tiles.interval"] = 50 }
        // The sidebar's own word for it, so the menu and the row agree.
        XCTAssertEqual(edit?.action, "Change Interval")
        XCTAssertEqual(edit?.coalescingKey, "stack.terrain_tiles.interval")
    }

    func testAChoiceSettingIsNamedToo() {
        let edit = describe { $0.sourceChoices["gibs_imagery.layer"] = "VIIRS_SNPP_DayNightBand" }
        XCTAssertEqual(edit?.action, "Change Layer")
    }

    /// A setting nobody declared still produces a sentence rather than a crash.
    func testAnUnknownSettingFallsBackToAReadableName() {
        let edit = describe { $0.sourceSettings["terrain_tiles.chromaticity"] = 3 }
        XCTAssertEqual(edit?.action, "Change Setting")
    }

    // MARK: - Style

    func testChangingThePresetAndTheQuality() {
        XCTAssertEqual(describe { $0.presetName = "Night" }?.action, "Change Preset")
        XCTAssertEqual(describe { $0.qualityKey = "export_print" }?.action, "Change Quality")
    }

    // MARK: - Derived layers


    // MARK: - Layers

    func testHidingAndShowingALayerUseThePanelsOwnName() {
        let hidden = describe { $0.hiddenLayers = ["terrain_index_contours"] }
        XCTAssertEqual(hidden?.action, "Hide Index contours")

        var before = Session()
        before.hiddenLayers = ["buildings"]
        XCTAssertEqual(
            SessionEdit.describe(from: before, to: Session())?.action, "Show Buildings"
        )
    }

    // MARK: - The area

    func testMovingTheAreaCoalesces() {
        let edit = describe { $0.area.west = 24.0 }
        XCTAssertEqual(edit?.action, "Change Area")
        XCTAssertEqual(edit?.coalescingKey, "area", "typing four numbers is one action")
    }

    func testRenamingTheAreaIsStillAnAreaChange() {
        XCTAssertEqual(describe { $0.placeName = "Thera" }?.action, "Change Area")
    }

    // MARK: - Precedence

    /// One gesture changes one thing. When a change carries several — adopting a
    /// preset brings its derivation sizes with it — the most specific thing the
    /// user actually reached for wins, and the rest ride along in the same entry.
    func testTheSourceStackOutranksEverythingElse() {
        var after = Session()
        after.enabledSources.append(SourceID.terrainTiles)
        after.presetName = "Night"
        after.area.west = 20

        XCTAssertEqual(SessionEdit.describe(from: Session(), to: after)?.action, "Enable Elevation")
    }

    func testThePresetOutranksTheSizesItBrings() {
        var after = Session()
        after.presetName = "Fragmented Urban"

        XCTAssertEqual(SessionEdit.describe(from: Session(), to: after)?.action, "Change Preset")
    }
}
