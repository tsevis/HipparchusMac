import CGEOS
import Foundation
import HipparchusGeometry

/// The derived artistic layers: structure invented from the map rather than
/// fetched with it.
///
/// Ported from `geometry/voronoi.py`, `triangulation.py`, `hex_grid.py` and
/// `circle_packing.py`.
///
/// **Voronoi and Delaunay come from GEOS, not SciPy.** The kickoff settled this:
/// `GEOSVoronoiDiagram` and `GEOSDelaunayTriangulation` replace the SciPy usage,
/// and with them go two hundred lines of the Python — a hand-rolled reconstruction
/// of finite Voronoi polygons from Qhull's infinite ridges, a fallback for when
/// SciPy will not import against the local NumPy ABI, and a second fallback that
/// draws squares around each site and calls them cells. GEOS returns clipped
/// polygons directly.
///
/// Everything here is **synthetic**: it is a pattern derived from the data, not a
/// measurement of anything. The features carry that provenance, because a hex grid
/// that reads as survey data is exactly what provenance exists to prevent.
public struct CirclePackingOptions: Sendable, Equatable {
    public var minRadius: Double
    public var maxRadius: Double
    public var radiusStep: Double
    public var sampleStep: Double
    public var maxCircles: Int
    /// How far a new circle must stay from one already placed.
    public var clearance: Double

    public init(
        minRadius: Double = 4,
        maxRadius: Double = 24,
        radiusStep: Double = 2,
        sampleStep: Double = 6,
        maxCircles: Int = 250,
        clearance: Double = 1.5
    ) {
        self.minRadius = minRadius
        self.maxRadius = maxRadius
        self.radiusStep = radiusStep
        self.sampleStep = sampleStep
        self.maxCircles = maxCircles
        self.clearance = clearance
    }
}

extension GEOSContext {

    // MARK: - Voronoi

    /// Voronoi cells for a set of sites, clipped to a boundary.
    ///
    /// Fewer than two sites has no diagram: one site's cell is the whole plane.
    public func voronoiCells(sites: [Coordinate], boundary: Geometry) throws -> [Polygon] {
        let usable = Self.deduplicated(sites)
        guard usable.count >= 2, !boundary.isEmpty else { return [] }

        let managed = try make(.multiPoint(usable))
        let diagram: Geometry = try managed.withPointer { pointer in
            // A tolerance of 0 means no snapping. The GEOS documentation calls the
            // parameter finicky and recommends 0 when it misbehaves, so it starts
            // there rather than arriving there after a bug report.
            guard let result = GEOSVoronoiDiagram_r(handle, pointer, nil, 0.0, 0) else {
                throw takeError("voronoiDiagram")
            }
            return try ManagedGeometry(taking: result, in: self).withPointer { try read($0) }
        }

        return try clipToBoundary(diagram.polygons, boundary: boundary)
    }

    /// Cells seeded from the middle of each shape — the Python seeds from building
    /// centroids, and a centroid is what "where is this building" means.
    public func voronoiCells(around shapes: [Geometry], boundary: Geometry) throws -> [Polygon] {
        var sites: [Coordinate] = []
        for shape in shapes where !shape.isEmpty {
            if let centre = try centroid(shape) { sites.append(centre) }
        }
        return try voronoiCells(sites: sites, boundary: boundary)
    }

    // MARK: - Delaunay

    /// Delaunay triangles over a set of sites, clipped to a boundary.
    ///
    /// Three sites is the fewest that make a triangle.
    public func delaunayTriangles(sites: [Coordinate], boundary: Geometry?) throws -> [Polygon] {
        let usable = Self.deduplicated(sites)
        guard usable.count >= 3 else { return [] }

        let managed = try make(.multiPoint(usable))
        let mesh: Geometry = try managed.withPointer { pointer in
            // onlyEdges = 0 asks for triangular polygons rather than a mesh of lines.
            guard let result = GEOSDelaunayTriangulation_r(handle, pointer, 0.0, 0) else {
                throw takeError("delaunayTriangulation")
            }
            return try ManagedGeometry(taking: result, in: self).withPointer { try read($0) }
        }

        guard let boundary, !boundary.isEmpty else { return mesh.polygons }
        return try clipToBoundary(mesh.polygons, boundary: boundary)
    }

    /// Where roads cross, which is what the Python seeds its triangulation with.
    ///
    /// Every pair of lines whose bounding boxes overlap is intersected, and the
    /// point results are kept. The pairs come from a grid index rather than from a
    /// double loop: a city frame holds tens of thousands of road segments, and
    /// comparing each with every other is quadratic.
    public func roadIntersections(_ roads: [Geometry], limit: Int = 3000) throws -> [Coordinate] {
        let lines = roads.flatMap(\.lineStrings).filter { $0.coordinates.count >= 2 }
        guard lines.count >= 2 else { return [] }

        let boxes = lines.map { $0.bounds ?? Bounds(minX: 0, minY: 0, maxX: 0, maxY: 0) }
        let pairs = SpatialGrid(bounds: boxes).overlappingPairs(boxes)

        var points: [Coordinate] = []
        var seen = Set<Coordinate>()
        for (first, second) in pairs {
            guard points.count < limit else { break }
            let meeting = try intersection(.lineString(lines[first]), .lineString(lines[second]))
            for point in Self.points(of: meeting) where seen.insert(Self.rounded(point)).inserted {
                points.append(point)
                if points.count >= limit { break }
            }
        }
        return points
    }

    // MARK: - Hex grid

    public func hexGrid(boundary: Geometry, options: HexGridOptions) throws -> [Polygon] {
        guard options.radius > 0, let bounds = boundary.bounds, !boundary.isEmpty else { return [] }

        let hexagons = HexGrid.hexagons(covering: bounds, radius: options.radius)
        guard options.clipToBoundary else {
            // Whole hexagons wherever one touches: a grid laid over the map.
            return try hexagons.filter { try intersects(.polygon($0), boundary) }
        }
        return try clipToBoundary(hexagons, boundary: boundary)
    }

    // MARK: - Circle packing

    /// Greedy circle packing: walk a lattice of candidate centres, and at each one
    /// grow a circle until it leaves the boundary or comes too close to a circle
    /// already placed.
    ///
    /// Greedy, so it is deterministic and depends on the order the lattice is
    /// walked — the same boundary always packs the same way, which is what makes a
    /// map redraw identically.
    public func packedCircles(in boundary: Geometry, options: CirclePackingOptions) throws -> [Polygon] {
        guard options.minRadius > 0, options.maxRadius >= options.minRadius,
              options.sampleStep > 0, options.radiusStep > 0,
              let bounds = boundary.bounds, !boundary.isEmpty
        else {
            return []
        }

        // The lattice is quadratic in the area and the step is fixed by the smallest
        // circle, so a step chosen for a village walks tens of millions of positions
        // over a city — most of which fail, because the loop only stops early when
        // it has *placed* enough. A 5 km frame at an 8 m step took seven seconds;
        // thirty kilometres would have taken four minutes. So the lattice is
        // bounded, and the step widens to fit rather than the wait growing.
        let step = Self.sampleStep(for: bounds, requested: options.sampleStep)

        var circles: [Polygon] = []
        var placed: [(centre: Coordinate, radius: Double)] = []

        var y = bounds.minY
        while y <= bounds.maxY, circles.count < options.maxCircles {
            var x = bounds.minX
            while x <= bounds.maxX, circles.count < options.maxCircles {
                let centre = Coordinate(x: x, y: y)
                if let radius = try largestFit(at: centre, boundary: boundary, placed: placed, options: options) {
                    let circle = try buffer(.point(centre), distance: radius, quadrantSegments: 32)
                    if let polygon = circle.polygons.first {
                        circles.append(polygon)
                        placed.append((centre, radius))
                    }
                }
                x += step
            }
            y += step
        }
        return circles
    }

    /// The requested step, widened if the lattice it implies is too large to walk.
    ///
    /// The cap is on *candidate positions*, not on circles: testing a position costs
    /// a point-in-polygon and, when it lands inside, a run of buffers and
    /// containment tests. Forty thousand of those is well under a second.
    static func sampleStep(for bounds: Bounds, requested: Double, maximumPositions: Double = 40_000) -> Double {
        guard requested > 0, bounds.width > 0, bounds.height > 0 else { return requested }
        let positions = (bounds.width / requested) * (bounds.height / requested)
        guard positions > maximumPositions else { return requested }
        return requested * (positions / maximumPositions).squareRoot()
    }

    private func largestFit(
        at centre: Coordinate,
        boundary: Geometry,
        placed: [(centre: Coordinate, radius: Double)],
        options: CirclePackingOptions
    ) throws -> Double? {
        guard try contains(boundary, .point(centre)) else { return nil }

        // How large a circle could be before it crowds one already placed. Between
        // two circles the gap is the centre distance less both radii, so this is
        // exact arithmetic — and it replaces a GEOS `distance` call per placed
        // circle per radius step, which is what made packing a city frame take
        // minutes rather than a second.
        var crowdingLimit = Double.infinity
        for existing in placed {
            let dx = centre.x - existing.centre.x
            let dy = centre.y - existing.centre.y
            let gap = (dx * dx + dy * dy).squareRoot() - existing.radius - options.clearance
            crowdingLimit = Swift.min(crowdingLimit, gap)
            if crowdingLimit < options.minRadius { return nil }
        }

        var best: Double?
        var radius = options.minRadius
        while radius <= options.maxRadius + 1e-9 {
            guard radius <= crowdingLimit else { break }
            // Only the boundary needs the engine: it is an arbitrary polygon.
            let circle = try buffer(.point(centre), distance: radius, quadrantSegments: 24)
            guard try contains(boundary, circle) else { break }

            best = radius
            radius += options.radiusStep
        }
        return best
    }

    // MARK: -

    /// Clip derived shapes to the boundary, keeping only what still has area.
    ///
    /// Both sides are repaired first, and a shape whose overlay fails anyway is
    /// dropped rather than thrown. Derived geometry is *generated*: a Voronoi cell
    /// can come back as a sliver whose edges lie along the boundary to within a
    /// rounding error, and GEOS answers that with a side-location conflict. Losing
    /// one cell of a diagram is a blemish; losing the whole layer to it is a bug.
    private func clipToBoundary(_ shapes: [Polygon], boundary: Geometry) throws -> [Polygon] {
        let region = repairedIfNeeded(boundary)

        var kept: [Polygon] = []
        for shape in shapes {
            guard let clipped = try? intersection(repairedIfNeeded(.polygon(shape)), region),
                  !clipped.isEmpty
            else {
                continue
            }
            // An overlay can return a collection; only the areas are cells.
            kept.append(contentsOf: clipped.polygons)
        }
        return kept
    }

    /// Repair only what needs it — `buffer(0)` on a valid polygon is wasted work on
    /// every shape in a grid.
    private func repairedIfNeeded(_ geometry: Geometry) -> Geometry {
        guard (try? isValid(geometry)) == false else { return geometry }
        return (try? repaired(geometry)) ?? geometry
    }

    /// Repeated sites make GEOS refuse the diagram, so they go first.
    static func deduplicated(_ coordinates: [Coordinate]) -> [Coordinate] {
        var seen = Set<Coordinate>()
        return coordinates.filter { $0.isFinite && seen.insert(rounded($0)).inserted }
    }

    /// Rounded for the identity test only; the coordinate kept is the original.
    static func rounded(_ coordinate: Coordinate) -> Coordinate {
        Coordinate(
            x: (coordinate.x * 1e8).rounded() / 1e8,
            y: (coordinate.y * 1e8).rounded() / 1e8
        )
    }

    static func points(of geometry: Geometry) -> [Coordinate] {
        switch geometry {
        case .point(let point): [point]
        case .multiPoint(let points): points
        // Two roads meeting along a shared stretch intersect in a line, not a
        // point. Its ends are still junctions.
        case .lineString(let line): [line.coordinates.first, line.coordinates.last].compactMap { $0 }
        case .multiLineString(let lines): lines.flatMap { [$0.coordinates.first, $0.coordinates.last] }
            .compactMap { $0 }
        default: []
        }
    }
}
