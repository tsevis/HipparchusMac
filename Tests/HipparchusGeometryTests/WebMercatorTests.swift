import XCTest
@testable import HipparchusGeometry

/// Ported from `ProjectionTests` in `tests/test_terrain_tiles.py`.
final class WebMercatorTests: XCTestCase {

    func testPixelAndLonLatRoundTrip() {
        for (lon, lat) in [(23.75, 37.96), (-122.4, 37.8), (11.0, 60.0), (0.0, 0.0), (150.0, -33.9)] {
            let pixel = WebMercator.pixel(lon: lon, lat: lat, zoom: 12)
            let back = WebMercator.lonLatForPixel(x: pixel.x, y: pixel.y, zoom: 12)
            XCTAssertEqual(back.lon, lon, accuracy: 1e-6, "lon at \(lon), \(lat)")
            XCTAssertEqual(back.lat, lat, accuracy: 1e-6, "lat at \(lon), \(lat)")
        }
    }

    /// Kickoff detail 2. The bug this guards: a linear row-to-latitude map.
    func testLatitudeSpacingIsNotLinear() {
        let zoom = 10
        let world = WebMercator.worldPixels(zoom: zoom)
        let nearEquator = WebMercator.lonLatForPixel(x: 0, y: world / 2.0, zoom: zoom).lat
            - WebMercator.lonLatForPixel(x: 0, y: world / 2.0 + 100.0, zoom: zoom).lat
        let farNorth = WebMercator.lonLatForPixel(x: 0, y: world * 0.25, zoom: zoom).lat
            - WebMercator.lonLatForPixel(x: 0, y: world * 0.25 + 100.0, zoom: zoom).lat
        XCTAssertGreaterThan(nearEquator, farNorth * 1.5)
    }

    /// The same displacement said in metres, so the consequence is legible rather
    /// than merely non-linear.
    ///
    /// Measured values, mid-frame, for a linear row-to-latitude map:
    /// Santorini 0.15° → 4 m, Athens 0.32° → 19 m, the same span at Oslo's
    /// latitude → 43 m, the Myrtoan Sea 0.8° → 116 m, the Aegean 8.5° → 13.6 km.
    /// It grows with frame height *and* with latitude, which is why it is not
    /// something a tolerance can absorb.
    func testALinearRowMapDisplacesContoursByAMeasurableDistance() {
        func midFrameErrorMetres(_ bounds: BoundingBox, zoom: Int) -> Double {
            let top = WebMercator.pixel(lon: bounds.minLon, lat: bounds.maxLat, zoom: zoom)
            let bottom = WebMercator.pixel(lon: bounds.maxLon, lat: bounds.minLat, zoom: zoom)
            let correct = WebMercator.lonLatForPixel(x: top.x, y: (top.y + bottom.y) / 2.0, zoom: zoom).lat
            let naive = (bounds.maxLat + bounds.minLat) / 2.0
            return abs(correct - naive) * 111_320.0
        }

        let athens = midFrameErrorMetres(
            BoundingBox(minLon: 23.575, minLat: 37.816, maxLon: 23.895, maxLat: 38.136), zoom: 12
        )
        XCTAssertEqual(athens, 19.4, accuracy: 0.5, "Athens: a fifth of a 100 m contour interval, out of place")

        // The same 0.32 degrees of latitude, further north.
        let oslo = midFrameErrorMetres(
            BoundingBox(minLon: 10.60, minLat: 59.80, maxLon: 10.92, maxLat: 60.12), zoom: 12
        )
        XCTAssertGreaterThan(oslo, athens * 2.0, "the error grows away from the equator")

        // A regional frame is out by kilometres.
        let aegean = midFrameErrorMetres(
            BoundingBox(minLon: 19.5, minLat: 33.5, maxLon: 30.0, maxLat: 42.0), zoom: 8
        )
        XCTAssertGreaterThan(aegean, 10_000.0)
    }

    func testTileIndicesMatchThePublishedScheme() {
        // Athens at zoom 11 is tile 1159/790 in the XYZ scheme.
        let tile = WebMercator.tile(lon: 23.75, lat: 37.96, zoom: 11)
        XCTAssertEqual(tile.x, 1159)
        XCTAssertEqual(tile.y, 790)
    }

    func testTilesAreClampedToTheWorld() {
        XCTAssertEqual(WebMercator.tile(lon: -181.0, lat: 89.0, zoom: 3).x, 0)
        XCTAssertEqual(WebMercator.tile(lon: 181.0, lat: -89.0, zoom: 3).x, 7)
    }

    func testLatitudeIsClampedAtTheMercatorLimit() {
        // Beyond ~85.05 degrees the projection diverges; the clamp is what stops
        // a polar frame producing infinities instead of pixels.
        let north = WebMercator.pixel(lon: 0, lat: 89.9, zoom: 5)
        XCTAssertTrue(north.y.isFinite)
        XCTAssertEqual(north.y, WebMercator.pixel(lon: 0, lat: WebMercator.maxLatitude, zoom: 5).y, accuracy: 1e-9)
    }
}

/// Ported from `tests/test_projection.py`.
final class ProjectionProfileTests: XCTestCase {

    func testWebMercatorRoundTripsAPoint() {
        let profile = ProjectionProfile(
            bbox: BoundingBox(minLon: 23.7, minLat: 37.9, maxLon: 23.8, maxLat: 38.0),
            mode: .webMercator
        )
        let projected = profile.project(Coordinate(lon: 23.75, lat: 37.95))
        let back = profile.unproject(projected)
        XCTAssertEqual(back.lon, 23.75, accuracy: 1e-6)
        XCTAssertEqual(back.lat, 37.95, accuracy: 1e-6)
    }

    func testLocalProjectionCentresTheFrame() {
        let profile = ProjectionProfile(
            bbox: BoundingBox(minLon: 10.0, minLat: 20.0, maxLon: 12.0, maxLat: 22.0),
            mode: .localAzimuthal
        )
        let projected = profile.project(Coordinate(lon: 11.0, lat: 21.0))
        XCTAssertEqual(projected.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(projected.y, 0.0, accuracy: 1e-6)
    }

    func testProjectingGeometryChangesTheCoordinateScale() {
        let profile = ProjectionProfile(
            bbox: BoundingBox(minLon: 0, minLat: 0, maxLon: 1, maxLat: 1),
            mode: .webMercator
        )
        let line = Geometry.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1)]))
        guard case .lineString(let projected) = profile.project(line) else {
            return XCTFail("projecting a line must give a line")
        }
        XCTAssertGreaterThan(projected.length, 100_000.0)
    }

    func testRawModeLeavesDegreesAlone() {
        let profile = ProjectionProfile(mode: .wgs84Raw)
        let point = Coordinate(lon: 12.5, lat: -33.9)
        XCTAssertEqual(profile.project(point), point)
        XCTAssertEqual(profile.unproject(point), point)
    }

    func testAnUnknownProjectionNameFallsBackRatherThanFailing() {
        XCTAssertEqual(ProjectionMode(name: "mollweide"), .webMercator)
        XCTAssertEqual(ProjectionMode(name: "web_mercator"), .webMercator)
        XCTAssertEqual(ProjectionMode(name: "local_azimuthal"), .localAzimuthal)
    }

    func testProjectedBoundsUseAllFourCorners() {
        let profile = ProjectionProfile(mode: .webMercator)
        let bbox = BoundingBox(minLon: -10, minLat: -20, maxLon: 30, maxLat: 40)
        let bounds = profile.project(bbox)
        XCTAssertEqual(bounds.minX, profile.project(Coordinate(lon: -10, lat: 0)).x, accuracy: 1e-6)
        XCTAssertEqual(bounds.maxY, profile.project(Coordinate(lon: 0, lat: 40)).y, accuracy: 1e-6)
    }

    func testMetadataNamesTheRenderCRS() {
        let profile = ProjectionProfile(mode: .webMercator)
        XCTAssertEqual(profile.metadata(bbox: nil)["render_crs"], "EPSG:3857")
        XCTAssertEqual(profile.sourceCRS, "EPSG:4326")
    }
}

/// Ported from `NiceIntervalTests` in `tests/test_simulated_field.py`.
final class NiceIntervalTests: XCTestCase {

    func testIntervalIsARoundNumber() {
        for range in [7.0, 83.0, 940.0, 12_500.0, 0.42] {
            let interval = niceInterval(range: range, targetLines: 40)
            let mantissa = interval / pow(10.0, (log10(interval)).rounded(.down))
            let nearest = [1.0, 2.0, 5.0].min { abs($0 - mantissa) < abs($1 - mantissa) }!
            XCTAssertEqual(nearest, mantissa, accuracy: 1e-9, "range \(range) gave interval \(interval)")
        }
    }

    func testIntervalGivesRoughlyTheRequestedLineCount() {
        let interval = niceInterval(range: 1000.0, targetLines: 40)
        XCTAssertGreaterThanOrEqual(1000.0 / interval, 20.0)
        XCTAssertLessThanOrEqual(1000.0 / interval, 80.0)
    }

    func testDegenerateRangeIsSafe() {
        XCTAssertGreaterThan(niceInterval(range: 0.0, targetLines: 40), 0.0)
        XCTAssertGreaterThan(niceInterval(range: -5.0, targetLines: 40), 0.0)
        XCTAssertGreaterThan(niceInterval(range: .nan, targetLines: 40), 0.0)
        XCTAssertGreaterThan(niceInterval(range: 100.0, targetLines: 0), 0.0)
    }

    /// Kickoff detail 7, stated as the consequence rather than the rule: the
    /// interval has to follow the relief in view, or a small window empties and a
    /// large one floods.
    func testTheIntervalFollowsTheReliefInView() {
        // Santorini: 604 m of relief. Everest: 3,686 m.
        let santorini = niceInterval(range: 525.0 - (-79.0), targetLines: 60)
        let everest = niceInterval(range: 8746.0 - 5060.0, targetLines: 60)
        XCTAssertLessThan(santorini, everest)
        for interval in [santorini, everest] {
            XCTAssertGreaterThan((525.0 - (-79.0)) / santorini, 20.0)
            XCTAssertTrue(interval > 0)
        }
        // And a fixed 20 m interval over Everest would ask for 184 lines.
        XCTAssertLessThan((8746.0 - 5060.0) / everest, 100.0)
    }

    /// Nearest is measured geometrically, and the two rules genuinely disagree.
    ///
    /// Normalised to a mantissa in `[1, 10)`, linear nearest switches candidate at
    /// 1.5, 3.5 and 7.5; geometric nearest switches at √2 ≈ 1.414, √10 ≈ 3.162 and
    /// √50 ≈ 7.071. In each of those three gaps the two rules pick differently,
    /// and geometric is the one that keeps the line count near the target.
    func testTheNearestCandidateIsGeometricNotLinear() {
        // mantissa 3.3: linear nearest is 2, geometric nearest is 5.
        XCTAssertEqual(niceInterval(range: 3.3 * 40.0, targetLines: 40), 5.0, accuracy: 1e-9)
        // mantissa 1.45: linear nearest is 1, geometric nearest is 2.
        XCTAssertEqual(niceInterval(range: 1.45 * 40.0, targetLines: 40), 2.0, accuracy: 1e-9)
        // mantissa 7.2: linear nearest is 5, geometric nearest is 10.
        XCTAssertEqual(niceInterval(range: 7.2 * 40.0, targetLines: 40), 10.0, accuracy: 1e-9)
    }

    func testTheMantissaIsAlwaysOneTwoFiveOrTenAcrossADecade() {
        for raw in stride(from: 0.11, through: 9.9, by: 0.07) {
            let interval = niceInterval(range: raw * 40.0, targetLines: 40)
            let mantissa = interval / pow(10.0, (log10(interval)).rounded(.down))
            XCTAssertTrue(
                [1.0, 2.0, 5.0].contains { abs($0 - mantissa) < 1e-9 },
                "raw \(raw) gave interval \(interval), mantissa \(mantissa)"
            )
            // Geometric nearest never lands more than a factor of √5 away.
            XCTAssertLessThan(max(interval / raw, raw / interval), 5.0.squareRoot() + 1e-9, "raw \(raw) -> \(interval)")
        }
    }
}

import Foundation
