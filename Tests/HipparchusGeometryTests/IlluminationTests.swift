import XCTest
@testable import HipparchusGeometry

/// Ported from `tests/test_illumination.py`.
///
/// Illuminated contours: stroke weight varying along a line to read as depth.

/// Winding order is the only channel a bare line has for slope aspect.
final class OrientationTests: XCTestCase {

    /// Ground rising towards +x.
    private let rampEast: (Coordinate) -> Double = { $0.x }

    func testALineIsWoundWithHighGroundOnItsLeft() {
        // Contour of the east-rising ramp at x = 5: a vertical line. High ground is
        // to the east, so travel must be southward for it to be on the left.
        let line = [Coordinate(x: 5, y: 10), Coordinate(x: 5, y: 0)]
        let oriented = orientUphillLeft(line, sample: rampEast, level: 5.0, probe: 0.5)
        XCTAssertEqual(oriented.first?.y, 10.0)
        XCTAssertEqual(oriented.last?.y, 0.0)
    }

    func testABackwardsLineIsReversed() {
        let line = [Coordinate(x: 5, y: 0), Coordinate(x: 5, y: 10)]
        let oriented = orientUphillLeft(line, sample: rampEast, level: 5.0, probe: 0.5)
        XCTAssertEqual(oriented.first?.y, 10.0)
    }

    func testOrientationIsIdempotent() {
        let line = [Coordinate(x: 5, y: 0), Coordinate(x: 5, y: 10)]
        let once = orientUphillLeft(line, sample: rampEast, level: 5.0, probe: 0.5)
        let twice = orientUphillLeft(once, sample: rampEast, level: 5.0, probe: 0.5)
        XCTAssertEqual(once, twice)
    }

    func testDegenerateInputIsReturnedUnchanged() {
        XCTAssertEqual(orientUphillLeft([], sample: rampEast, level: 0, probe: 0.5), [])
        let single = [Coordinate(x: 1, y: 1)]
        XCTAssertEqual(orientUphillLeft(single, sample: rampEast, level: 0, probe: 0.5), single)
        let repeated = [Coordinate(x: 1, y: 1), Coordinate(x: 1, y: 1)]
        XCTAssertEqual(orientUphillLeft(repeated, sample: rampEast, level: 0, probe: 0.5), repeated)
    }
}

final class IlluminationWeightTests: XCTestCase {

    func testShadowedSlopesDrawHeavierThanLitOnes() {
        let profile = IlluminationProfile(azimuthDegrees: 315, bands: 5, litScale: 0.4, shadowScale: 1.9)
        XCTAssertEqual(profile.weight(for: 1.0), 0.4, accuracy: 1e-12)
        XCTAssertEqual(profile.weight(for: -1.0), 1.9, accuracy: 1e-12)
        XCTAssertGreaterThan(profile.weight(for: -0.5), profile.weight(for: 0.5))
    }

    func testWeightsAreQuantisedIntoBands() {
        let profile = IlluminationProfile(bands: 3, litScale: 1.0, shadowScale: 2.0)
        let weights = Set(linspace(-1.0, 1.0, 50).map { profile.weight(for: $0) })
        XCTAssertEqual(weights.count, 3)
    }

    func testASingleBandGivesOneUniformWeight() {
        let profile = IlluminationProfile(bands: 1, litScale: 0.5, shadowScale: 2.0)
        let weights = Set([-1.0, 0.0, 1.0].map { profile.weight(for: $0) })
        XCTAssertEqual(weights.count, 1)
    }

    func testAnOutOfRangeLitValueIsClamped() {
        let profile = IlluminationProfile(bands: 5, litScale: 0.4, shadowScale: 1.9)
        XCTAssertEqual(profile.weight(for: 12.0), profile.weight(for: 1.0), accuracy: 1e-12)
        XCTAssertEqual(profile.weight(for: -12.0), profile.weight(for: -1.0), accuracy: 1e-12)
    }
}

final class IlluminateGeometriesTests: XCTestCase {
    private let profile = IlluminationProfile(azimuthDegrees: 315, bands: 5, litScale: 0.4, shadowScale: 1.9)

    func testGeometryAndWeightListsStayParallel() {
        let ring = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0),
            Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10), Coordinate(x: 0, y: 0),
        ]))
        let runs = illuminate([ring], profile: profile)
        XCTAssertFalse(runs.isEmpty)
        // One weight per chunk, by construction: a run *is* a chunk and a weight.
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.line.coordinates.count, 2)
            XCTAssertGreaterThan(run.weight, 0)
        }
    }

    /// A hill lit from one side must not come out at one uniform weight.
    func testAClosedRingIsSplitIntoLitAndShadowedRuns() {
        let ring = Geometry.lineString(LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0),
            Coordinate(x: 10, y: 10), Coordinate(x: 0, y: 10), Coordinate(x: 0, y: 0),
        ]))
        let weights = illuminate([ring], profile: profile).map(\.weight)
        XCTAssertGreaterThan(Set(weights).count, 1)
        XCTAssertGreaterThan(weights.max()!, weights.min()!)
    }

    func testTheLitSideIsOppositeTheShadowedSide() {
        // Ring wound counter-clockwise: the left of travel points outward, so the
        // north-west arc faces the north-west light.
        let radius = 10.0
        let coordinates = stride(from: 0, through: 360, by: 10).map { degrees in
            Coordinate(
                x: radius * cos(Double(degrees) * .pi / 180),
                y: radius * sin(Double(degrees) * .pi / 180)
            )
        }
        let runs = illuminate([.lineString(LineString(coordinates))], profile: profile)

        let lightest = runs.min { $0.weight < $1.weight }!
        let heaviest = runs.max { $0.weight < $1.weight }!
        let towardsLight = Coordinate(x: -radius * 0.7071, y: radius * 0.7071)

        func nearestDistance(_ line: LineString, to point: Coordinate) -> Double {
            line.coordinates
                .map { ((($0.x - point.x) * ($0.x - point.x)) + (($0.y - point.y) * ($0.y - point.y))).squareRoot() }
                .min() ?? .infinity
        }
        XCTAssertLessThan(
            nearestDistance(lightest.line, to: towardsLight),
            nearestDistance(heaviest.line, to: towardsLight),
            "the thinnest stroke must sit on the side facing the light"
        )
    }

    func testReversingALineSwapsLitForShadowed() {
        let coordinates = [Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0)]
        let forward = illuminate([.lineString(LineString(coordinates))], profile: profile).map(\.weight)
        let reverse = illuminate([.lineString(LineString(coordinates.reversed()))], profile: profile).map(\.weight)
        XCTAssertNotEqual(forward, reverse)
    }

    func testChunksCoverTheWholeLine() {
        let line = LineString([
            Coordinate(x: 0, y: 0), Coordinate(x: 5, y: 5),
            Coordinate(x: 10, y: 0), Coordinate(x: 15, y: 5),
        ])
        let runs = illuminate([.lineString(line)], profile: profile)
        let total = runs.reduce(0.0) { $0 + $1.line.length }
        XCTAssertEqual(total, line.length, accuracy: 1e-6)
    }

    /// One chunk per segment would explode the SVG into unusable fragments.
    func testRunsAreMergedRatherThanSplitPerSegment() {
        let straight = LineString((0..<60).map { Coordinate(x: Double($0), y: 0) })
        XCTAssertEqual(illuminate([.lineString(straight)], profile: profile).count, 1)
    }

    func testPolygonsAndPointsAreIgnored() {
        XCTAssertTrue(illuminate([.point(Coordinate(x: 1, y: 1))], profile: profile).isEmpty)
        let square = Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 0), Coordinate(x: 1, y: 1), Coordinate(x: 0, y: 1),
        ])
        XCTAssertTrue(illuminate([.polygon(square)], profile: profile).isEmpty)
    }

    func testEmptyInputIsSafe() {
        XCTAssertTrue(illuminate([], profile: profile).isEmpty)
    }

    func testMultiLineStringsAreHandledPartByPart() {
        // Eastward means the slope falls south; westward means it falls north.
        // Under a north-west light those are the shadowed and the lit extreme.
        //
        // Note what does *not* work as a test here: eastward and northward come out
        // at the same weight, because south and east are both 135 degrees off a
        // north-west light. Perpendicular lines are not necessarily lit differently.
        let geometry = Geometry.multiLineString([
            LineString([Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0)]),
            LineString([Coordinate(x: 0, y: 5), Coordinate(x: -10, y: 5)]),
        ])
        let runs = illuminate([geometry], profile: profile)
        XCTAssertEqual(runs.count, 2)
        XCTAssertGreaterThan(runs[0].weight, runs[1].weight)
    }

    /// The azimuth is a compass bearing: degrees clockwise from north.
    func testTheLightComesFromTheAzimuthGiven() {
        // Travelling east with high ground on the left (north) means the slope
        // falls south. A light from the south lights it; a light from the north
        // shadows it.
        let eastward = Geometry.lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0)]))
        let fromSouth = illuminate([eastward], profile: IlluminationProfile(azimuthDegrees: 180)).map(\.weight)
        let fromNorth = illuminate([eastward], profile: IlluminationProfile(azimuthDegrees: 0)).map(\.weight)
        XCTAssertLessThan(fromSouth[0], fromNorth[0], "a slope facing the light must draw lighter")
    }
}

import Foundation
