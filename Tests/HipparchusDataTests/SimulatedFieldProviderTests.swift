import XCTest
import HipparchusGeometry
@testable import HipparchusData

/// The one source that needs nothing: no file, no account, no network.
final class SimulatedFieldProviderTests: XCTestCase {

    private let santorini = BBoxQuery(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)

    private func provider(_ configure: (inout TerrainFieldSettings) -> Void = { _ in })
        -> SimulatedFieldProvider {
        var settings = TerrainFieldSettings()
        // A smaller grid keeps the suite quick; the parity tests cover the real one.
        settings.gridSize = 96
        configure(&settings)
        return SimulatedFieldProvider(settings: settings)
    }

    // MARK: - What it produces

    func testItContoursItsOwnFieldWithoutTouchingAnything() async throws {
        let collection = try await provider().fetch(santorini)

        XCTAssertFalse(collection.features(in: TerrainLayer.minorContours).isEmpty)
        XCTAssertFalse(collection.features(in: TerrainLayer.indexContours).isEmpty)
        XCTAssertEqual(collection.bbox, santorini.bbox)

        for feature in collection.features(in: TerrainLayer.minorContours) {
            guard case .lineString(let line) = feature.geometry else {
                return XCTFail("a contour is a line")
            }
            XCTAssertGreaterThanOrEqual(line.coordinates.count, 2)
        }
    }

    /// The whole reason the provenance vocabulary exists. This source makes
    /// beautiful relief that is not a measurement of anywhere.
    func testEverythingItMakesDeclaresItselfSynthetic() async throws {
        let collection = try await provider().fetch(santorini)

        XCTAssertEqual(collection.provenance, .synthetic)
        XCTAssertEqual(collection.metadata["synthetic"]?.boolValue, true)
        XCTAssertEqual(collection.metadata["elevation_model"]?.stringValue, "generated")

        let features = TerrainLayer.all.flatMap { collection.features(in: $0) }
        XCTAssertFalse(features.isEmpty)
        XCTAssertTrue(features.allSatisfy { $0.provenance == .synthetic })
        XCTAssertTrue(features.allSatisfy { $0.property("synthetic")?.boolValue == true })
    }

    /// Kickoff detail 7: a fixed interval empties a small window and floods a
    /// large one, so the interval follows the relief actually in view.
    func testTheContourIntervalIsARoundNumberChosenFromTheRelief() async throws {
        let collection = try await provider().fetch(santorini)
        let interval = try XCTUnwrap(collection.metadata["contour_interval_metres"]?.doubleValue)

        XCTAssertGreaterThan(interval, 0)
        // A 1, 2 or 5 step: a number a person would write down.
        let mantissa = interval / pow(10, (log10(interval)).rounded(.down))
        XCTAssertTrue(
            [1.0, 2.0, 5.0, 10.0].contains { abs($0 - mantissa) < 1e-9 },
            "\(interval) m is not a round interval"
        )
    }

    func testAnExplicitIntervalIsHonoured() async throws {
        let collection = try await provider { $0.contourIntervalMetres = 25 }.fetch(santorini)
        XCTAssertEqual(collection.metadata["contour_interval_metres"]?.doubleValue, 25)

        for feature in collection.features(in: TerrainLayer.minorContours) {
            let elevation = try XCTUnwrap(feature.property("elevation")?.doubleValue)
            XCTAssertEqual(elevation.truncatingRemainder(dividingBy: 25), 0, accuracy: 1e-6)
        }
    }

    /// The dense sheet accents nothing: depth is carried by how tightly the lines
    /// crowd, and a heavier line every fifth only interrupts that.
    func testTheDenseSheetHasNoIndexContours() async throws {
        var settings = TerrainFieldSettings.denseRelief
        settings.gridSize = 96
        let collection = try await SimulatedFieldProvider(settings: settings).fetch(santorini)

        let ordinary = try await provider().fetch(santorini)

        XCTAssertTrue(collection.features(in: TerrainLayer.indexContours).isEmpty)
        XCTAssertGreaterThan(
            collection.features(in: TerrainLayer.minorContours).count,
            ordinary.features(in: TerrainLayer.minorContours).count,
            "the dense sheet should carry far more lines"
        )
    }

    // MARK: - Determinism and continuity

    /// Deterministic in the seed, or a map could not be redrawn.
    func testTheSameSeedAlwaysDrawsTheSameLandscape() async throws {
        let first = try await provider().fetch(santorini)
        let second = try await provider().fetch(santorini)

        XCTAssertEqual(
            first.features(in: TerrainLayer.minorContours).count,
            second.features(in: TerrainLayer.minorContours).count
        )
        XCTAssertEqual(
            first.metadata["elevation_max_metres"]?.doubleValue,
            second.metadata["elevation_max_metres"]?.doubleValue
        )
    }

    func testADifferentSeedIsADifferentLandscape() async throws {
        let first = try await provider { $0.seed = 1729 }.fetch(santorini)
        let second = try await provider { $0.seed = 4104 }.fetch(santorini)

        XCTAssertNotEqual(
            first.metadata["elevation_max_metres"]?.doubleValue,
            second.metadata["elevation_max_metres"]?.doubleValue
        )
    }

    /// Anchored to geography, not to the window. This is what makes the result
    /// usable as a map rather than as wallpaper: panning shows more of the same
    /// landscape instead of re-rolling a new one.
    func testPanningWalksAcrossOneContinuousLandscape() throws {
        var settings = TerrainFieldSettings()
        settings.gridSize = 96

        // Two windows of identical size, side by side and overlapping by half.
        let left = BoundingBox(minLon: 25.30, minLat: 36.33, maxLon: 25.40, maxLat: 36.43)
        let right = BoundingBox(minLon: 25.35, minLat: 36.33, maxLon: 25.45, maxLat: 36.43)

        // Same rung of the ladder, so the landscape is at the same scale.
        XCTAssertEqual(
            SimulatedField.wavelengthDegrees(left, settings: settings),
            SimulatedField.wavelengthDegrees(right, settings: settings)
        )

        let leftGrid = SimulatedField.elevationGrid(left, settings: settings)
        let rightGrid = SimulatedField.elevationGrid(right, settings: settings)

        // The point at lon 25.375, lat 36.38 sits in both, and must be the same
        // height read from either.
        let provider = SimulatedFieldProvider(settings: settings)
        let probe = Coordinate(lon: 25.375, lat: 36.38)
        XCTAssertEqual(
            provider.sample(leftGrid, at: probe, bounds: left),
            provider.sample(rightGrid, at: probe, bounds: right),
            accuracy: 1.0,
            "the same ground read two different heights, so this is wallpaper not terrain"
        )
    }

    /// The landform ladder is quantised, so nudging an area's size by a few percent
    /// must land on the same rung and change nothing.
    func testANudgedWindowStaysOnTheSameRung() {
        let settings = TerrainFieldSettings()
        let base = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)
        let nudged = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.505, maxLat: 36.485)

        XCTAssertEqual(
            SimulatedField.wavelengthDegrees(base, settings: settings),
            SimulatedField.wavelengthDegrees(nudged, settings: settings)
        )
    }

    /// Relief grows with landform size, near-linearly as real terrain does: a
    /// 1 km-wide window with a kilometre of relief would be a cliff, not a hill.
    func testASmallWindowGetsLessReliefThanALargeOne() {
        let settings = TerrainFieldSettings()
        let small = BoundingBox(minLon: 25.40, minLat: 36.39, maxLon: 25.41, maxLat: 36.40)
        let large = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)

        XCTAssertLessThan(
            SimulatedField.reliefMetres(small, settings: settings),
            SimulatedField.reliefMetres(large, settings: settings)
        )
    }

    /// Band-limiting to the grid keeps a wide window from summing detail it has no
    /// pixels to draw, which would only arrive as speckle.
    func testAFinerGridResolvesMoreOctaves() {
        var coarse = TerrainFieldSettings()
        coarse.gridSize = 64
        var fine = TerrainFieldSettings()
        fine.gridSize = 512

        let bounds = BoundingBox(minLon: 23.2, minLat: 36.3, maxLon: 24.2, maxLat: 37.1)
        XCTAssertLessThan(
            SimulatedField.resolvableOctaves(bounds, settings: coarse),
            SimulatedField.resolvableOctaves(bounds, settings: fine)
        )
    }

    // MARK: - Winding

    /// Contours are wound with the high ground on the left, which is what lets the
    /// renderer light the sheet without dragging the elevation grid through it.
    func testContoursAreWoundWithHighGroundOnTheLeft() async throws {
        let settings = { () -> TerrainFieldSettings in
            var settings = TerrainFieldSettings()
            settings.gridSize = 96
            return settings
        }()
        let provider = SimulatedFieldProvider(settings: settings)
        let collection = try await provider.fetch(santorini)
        let grid = SimulatedField.elevationGrid(santorini.bbox, settings: settings)
        let probe = provider.probeStep(grid: grid, bounds: santorini.bbox)

        var checked = 0
        var correct = 0
        for feature in collection.features(in: TerrainLayer.minorContours).prefix(40) {
            guard case .lineString(let line) = feature.geometry, line.coordinates.count >= 4,
                  let level = feature.property("elevation")?.doubleValue
            else {
                continue
            }
            let index = line.coordinates.count / 2
            let start = line.coordinates[index - 1]
            let end = line.coordinates[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { continue }

            // Left of travel, in the same y-up space the orienting pass works in.
            let midpoint = Coordinate(
                x: (start.x + end.x) / 2 - dy / length * probe,
                y: (start.y + end.y) / 2 + dx / length * probe
            )
            checked += 1
            if provider.sample(grid, at: midpoint, bounds: santorini.bbox) >= level { correct += 1 }
        }

        XCTAssertGreaterThan(checked, 10)
        // Not every segment: a contour that closes tightly around a summit can read
        // the far side of the hill at half a cell out. The overwhelming majority
        // must be right, which is what the illumination pass depends on.
        XCTAssertGreaterThan(Double(correct) / Double(checked), 0.9, "\(correct)/\(checked) wound uphill-left")
    }

    // MARK: - What the provider hands back

    /// A contour that runs past the frame would be clipped later, but the source
    /// should not be producing ground nobody asked for in the first place.
    func testContoursStayInsideTheRequestedArea() async throws {
        let collection = try await provider().fetch(santorini)
        let bbox = santorini.bbox

        var checked = 0
        for feature in collection.features(in: TerrainLayer.minorContours) {
            for line in feature.geometry.lineStrings {
                for point in line.coordinates {
                    XCTAssertGreaterThanOrEqual(point.lon, bbox.minLon - 1e-6)
                    XCTAssertLessThanOrEqual(point.lon, bbox.maxLon + 1e-6)
                    XCTAssertGreaterThanOrEqual(point.lat, bbox.minLat - 1e-6)
                    XCTAssertLessThanOrEqual(point.lat, bbox.maxLat + 1e-6)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "no vertices were examined")
    }

    /// Contours sit on multiples of the interval, and index contours on
    /// multiples of the interval times `indexEvery` — that is what makes the
    /// heavier line mean something rather than being every fifth line drawn.
    func testElevationsSitOnTheContourInterval() async throws {
        let collection = try await provider().fetch(santorini)
        let interval = try XCTUnwrap(collection.metadata["contour_interval_metres"]?.doubleValue)
        let indexEvery = try XCTUnwrap(collection.metadata["index_every"]?.doubleValue)
        XCTAssertGreaterThan(interval, 0)

        func remainder(_ elevation: Double, _ step: Double) -> Double {
            let scaled = (elevation / step).rounded()
            return abs(elevation - scaled * step)
        }

        for feature in collection.features(in: TerrainLayer.minorContours) {
            let elevation = try XCTUnwrap(feature.property("elevation")?.doubleValue)
            XCTAssertLessThan(remainder(elevation, interval), 1e-6, "\(elevation) is off the interval")
        }
        for feature in collection.features(in: TerrainLayer.indexContours) {
            let elevation = try XCTUnwrap(feature.property("elevation")?.doubleValue)
            XCTAssertLessThan(
                remainder(elevation, interval * indexEvery), 1e-6,
                "\(elevation) is not an index level"
            )
        }
    }

    /// Steep ground crowds contours below the grid's own resolution, and the
    /// crumbs that result are noise rather than terrain.
    func testSubCellSpecksAreDropped() async throws {
        let kept = try await provider().fetch(santorini)
        let unfiltered = try await provider { $0.minContourLengthCells = 0 }.fetch(santorini)

        XCTAssertLessThan(
            kept.features(in: TerrainLayer.minorContours).count,
            unfiltered.features(in: TerrainLayer.minorContours).count,
            "the length filter dropped nothing at all"
        )
    }

    /// The layers this source cannot fill are present and empty rather than
    /// absent, so a stack that includes it still explains itself in the panel.
    func testTheLayersItCannotFillArePresentAndEmpty() async throws {
        let collection = try await provider().fetch(santorini)

        for layer in [TerrainLayer.minorContours, TerrainLayer.indexContours] {
            XCTAssertNotNil(collection.featuresByLayer[layer])
        }
        XCTAssertFalse(
            collection.features(in: TerrainLayer.minorContours).isEmpty,
            "the one layer it exists to fill came back empty"
        )
    }

    // MARK: - Degenerate input

    func testADegenerateAreaIsNoContoursRatherThanACrash() async throws {
        let collection = try await provider().fetch(
            BBoxQuery(minLon: 25.4, minLat: 36.4, maxLon: 25.4, maxLat: 36.4)
        )
        XCTAssertEqual(collection.provenance, .synthetic)
        XCTAssertTrue(collection.features(in: TerrainLayer.minorContours).isEmpty)
    }
}
