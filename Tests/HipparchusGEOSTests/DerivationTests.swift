import XCTest
import HipparchusGeometry
@testable import HipparchusGEOS

/// The derived artistic layers: structure invented from the map rather than
/// fetched with it.
final class DerivationTests: XCTestCase {

    private let geos = GEOSContext()

    private func square(_ minimum: Double, _ maximum: Double) -> Geometry {
        .polygon(HipparchusGeometry.Polygon(exterior: [
            Coordinate(x: minimum, y: minimum), Coordinate(x: maximum, y: minimum),
            Coordinate(x: maximum, y: maximum), Coordinate(x: minimum, y: maximum),
        ]))
    }

    private func totalArea(_ polygons: [HipparchusGeometry.Polygon]) throws -> Double {
        try polygons.reduce(0) { try $0 + geos.area(.polygon($1)) }
    }

    // MARK: - Voronoi

    /// The defining property: every cell holds exactly one site, and the cells
    /// tile the boundary without overlapping.
    func testVoronoiCellsTileTheBoundaryOnePerSite() throws {
        let sites = [
            Coordinate(x: 25, y: 25), Coordinate(x: 75, y: 25),
            Coordinate(x: 25, y: 75), Coordinate(x: 75, y: 75),
        ]
        let boundary = square(0, 100)
        let cells = try geos.voronoiCells(sites: sites, boundary: boundary)

        XCTAssertEqual(cells.count, 4)
        // Tiling: the cells together are the boundary, to rounding.
        XCTAssertEqual(try totalArea(cells), 10_000, accuracy: 1e-6)

        for site in sites {
            let holding = try cells.filter { try geos.contains(.polygon($0), .point(site)) }
            XCTAssertEqual(holding.count, 1, "site \(site) is in \(holding.count) cells")
        }
    }

    func testVoronoiCellsAreClippedToTheBoundary() throws {
        let boundary = square(0, 100)
        let cells = try geos.voronoiCells(
            sites: [Coordinate(x: 40, y: 50), Coordinate(x: 60, y: 50)], boundary: boundary
        )
        for cell in cells {
            XCTAssertTrue(try geos.covers(boundary, .polygon(cell)), "a cell escaped the boundary")
        }
    }

    /// One site's cell is the whole plane, which is not a diagram.
    func testFewerThanTwoSitesIsNoDiagram() throws {
        XCTAssertTrue(try geos.voronoiCells(sites: [], boundary: square(0, 10)).isEmpty)
        XCTAssertTrue(
            try geos.voronoiCells(sites: [Coordinate(x: 1, y: 1)], boundary: square(0, 10)).isEmpty
        )
    }

    /// Repeated sites make GEOS refuse the diagram outright.
    func testRepeatedSitesDoNotSinkTheDiagram() throws {
        let cells = try geos.voronoiCells(
            sites: [
                Coordinate(x: 25, y: 25), Coordinate(x: 25, y: 25),
                Coordinate(x: 75, y: 75),
            ],
            boundary: square(0, 100)
        )
        XCTAssertEqual(cells.count, 2, "the duplicate should have been dropped, not fatal")
    }

    /// The Python seeds from building centroids, and a centroid is what "where is
    /// this building" means.
    func testCellsCanBeSeededFromShapes() throws {
        let buildings = [square(10, 20), square(60, 70), square(80, 90)]
        let cells = try geos.voronoiCells(around: buildings, boundary: square(0, 100))
        XCTAssertEqual(cells.count, 3)
        XCTAssertEqual(try totalArea(cells), 10_000, accuracy: 1e-6)
    }

    // MARK: - Delaunay

    func testDelaunayCoversTheHullOfItsSites() throws {
        let sites = [
            Coordinate(x: 0, y: 0), Coordinate(x: 100, y: 0),
            Coordinate(x: 100, y: 100), Coordinate(x: 0, y: 100),
        ]
        let triangles = try geos.delaunayTriangles(sites: sites, boundary: nil)

        // A square of four points triangulates into two triangles covering it.
        XCTAssertEqual(triangles.count, 2)
        XCTAssertEqual(try totalArea(triangles), 10_000, accuracy: 1e-6)
        for triangle in triangles {
            XCTAssertEqual(triangle.exterior.coordinates.count, 4, "a triangle is three corners, closed")
        }
    }

    func testThreeSitesIsTheFewestThatMakeATriangle() throws {
        XCTAssertTrue(try geos.delaunayTriangles(
            sites: [Coordinate(x: 0, y: 0), Coordinate(x: 1, y: 1)], boundary: nil
        ).isEmpty)
        XCTAssertEqual(try geos.delaunayTriangles(
            sites: [Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0), Coordinate(x: 0, y: 10)],
            boundary: nil
        ).count, 1)
    }

    func testDelaunayIsClippedWhenABoundaryIsGiven() throws {
        let sites = [
            Coordinate(x: -50, y: -50), Coordinate(x: 150, y: -50), Coordinate(x: 50, y: 150),
        ]
        let boundary = square(0, 100)
        let clipped = try geos.delaunayTriangles(sites: sites, boundary: boundary)
        for triangle in clipped {
            XCTAssertTrue(try geos.covers(boundary, .polygon(triangle)))
        }
        XCTAssertGreaterThan(try totalArea(clipped), 0)
    }

    /// Where roads cross is what the Python seeds its triangulation with.
    func testRoadIntersectionsAreFoundAndDeduplicated() throws {
        let roads: [Geometry] = [
            .lineString(LineString([Coordinate(x: 0, y: 50), Coordinate(x: 100, y: 50)])),
            .lineString(LineString([Coordinate(x: 50, y: 0), Coordinate(x: 50, y: 100)])),
            .lineString(LineString([Coordinate(x: 25, y: 0), Coordinate(x: 25, y: 100)])),
            // Parallel, so it crosses nothing.
            .lineString(LineString([Coordinate(x: 0, y: 90), Coordinate(x: 100, y: 90)])),
        ]
        let crossings = try geos.roadIntersections(roads)

        // The horizontal road crosses both verticals; the second horizontal too.
        XCTAssertEqual(crossings.count, 4)
        XCTAssertTrue(crossings.contains { abs($0.x - 50) < 1e-9 && abs($0.y - 50) < 1e-9 })
        XCTAssertEqual(Set(crossings.map(GEOSContext.rounded)).count, crossings.count, "duplicates")
    }

    func testRoadsThatNeverMeetSeedNothing() throws {
        let roads: [Geometry] = [
            .lineString(LineString([Coordinate(x: 0, y: 0), Coordinate(x: 10, y: 0)])),
            .lineString(LineString([Coordinate(x: 0, y: 50), Coordinate(x: 10, y: 50)])),
        ]
        XCTAssertTrue(try geos.roadIntersections(roads).isEmpty)
    }

    func testTheSeedCountIsCapped() throws {
        // A dense lattice: 40 x 40 lines is 1 600 crossings.
        var roads: [Geometry] = []
        for step in 0..<40 {
            let position = Double(step) * 10
            roads.append(.lineString(LineString([
                Coordinate(x: 0, y: position), Coordinate(x: 400, y: position),
            ])))
            roads.append(.lineString(LineString([
                Coordinate(x: position, y: 0), Coordinate(x: position, y: 400),
            ])))
        }
        XCTAssertEqual(try geos.roadIntersections(roads, limit: 100).count, 100)
    }

    // MARK: - Hex grid

    func testHexagonsInterlockAndCoverTheBoundary() throws {
        let boundary = square(0, 200)
        let cells = try geos.hexGrid(boundary: boundary, options: HexGridOptions(radius: 20))

        XCTAssertGreaterThan(cells.count, 20)
        // Clipped to the boundary, the pieces tile it exactly.
        XCTAssertEqual(try totalArea(cells), 40_000, accuracy: 1.0)
        for cell in cells {
            XCTAssertTrue(try geos.covers(boundary, .polygon(cell)))
        }
    }

    /// Pointy-top: a vertex straight up is what makes rows interlock.
    func testAHexagonIsPointyTopped() {
        let hexagon = HexGrid.hexagon(centre: Coordinate(x: 0, y: 0), radius: 10)
        let corners = hexagon.exterior.coordinates.dropLast()

        XCTAssertEqual(corners.count, 6)
        XCTAssertTrue(
            corners.contains { abs($0.x) < 1e-9 && abs($0.y - 10) < 1e-9 },
            "no vertex at the top, so this is flat-topped"
        )
        // Width across the flats is sqrt(3) x radius; height across points is 2r.
        let bounds = Bounds(Array(corners))
        XCTAssertEqual(bounds?.height ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(bounds?.width ?? 0, 3.0.squareRoot() * 10, accuracy: 1e-9)
    }

    func testUnclippedHexagonsStayWholeAndOverhangTheEdge() throws {
        let boundary = square(0, 100)
        let cells = try geos.hexGrid(
            boundary: boundary, options: HexGridOptions(radius: 20, clipToBoundary: false)
        )
        XCTAssertFalse(cells.isEmpty)
        var overhangs = false
        for cell in cells where try !geos.covers(boundary, .polygon(cell)) {
            overhangs = true
        }
        XCTAssertTrue(overhangs, "with clipping off, some hexagon must hang over the edge")
    }

    /// A radius small enough to make millions of shapes is a mistake, not a request.
    func testAnAbsurdlySmallRadiusIsRefusedRatherThanAttempted() {
        XCTAssertTrue(HexGrid.hexagons(covering: Bounds(minX: 0, minY: 0, maxX: 1e6, maxY: 1e6), radius: 0.5).isEmpty)
        XCTAssertTrue(HexGrid.hexagons(covering: Bounds(minX: 0, minY: 0, maxX: 10, maxY: 10), radius: 0).isEmpty)
    }

    // MARK: - Circle packing

    func testCirclesFitInsideTheBoundaryAndDoNotTouch() throws {
        let boundary = square(0, 100)
        let options = CirclePackingOptions(
            minRadius: 4, maxRadius: 12, radiusStep: 2, sampleStep: 10, maxCircles: 40, clearance: 1.5
        )
        let circles = try geos.packedCircles(in: boundary, options: options)

        XCTAssertGreaterThan(circles.count, 3)
        for circle in circles {
            XCTAssertTrue(try geos.covers(boundary, .polygon(circle)), "a circle escaped the boundary")
        }
        for outer in 0..<(circles.count - 1) {
            for inner in (outer + 1)..<circles.count {
                let gap = try geos.distance(.polygon(circles[outer]), .polygon(circles[inner]))
                XCTAssertGreaterThanOrEqual(gap, options.clearance - 1e-6, "circles \(outer) and \(inner) overlap")
            }
        }
    }

    func testPackingStopsAtTheCircleLimit() throws {
        let circles = try geos.packedCircles(
            in: square(0, 200),
            options: CirclePackingOptions(
                minRadius: 2, maxRadius: 6, radiusStep: 2, sampleStep: 8, maxCircles: 5, clearance: 1
            )
        )
        XCTAssertEqual(circles.count, 5)
    }

    /// Greedy and lattice-ordered, so the same boundary always packs the same way —
    /// which is what makes a map redraw identically.
    func testPackingIsDeterministic() throws {
        let options = CirclePackingOptions(
            minRadius: 4, maxRadius: 10, radiusStep: 2, sampleStep: 12, maxCircles: 20, clearance: 1
        )
        let first = try geos.packedCircles(in: square(0, 100), options: options)
        let second = try geos.packedCircles(in: square(0, 100), options: options)
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(
            first.compactMap { $0.bounds?.center.x },
            second.compactMap { $0.bounds?.center.x }
        )
    }

    func testNonsenseOptionsProduceNothingRatherThanSpinning() throws {
        let boundary = square(0, 100)
        XCTAssertTrue(try geos.packedCircles(
            in: boundary, options: CirclePackingOptions(minRadius: 20, maxRadius: 5)
        ).isEmpty)
        XCTAssertTrue(try geos.packedCircles(
            in: boundary, options: CirclePackingOptions(minRadius: 0, maxRadius: 5)
        ).isEmpty)
        XCTAssertTrue(try geos.packedCircles(
            in: boundary, options: CirclePackingOptions(sampleStep: 0)
        ).isEmpty)
    }

    // MARK: - An empty boundary derives nothing

    func testAnEmptyBoundaryDerivesNothing() throws {
        let empty = Geometry.empty
        XCTAssertTrue(try geos.voronoiCells(sites: [Coordinate(x: 1, y: 1), Coordinate(x: 2, y: 2)], boundary: empty).isEmpty)
        XCTAssertTrue(try geos.hexGrid(boundary: empty, options: HexGridOptions(radius: 10)).isEmpty)
        XCTAssertTrue(try geos.packedCircles(in: empty, options: CirclePackingOptions()).isEmpty)
    }
}

/// Circle packing walks a lattice, and the lattice is quadratic in the area while
/// its step is fixed by the smallest circle. Bounding it is what keeps a city frame
/// from taking minutes.
final class CirclePackingCostTests: XCTestCase {

    func testTheStepIsLeftAloneWhenTheLatticeIsSmall() {
        let bounds = Bounds(minX: 0, minY: 0, maxX: 100, maxY: 100)
        XCTAssertEqual(GEOSContext.sampleStep(for: bounds, requested: 10), 10, accuracy: 1e-9)
    }

    func testTheStepWidensRatherThanTheWaitGrowing() {
        // 30 km at an 8 m step is fourteen million positions.
        let bounds = Bounds(minX: 0, minY: 0, maxX: 30_000, maxY: 30_000)
        let step = GEOSContext.sampleStep(for: bounds, requested: 8)

        XCTAssertGreaterThan(step, 8)
        let positions = (bounds.width / step) * (bounds.height / step)
        XCTAssertLessThanOrEqual(positions, 40_000 * 1.01)
    }

    /// A frame four times as wide has sixteen times the area, so the step doubles
    /// and the number of positions walked stays put.
    func testTheBoundHoldsAsTheFrameGrows() {
        for side in [5_000.0, 20_000.0, 80_000.0] {
            let bounds = Bounds(minX: 0, minY: 0, maxX: side, maxY: side)
            let step = GEOSContext.sampleStep(for: bounds, requested: 8)
            let positions = (bounds.width / step) * (bounds.height / step)
            XCTAssertLessThanOrEqual(positions, 40_000 * 1.01, "\(side) m frame")
        }
    }

    func testPackingALargeFrameIsQuick() throws {
        let geos = GEOSContext()
        let boundary = Geometry.polygon(HipparchusGeometry.Polygon(exterior: [
            Coordinate(x: 0, y: 0), Coordinate(x: 30_000, y: 0),
            Coordinate(x: 30_000, y: 30_000), Coordinate(x: 0, y: 30_000),
        ]))

        let started = ContinuousClock.now
        let circles = try geos.packedCircles(
            in: boundary,
            options: CirclePackingOptions(minRadius: 8, maxRadius: 30, sampleStep: 8, maxCircles: 350)
        )
        let elapsed = ContinuousClock.now - started

        XCTAssertFalse(circles.isEmpty)
        XCTAssertLessThan(elapsed, .seconds(10), "the lattice is not bounded")
    }
}
