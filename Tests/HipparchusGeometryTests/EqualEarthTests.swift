import XCTest
@testable import HipparchusGeometry

/// The projection a world map needs, and the rule that reaches for it.
///
/// Two separate claims are checked here, and they fail for different reasons.
/// The first is arithmetic: Equal Earth is a published projection with published
/// numbers, and either this is it or it is something else. The second is
/// judgement: which frames are too big for a flat approximation to be honest
/// about. Only the second is arguable, and it is the one written down in
/// `ProjectionMode.honest(for:)`.
final class EqualEarthTests: XCTestCase {

    // MARK: - The projection itself

    func testTheOriginStaysAtTheOrigin() {
        let profile = ProjectionProfile(mode: .equalEarth)
        let projected = profile.project(Coordinate(lon: 0, lat: 0))
        XCTAssertEqual(projected.x, 0, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 0, accuracy: 1e-9)
    }

    func testItRoundTripsAcrossTheWholeWorld() {
        let profile = ProjectionProfile(mode: .equalEarth)
        for lat in stride(from: -89.0, through: 89.0, by: 7.0) {
            for lon in stride(from: -179.0, through: 179.0, by: 13.0) {
                let point = Coordinate(lon: lon, lat: lat)
                let back = profile.unproject(profile.project(point))
                XCTAssertEqual(back.lon, lon, accuracy: 1e-6, "longitude at \(lon), \(lat)")
                XCTAssertEqual(back.lat, lat, accuracy: 1e-6, "latitude at \(lon), \(lat)")
            }
        }
    }

    /// The pole is a line, not a singularity — which is the whole point of
    /// reaching for this rather than letting Mercator clamp at 85°.
    func testThePolesProjectToFiniteFinitePoints() {
        let profile = ProjectionProfile(mode: .equalEarth)
        let north = profile.project(Coordinate(lon: 0, lat: 90))
        let south = profile.project(Coordinate(lon: 0, lat: -90))
        XCTAssertTrue(north.y.isFinite)
        XCTAssertTrue(south.y.isFinite)
        XCTAssertEqual(north.y, -south.y, accuracy: 1e-6)
        XCTAssertGreaterThan(north.y, 0)
        // Web Mercator cannot answer this at all: it clamps at 85.05°, which is
        // why the world render was losing the Arctic and stretching Antarctica.
        let mercator = ProjectionProfile(mode: .webMercator)
        XCTAssertEqual(
            mercator.project(Coordinate(lon: 0, lat: 90)).y,
            mercator.project(Coordinate(lon: 0, lat: WebMercator.maxLatitude)).y,
            accuracy: 1e-6
        )
    }

    /// The defining property, and the reason to use it: a shape covers the same
    /// area on the sheet wherever on Earth it came from.
    ///
    /// Checked as a ratio against the true spherical area of the same cell, at
    /// latitudes an atlas actually has to hold together. Mercator fails this by a
    /// factor of four across the same span, which is the second assertion.
    func testEqualAreaHoldsFromTheEquatorToTheArctic() {
        let profile = ProjectionProfile(mode: .equalEarth)
        let mercator = ProjectionProfile(mode: .webMercator)

        func areaRatio(_ project: (Coordinate) -> Coordinate, atLatitude lat: Double) -> Double {
            let step = 1.0
            let corners = [
                Coordinate(lon: 0, lat: lat), Coordinate(lon: step, lat: lat),
                Coordinate(lon: step, lat: lat + step), Coordinate(lon: 0, lat: lat + step),
            ].map(project)
            var sheetArea = 0.0
            for index in corners.indices {
                let here = corners[index], next = corners[(index + 1) % corners.count]
                sheetArea += here.x * next.y - next.x * here.y
            }
            sheetArea = abs(sheetArea) / 2

            // The true area of a spherical cell: R² Δλ (sin φ₂ − sin φ₁).
            let radians = Double.pi / 180
            let trueArea = pow(WebMercator.earthRadiusMetres, 2) * (step * radians)
                * (sin((lat + step) * radians) - sin(lat * radians))
            return sheetArea / trueArea
        }

        let equator = areaRatio(profile.project, atLatitude: 0)
        for lat in [15.0, 30.0, 45.0, 60.0, 75.0] {
            let ratio = areaRatio(profile.project, atLatitude: lat)
            XCTAssertEqual(
                ratio / equator, 1.0, accuracy: 0.01,
                "a cell at \(lat)° must cover the area a cell at the equator does"
            )
        }

        let mercatorEquator = areaRatio(mercator.project, atLatitude: 0)
        XCTAssertGreaterThan(
            areaRatio(mercator.project, atLatitude: 60) / mercatorEquator, 3.5,
            "Mercator is the comparison, and it is not close"
        )
    }

    func testItIsNamedInTheMetadataAndReadBackFromIt() {
        XCTAssertEqual(ProjectionMode(name: "equal_earth"), .equalEarth)
        XCTAssertEqual(ProjectionMode.equalEarth.rawValue, "equal_earth")
        let profile = ProjectionProfile(mode: .equalEarth)
        XCTAssertEqual(profile.renderCRS, "EQUAL_EARTH")
        XCTAssertEqual(profile.metadata(bbox: nil)["render_crs"], "EQUAL_EARTH")
        XCTAssertEqual(profile.sourceCRS, "EPSG:4326")
    }

    /// The central meridian is the frame's own, so a Pacific-centred map is not
    /// split down the middle.
    func testTheFrameChoosesTheCentralMeridian() {
        let profile = ProjectionProfile(
            bbox: BoundingBox(minLon: 100, minLat: -40, maxLon: 200, maxLat: 40),
            mode: .equalEarth
        )
        let centre = profile.project(Coordinate(lon: 150, lat: 0))
        XCTAssertEqual(centre.x, 0, accuracy: 1e-6)
        XCTAssertLessThan(profile.project(Coordinate(lon: 120, lat: 0)).x, 0)
        XCTAssertGreaterThan(profile.project(Coordinate(lon: 180, lat: 0)).x, 0)
    }

    // MARK: - When to reach for it

    /// A city, an island and a small country are what the local projection was
    /// written for, and it stays.
    func testASmallFrameKeepsTheProjectionItAskedFor() {
        let santorini = BoundingBox(minLon: 25.32, minLat: 36.33, maxLon: 25.50, maxLat: 36.48)
        let greece = BoundingBox(minLon: 19.4, minLat: 34.8, maxLon: 28.3, maxLat: 41.8)
        let france = BoundingBox(minLon: -5, minLat: 42, maxLon: 8, maxLat: 51)
        for frame in [santorini, greece, france] {
            XCTAssertEqual(ProjectionMode.localAzimuthal.honest(for: frame), .localAzimuthal)
            XCTAssertEqual(ProjectionMode.webMercator.honest(for: frame), .webMercator)
        }
    }

    /// A continent, a hemisphere and the planet are not, and neither Mercator nor
    /// a cosine-scaled equirectangular can be asked to carry them.
    func testAContinentalFrameIsUpgraded() {
        let europe = BoundingBox(minLon: -25, minLat: 34, maxLon: 45, maxLat: 72)
        let unitedStates = BoundingBox(minLon: -125, minLat: 25, maxLon: -66, maxLat: 49)
        let world = BoundingBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90)
        for frame in [europe, unitedStates, world] {
            XCTAssertEqual(ProjectionMode.localAzimuthal.honest(for: frame), .equalEarth)
            XCTAssertEqual(ProjectionMode.webMercator.honest(for: frame), .equalEarth)
        }
    }

    /// The same span at the equator is a different proposition: an
    /// equirectangular frame there is barely distorted at all, so the rule reads
    /// the latitudes rather than counting degrees of span.
    func testTheRuleReadsLatitudeRatherThanCountingDegrees() {
        let equatorial = BoundingBox(minLon: 0, minLat: -9, maxLon: 20, maxLat: 9)
        let arctic = BoundingBox(minLon: 0, minLat: 63, maxLon: 20, maxLat: 81)
        XCTAssertEqual(ProjectionMode.localAzimuthal.honest(for: equatorial), .localAzimuthal)
        XCTAssertEqual(ProjectionMode.localAzimuthal.honest(for: arctic), .equalEarth,
                       "the same 18° of span, where the meridians are converging")
    }

    /// Asking for degrees is asking for degrees. The rule improves a projection
    /// nobody chose deliberately; it does not overrule one that was.
    func testAnExplicitChoiceIsLeftAlone() {
        let world = BoundingBox(minLon: -180, minLat: -90, maxLon: 180, maxLat: 90)
        XCTAssertEqual(ProjectionMode.wgs84Raw.honest(for: world), .wgs84Raw)
        XCTAssertEqual(ProjectionMode.equalEarth.honest(for: world), .equalEarth)
    }

    func testAMissingFrameChangesNothing() {
        XCTAssertEqual(ProjectionMode.localAzimuthal.honest(for: nil), .localAzimuthal)
    }
}

/// The bounds a curved projection needs, which are not the bounds its corners
/// give.
final class EqualEarthBoundsTests: XCTestCase {

    /// The failure this was written for: a world sheet came out cropped down
    /// the sides, because the frame's widest point is on the equator and the
    /// corners are at the poles, where the meridians have converged.
    func testWorldBoundsReachTheEquatorNotTheCorners() {
        let profile = ProjectionProfile(mode: .equalEarth)
        let world = BoundingBox(minLon: -180, minLat: -89, maxLon: 180, maxLat: 89)
        let bounds = profile.project(world)

        let equator = profile.project(Coordinate(lon: 180, lat: 0)).x
        let corner = profile.project(Coordinate(lon: 180, lat: 89)).x
        // The pole line is about 0.59 of the equator in this projection, so the
        // corners understate the frame's width by two fifths.
        XCTAssertGreaterThan(equator, corner * 1.5, "the premise: the corner is far narrower")
        XCTAssertEqual(bounds.maxX, equator, accuracy: 1.0)
        XCTAssertEqual(bounds.minX, -equator, accuracy: 1.0)
    }

    /// Sampling the outline must not have changed the answer for the modes that
    /// were always axis-aligned.
    func testTheAxisAlignedModesAreUnaffected() {
        for mode in [ProjectionMode.webMercator, .localAzimuthal, .wgs84Raw] {
            let profile = ProjectionProfile(mode: mode)
            let bbox = BoundingBox(minLon: -10, minLat: -20, maxLon: 30, maxLat: 40)
            let bounds = profile.project(bbox)
            XCTAssertEqual(bounds.minX, profile.project(Coordinate(lon: -10, lat: -20)).x, accuracy: 1e-6)
            XCTAssertEqual(bounds.maxX, profile.project(Coordinate(lon: 30, lat: 40)).x, accuracy: 1e-6)
            XCTAssertEqual(bounds.minY, profile.project(Coordinate(lon: -10, lat: -20)).y, accuracy: 1e-6)
            XCTAssertEqual(bounds.maxY, profile.project(Coordinate(lon: 30, lat: 40)).y, accuracy: 1e-6)
        }
    }
}

/// Straight in degrees is not straight on every sheet.
final class DensifyTests: XCTestCase {

    func testAShortSegmentIsLeftAlone() {
        let line = [Coordinate(lon: 0, lat: 0), Coordinate(lon: 0.4, lat: 0.3)]
        XCTAssertEqual(Densify.coordinates(line, stepDegrees: 1), line)
    }

    func testALongSegmentGainsVerticesAndKeepsItsEnds() {
        let line = [Coordinate(lon: -125, lat: 49), Coordinate(lon: -66, lat: 49)]
        let dense = Densify.coordinates(line, stepDegrees: 1)
        XCTAssertEqual(dense.count, 60, "59° of parallel, one vertex per degree, plus the end")
        XCTAssertEqual(dense.first, line.first)
        XCTAssertEqual(dense.last, line.last)
        // Every added vertex sits on the original run, so the shape is unchanged
        // in the projections that were already exact.
        for point in dense { XCTAssertEqual(point.lat, 49, accuracy: 1e-9) }
    }

    func testANonFiniteRunDoesNotAskForInfiniteVertices() {
        let line = [Coordinate(x: 0, y: 0), Coordinate(x: .nan, y: 0)]
        XCTAssertEqual(Densify.coordinates(line, stepDegrees: 1).count, 2)
    }

    func testPolygonsAndHolesAreBothDensified() {
        let polygon = Polygon(
            exterior: [
                Coordinate(lon: -20, lat: -20), Coordinate(lon: 20, lat: -20),
                Coordinate(lon: 20, lat: 20), Coordinate(lon: -20, lat: 20),
                Coordinate(lon: -20, lat: -20),
            ],
            holes: [[
                Coordinate(lon: -5, lat: -5), Coordinate(lon: 5, lat: -5),
                Coordinate(lon: 5, lat: 5), Coordinate(lon: -5, lat: 5),
                Coordinate(lon: -5, lat: -5),
            ]]
        )
        guard case .polygon(let dense) = Geometry.polygon(polygon).densified(stepDegrees: 1) else {
            return XCTFail("a polygon must densify to a polygon")
        }
        XCTAssertEqual(dense.exterior.coordinates.count, 161)
        XCTAssertEqual(dense.holes.first?.coordinates.count, 41)
    }

    /// The reason any of this exists: the chord across a projected parallel.
    func testProjectingABorderNoLongerCutsAcrossIt() {
        let profile = ProjectionProfile(mode: .equalEarth)
        let border = Geometry.lineString(LineString([
            Coordinate(lon: -125, lat: 49), Coordinate(lon: -66, lat: 49),
        ]))
        guard case .lineString(let drawn) = profile.project(border) else {
            return XCTFail("projecting a line must give a line")
        }
        // The midpoint of what gets drawn, against where the midpoint belongs.
        let ends = [drawn.coordinates.first!, drawn.coordinates.last!]
        let chordMidY = (ends[0].y + ends[1].y) / 2
        let trueMid = profile.project(Coordinate(lon: -95.5, lat: 49))
        XCTAssertEqual(
            drawn.coordinates[drawn.coordinates.count / 2].y, trueMid.y, accuracy: 1.0,
            "the drawn line follows the parallel"
        )
        XCTAssertEqual(chordMidY, trueMid.y, accuracy: 1.0,
                       "a parallel is level in this projection, so the chord is level too")
        XCTAssertGreaterThan(drawn.coordinates.count, 50, "it was densified, not left as two ends")
    }

    func testTheAxisAlignedModesSkipTheWork() {
        let profile = ProjectionProfile(mode: .webMercator)
        let line = Geometry.lineString(LineString([
            Coordinate(lon: -125, lat: 49), Coordinate(lon: -66, lat: 49),
        ]))
        guard case .lineString(let drawn) = profile.project(line) else {
            return XCTFail("projecting a line must give a line")
        }
        XCTAssertEqual(drawn.coordinates.count, 2, "nothing to bend, nothing to add")
    }
}
