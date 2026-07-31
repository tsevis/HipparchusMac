import XCTest
@testable import HipparchusGeometry

/// A ring that runs past ±180° belongs on both edges of the sheet.
///
/// Ported from `_split_at_antimeridian`. Ground tracks were already split at the
/// date line; footprints were not, and wrapping each vertex on its own is worse
/// than not wrapping at all — a ring that steps from +179° to −179° between two
/// vertices draws a band straight across the whole map.
final class AntimeridianTests: XCTestCase {

    /// A ring that stays inside the map is returned untouched.
    func testARingInsideTheMapIsLeftAlone() {
        let ring = [
            Coordinate(lon: 20, lat: 30), Coordinate(lon: 30, lat: 30),
            Coordinate(lon: 30, lat: 40), Coordinate(lon: 20, lat: 40),
        ]
        let pieces = Orbits.splitAtAntimeridian(ring)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first ?? [], ring)
    }

    /// The case that draws the bug: a ring centred on the date line comes back as
    /// two pieces, one against each edge, and neither spans the world.
    func testARingOverTheDateLineBecomesTwoPiecesOnOppositeEdges() throws {
        let ring = [
            Coordinate(lon: 170, lat: 10), Coordinate(lon: 190, lat: 10),
            Coordinate(lon: 190, lat: 20), Coordinate(lon: 170, lat: 20),
        ]
        let pieces = Orbits.splitAtAntimeridian(ring)
        XCTAssertEqual(pieces.count, 2, "the ring did not divide at the date line")

        for piece in pieces {
            let lons = piece.map(\.lon)
            let span = (lons.max() ?? 0) - (lons.min() ?? 0)
            XCTAssertLessThan(span, 180, "a piece was stretched across the map")
            for lon in lons {
                XCTAssertLessThanOrEqual(lon, 180.0001)
                XCTAssertGreaterThanOrEqual(lon, -180.0001)
            }
        }

        // One piece hugs the eastern edge, the other the western.
        let east = try XCTUnwrap(pieces.first { $0.contains { $0.lon > 0 } })
        let west = try XCTUnwrap(pieces.first { $0.contains { $0.lon < 0 } })
        XCTAssertEqual(east.map(\.lon).max() ?? 0, 180, accuracy: 1e-9)
        XCTAssertEqual(west.map(\.lon).min() ?? 0, -180, accuracy: 1e-9)
    }

    /// Area is conserved: the two pieces together cover what the whole ring did.
    func testTheDividedPiecesCoverTheSameGroundAsTheWhole() {
        let ring = [
            Coordinate(lon: 170, lat: 10), Coordinate(lon: 190, lat: 10),
            Coordinate(lon: 190, lat: 20), Coordinate(lon: 170, lat: 20),
        ]
        func area(_ ring: [Coordinate]) -> Double {
            guard ring.count >= 3 else { return 0 }
            var sum = 0.0
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                sum += a.lon * b.lat - b.lon * a.lat
            }
            return abs(sum) / 2
        }
        let total = Orbits.splitAtAntimeridian(ring).reduce(0.0) { $0 + area($1) }
        XCTAssertEqual(total, area(ring), accuracy: 1e-6)
    }

    /// The western overhang is the case a naive `+360` shift misses.
    func testARingRunningPastMinusOneEightyAlsoDivides() {
        let ring = [
            Coordinate(lon: -170, lat: 10), Coordinate(lon: -190, lat: 10),
            Coordinate(lon: -190, lat: 20), Coordinate(lon: -170, lat: 20),
        ]
        let pieces = Orbits.splitAtAntimeridian(ring)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue(pieces.contains { $0.contains { $0.lon > 170 } }, "no piece on the eastern edge")
    }
}
