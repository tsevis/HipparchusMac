import XCTest
@testable import HipparchusGeometry

/// Ported from `tests/test_orbits.py`.
///
/// The reference values in the kickoff are the point of this file: the ISS is
/// bounded at ±51.63° of latitude, sits 414–424 km up, goes round in 92.95 minutes
/// and drifts about −23.5° of longitude per orbit. A propagator that gets any of
/// those wrong is drawing a track for a satellite that does not exist.
final class OrbitsTests: XCTestCase {

    /// Real element set for the ISS, captured from Celestrak on 2026-07-28.
    static let issTLE = """
        ISS (ZARYA)
        1 25544U 98067A   26209.15252568  .00010831  00000+0  20282-3 0  9992
        2 25544  51.6320  97.3682 0007093 345.6120  14.4666 15.49220842578109
        """

    /// A second object at a very different inclination, to prove nothing is
    /// hardcoded around the ISS. Sun-synchronous, retrograde.
    static let sunSynchronousTLE = """
        NOAA 20
        1 43013U 17073A   26209.50000000  .00000100  00000+0  600-4 0  9995
        2 43013  98.7300 120.4000 0001200  90.0000 270.0000 14.19550000123456
        """

    private func iss() throws -> TwoLineElements {
        try XCTUnwrap(TwoLineElements.parseListing(Self.issTLE).first)
    }

    // MARK: - Parsing

    func testElementsAreReadFromANamedListing() throws {
        let elements = TwoLineElements.parseListing(Self.issTLE)
        XCTAssertEqual(elements.count, 1)

        let iss = try XCTUnwrap(elements.first)
        XCTAssertEqual(iss.name, "ISS (ZARYA)")
        XCTAssertEqual(iss.catalogNumber, "25544")
        XCTAssertEqual(iss.inclinationDegrees, 51.6320, accuracy: 1e-4)
        XCTAssertEqual(iss.eccentricity, 0.0007093, accuracy: 1e-7)
        XCTAssertEqual(iss.meanMotionRevPerDay, 15.49220842, accuracy: 1e-6)
    }

    /// Epoch is `YYDDD.DDDD`: day 209.15 of 2026 is 28 July, mid-morning UTC.
    func testTheEpochDecodesToTheRightInstant() throws {
        let epoch = try iss().epoch
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: epoch)

        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 28)
        let hours = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        XCTAssertEqual(hours, 3.66, accuracy: 0.05)
    }

    func testDerivedOrbitGeometryMatchesThePublishedValues() throws {
        let iss = try iss()
        XCTAssertEqual(iss.periodMinutes, 92.95, accuracy: 0.2)
        XCTAssertEqual(iss.semiMajorAxisKm - Orbits.earthRadiusKm, 419.0, accuracy: 15.0)
    }

    func testAListingWithoutNameLinesIsRead() {
        let bare = Self.issTLE.split(separator: "\n").dropFirst().joined(separator: "\n")
        let elements = TwoLineElements.parseListing(String(bare))
        XCTAssertEqual(elements.count, 1)
        XCTAssertEqual(elements.first?.name, "NORAD 25544")
    }

    /// Celestrak returns hundreds of sets at a time; one bad record is not a reason
    /// to draw nothing.
    func testOneMalformedSetDoesNotLoseTheRest() {
        let listing = """
            BROKEN SAT
            1 XXXXX this is not an element set
            2 XXXXX nor is this
            \(Self.issTLE)
            """
        let elements = TwoLineElements.parseListing(listing)
        XCTAssertEqual(elements.map(\.catalogNumber), ["25544"])
    }

    func testAnEmptyListingIsNoSatellitesRatherThanACrash() {
        XCTAssertTrue(TwoLineElements.parseListing("").isEmpty)
        XCTAssertTrue(TwoLineElements.parseListing("nonsense\nmore nonsense").isEmpty)
    }

    // MARK: - Propagation, against the published reference values

    /// A satellite cannot reach a latitude above its inclination. The ISS is
    /// inclined 51.63°, so ±51.63° is a hard ceiling on where it can ever be.
    func testLatitudeIsBoundedByInclination() throws {
        let iss = try iss()
        let track = Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 200, stepSeconds: 20)
        let latitudes = track.flatMap { $0 }.map(\.latitude)

        XCTAssertFalse(latitudes.isEmpty)
        XCTAssertLessThanOrEqual(latitudes.max() ?? 0, 51.63 + 0.2)
        XCTAssertGreaterThanOrEqual(latitudes.min() ?? 0, -51.63 - 0.2)
        // And it must actually get up there, or the bound is met by drawing nothing.
        XCTAssertGreaterThan(latitudes.max() ?? 0, 50.0)
        XCTAssertLessThan(latitudes.min() ?? 0, -50.0)
    }

    func testAltitudeStaysInTheKnownBand() throws {
        let iss = try iss()
        let altitudes = Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 100, stepSeconds: 30)
            .flatMap { $0 }
            .map(\.altitudeKm)

        XCTAssertGreaterThan(altitudes.min() ?? 0, 405, "far below the known 414 km floor")
        XCTAssertLessThan(altitudes.max() ?? 0, 435, "far above the known 424 km ceiling")
    }

    /// J2 nodal regression is what walks the track westward. Drop it and successive
    /// orbits retrace the same ground, which is visibly wrong on any world map.
    func testTheTrackDriftsWestwardByAboutTwentyThreeDegreesPerOrbit() throws {
        let iss = try iss()
        let period = iss.periodMinutes * 60

        // Compare the same point in two successive orbits: an ascending equator
        // crossing is the conventional place to measure nodal drift.
        let first = Orbits.subpoint(of: iss, at: iss.epoch)
        let second = Orbits.subpoint(of: iss, at: iss.epoch.addingTimeInterval(period))

        var drift = second.longitude - first.longitude
        if drift > 180 { drift -= 360 }
        if drift < -180 { drift += 360 }

        XCTAssertEqual(drift, -23.5, accuracy: 1.5, "the ground track is not regressing correctly")
    }

    func testAPolarOrbitReachesFarHigherLatitudesThanTheISS() throws {
        let polar = try XCTUnwrap(TwoLineElements.parseListing(Self.sunSynchronousTLE).first)
        let latitudes = Orbits.groundTrack(of: polar, start: polar.epoch, minutes: 120, stepSeconds: 30)
            .flatMap { $0 }
            .map(\.latitude)
        // 98.73° inclination is retrograde and near-polar: it passes over the caps.
        XCTAssertGreaterThan(latitudes.max() ?? 0, 80)
        XCTAssertLessThan(latitudes.min() ?? 0, -80)
    }

    // MARK: - Drawing the track

    /// A track crossing ±180° must not draw a line straight back across the map.
    func testTheTrackIsSplitAtTheAntimeridian() throws {
        let iss = try iss()
        // Long enough to wrap the world more than once.
        let runs = Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 200, stepSeconds: 30)

        XCTAssertGreaterThan(runs.count, 1, "the track was never split")
        for run in runs {
            for (previous, next) in zip(run, run.dropFirst()) {
                XCTAssertLessThanOrEqual(
                    abs(next.longitude - previous.longitude), 180,
                    "a run jumps the antimeridian, which draws a chord across the map"
                )
            }
        }
        XCTAssertTrue(runs.allSatisfy { $0.count >= 2 }, "a run of one point is not a line")
    }

    func testEveryLongitudeIsInRange() throws {
        let iss = try iss()
        for point in Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 200, stepSeconds: 25).flatMap({ $0 }) {
            XCTAssertGreaterThanOrEqual(point.longitude, -180)
            XCTAssertLessThanOrEqual(point.longitude, 180)
        }
    }

    func testAZeroWindowIsNoTrackRatherThanADegenerateOne() throws {
        let iss = try iss()
        XCTAssertTrue(Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 0).isEmpty)
        XCTAssertTrue(Orbits.groundTrack(of: iss, start: iss.epoch, minutes: 10, stepSeconds: 0).isEmpty)
    }

    /// From 420 km the horizon is roughly 20° away — the footprint a track drags
    /// across the ground.
    func testTheHorizonCircleGrowsWithAltitude() {
        let low = Orbits.horizonRadiusDegrees(altitudeKm: 420)
        let high = Orbits.horizonRadiusDegrees(altitudeKm: 35786)  // geostationary

        XCTAssertEqual(low, 19.8, accuracy: 1.0)
        XCTAssertGreaterThan(high, 80, "a geostationary satellite sees most of a hemisphere")
        XCTAssertLessThan(high, 90)
    }

    // MARK: - The maths underneath

    func testJulianDateMatchesAKnownEpoch() {
        // 2000-01-01T12:00:00Z is JD 2451545.0 by definition.
        let j2000 = Date(timeIntervalSince1970: 946_728_000)
        XCTAssertEqual(Orbits.julianDate(j2000), 2_451_545.0, accuracy: 1e-6)
    }

    func testKeplersEquationSolvesForACircularAndAnEccentricOrbit() {
        // A circular orbit has eccentric anomaly equal to mean anomaly.
        XCTAssertEqual(Orbits.solveKepler(meanAnomaly: 1.0, eccentricity: 0.0), 1.0, accuracy: 1e-12)

        // Otherwise the solution must satisfy E - e·sin E = M.
        for eccentricity in [0.01, 0.3, 0.7, 0.9] {
            for meanAnomaly in [0.1, 1.0, 3.0, 5.5] {
                let eccentric = Orbits.solveKepler(meanAnomaly: meanAnomaly, eccentricity: eccentricity)
                XCTAssertEqual(
                    eccentric - eccentricity * sin(eccentric), meanAnomaly, accuracy: 1e-9,
                    "e=\(eccentricity) M=\(meanAnomaly)"
                )
            }
        }
    }

    func testLongitudeWrappingKeepsTheAntimeridianIntact() {
        XCTAssertEqual(Orbits.wrappedLongitude(190), -170, accuracy: 1e-9)
        XCTAssertEqual(Orbits.wrappedLongitude(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(Orbits.wrappedLongitude(0), 0, accuracy: 1e-9)
        XCTAssertEqual(Orbits.wrappedLongitude(-180), -180, accuracy: 1e-9)
    }
}
