import Foundation

/// Marching-squares contouring for scalar fields.
///
/// Ported from `src/hipparchus/geometry/contours.py`. Contours are traced in
/// fractional grid-index space and stitched into continuous polylines rather
/// than loose segments, because the output is destined for editable SVG paths
/// where a thousand two-point fragments would be unusable.
///
/// The Python is vectorised numpy over four shifted slices of the grid. Here it
/// is one fused walk: the same arithmetic without a dozen intermediate arrays.

public let defaultIndexEvery = 5
public let defaultMaxLevels = 400

/// A point in fractional grid-index space, `(row, column)`, row 0 at the top.
///
/// A distinct type from `Coordinate` on purpose. Contours are traced in
/// `(row, column)` and everything downstream works in `(x, y)`, so the swap has
/// to happen exactly once — making it a different type means the compiler
/// notices when it does not.
public struct GridPoint: Sendable, Hashable {
    public var row: Double
    public var column: Double

    public init(row: Double, column: Double) {
        self.row = row
        self.column = column
    }
}

/// Contour levels split into ordinary and index (accented) lines.
public struct ContourLevels: Sendable, Equatable {
    public let minor: [Double]
    public let index: [Double]
    public let interval: Double
    public let indexEvery: Int

    public init(minor: [Double], index: [Double], interval: Double, indexEvery: Int) {
        self.minor = minor
        self.index = index
        self.interval = interval
        self.indexEvery = indexEvery
    }

    public var allLevels: [Double] { (minor + index).sorted() }
    public var isEmpty: Bool { minor.isEmpty && index.isEmpty }
}

/// Levels on a fixed interval, as a paper contour map is drawn.
///
/// Equal subdivision of the observed range — the scheme the raster providers use
/// — makes every map's line spacing mean something different. A fixed interval is
/// what makes contour spacing readable as slope.
///
/// `indexEvery` of 0 or less accents nothing: a densely contoured sheet reads its
/// depth from line density, and a heavier line every fifth only interrupts that.
///
/// A non-positive interval cannot produce lines and yields none. The Python
/// raises here; the caller that computed the interval is the fault either way,
/// and `niceInterval` never returns one.
public func contourLevels(
    minimum: Double,
    maximum: Double,
    interval: Double,
    indexEvery: Int = defaultIndexEvery,
    maxLevels: Int = defaultMaxLevels
) -> ContourLevels {
    guard interval > 0 else {
        return ContourLevels(minor: [], index: [], interval: interval, indexEvery: indexEvery)
    }
    guard minimum.isFinite, maximum.isFinite, maximum > minimum else {
        return ContourLevels(minor: [], index: [], interval: interval, indexEvery: indexEvery)
    }

    let first = Int((minimum / interval).rounded(.down)) + 1
    var last = Int((maximum / interval).rounded(.up)) - 1
    guard last >= first else {
        return ContourLevels(minor: [], index: [], interval: interval, indexEvery: indexEvery)
    }

    // A tight interval over a wide range can ask for millions of lines; cap the
    // count rather than let a preview render stall.
    if (last - first + 1) > maxLevels {
        last = first + maxLevels - 1
    }

    var minor: [Double] = []
    var index: [Double] = []
    for step in first...last {
        let level = Double(step) * interval
        if level <= minimum || level >= maximum { continue }
        // Accenting counts interval steps, not emitted levels, so the accents
        // stay on the same absolute heights whatever range is in view.
        let isIndex = indexEvery > 0 && step % indexEvery == 0
        if isIndex {
            index.append(level)
        } else {
            minor.append(level)
        }
    }
    return ContourLevels(minor: minor, index: index, interval: interval, indexEvery: indexEvery)
}

// MARK: - Cell cases

/// Which cell edges the contour connects, by corner bitmask.
///
/// Corner bits: 1 = top-left, 2 = top-right, 4 = bottom-right, 8 = bottom-left,
/// set when that corner is above the level. `T`, `R`, `B`, `L` name the four cell
/// edges.
///
/// Order matters and is the Python's insertion order: segments are emitted case
/// by case, and reordering them would reorder the stitched output. The exported
/// SVG has to be reproducible.
private enum CellEdge: Int {
    case top, right, bottom, left
}

private let caseSegments: [(caseValue: UInt8, pairs: [(CellEdge, CellEdge)])] = [
    (1, [(.left, .top)]),
    (2, [(.top, .right)]),
    (3, [(.left, .right)]),
    (4, [(.right, .bottom)]),
    (6, [(.top, .bottom)]),
    (7, [(.left, .bottom)]),
    (8, [(.bottom, .left)]),
    (9, [(.top, .bottom)]),
    (11, [(.right, .bottom)]),
    (12, [(.left, .right)]),
    (13, [(.top, .right)]),
    (14, [(.left, .top)]),
]

// Ambiguous saddles, resolved by the cell centre. Both variants consume all four
// crossings, so stitching stays consistent whichever way a saddle is read.
private let saddleCentreAbove: [UInt8: [(CellEdge, CellEdge)]] = [
    5: [(.top, .right), (.bottom, .left)],
    10: [(.left, .top), (.right, .bottom)],
]
private let saddleCentreBelow: [UInt8: [(CellEdge, CellEdge)]] = [
    5: [(.left, .top), (.right, .bottom)],
    10: [(.top, .right), (.bottom, .left)],
]
/// Saddles are handled after the unambiguous cases, in this order, because
/// segment order decides stitched output order.
private let saddleCaseOrder: [UInt8] = [5, 10]

// MARK: - Tracing

/// Trace one iso-level of `field` as stitched polylines in index space.
///
/// Closed contours repeat their first point as the last; contours that leave the
/// grid are returned open. Non-finite samples are treated as below the level, so
/// a masked hole simply ends the lines that reach it.
public func contourPolylines(_ field: Field2D, level: Double) -> [[GridPoint]] {
    let height = field.rows
    let width = field.columns
    guard height >= 2, width >= 2 else { return [] }

    // Work on a level-relative field so a crossing is a sign change. Samples
    // sitting exactly on the level are nudged below it: an exact hit is a
    // tangency, not a crossing, and leaving it at zero would create segments
    // with no length.
    var relative = ContiguousArray<Double>(repeating: 0, count: height * width)
    var anyAbove = false
    var anyBelow = false
    var scale = 0.0
    for index in 0..<(height * width) {
        let value = field.values[index] - level
        let finite = value.isFinite ? value : -1.0
        relative[index] = finite
        let magnitude = Swift.abs(finite)
        if magnitude > scale { scale = magnitude }
    }
    let tiny = (scale.isFinite && scale != 0.0 ? scale : 1.0) * 1e-12
    for index in 0..<(height * width) {
        if relative[index] == 0.0 { relative[index] = -tiny }
        if relative[index] > 0 { anyAbove = true } else { anyBelow = true }
    }
    guard anyAbove, anyBelow else { return [] }

    let horizontalCount = height * (width - 1)
    let (pointRow, pointColumn) = edgeCrossingPoints(relative, rows: height, columns: width, horizontalCount: horizontalCount)

    // Corner bitmask per cell, one pass.
    let cellRows = height - 1
    let cellColumns = width - 1
    var cases = ContiguousArray<UInt8>(repeating: 0, count: cellRows * cellColumns)
    for row in 0..<cellRows {
        let top = row * width
        let bottom = (row + 1) * width
        let out = row * cellColumns
        for column in 0..<cellColumns {
            var mask: UInt8 = 0
            if relative[top + column] > 0 { mask |= 1 }
            if relative[top + column + 1] > 0 { mask |= 2 }
            if relative[bottom + column + 1] > 0 { mask |= 4 }
            if relative[bottom + column] > 0 { mask |= 8 }
            cases[out + column] = mask
        }
    }

    // Edge ids are global and computed once per edge, never once per incident
    // cell, so two neighbouring cells agree on a crossing bit-exactly.
    func edgeID(_ edge: CellEdge, row: Int, column: Int) -> Int {
        switch edge {
        case .top: return row * cellColumns + column
        case .bottom: return (row + 1) * cellColumns + column
        case .left: return horizontalCount + row * width + column
        case .right: return horizontalCount + row * width + column + 1
        }
    }

    var segmentStart: [Int] = []
    var segmentEnd: [Int] = []

    // Case by case, and within a case pair by pair, matching the Python's
    // masked-append order exactly.
    func collect(pairs: [(CellEdge, CellEdge)], where matches: (Int, Int) -> Bool) {
        for (first, second) in pairs {
            for row in 0..<cellRows {
                for column in 0..<cellColumns where matches(row, column) {
                    segmentStart.append(edgeID(first, row: row, column: column))
                    segmentEnd.append(edgeID(second, row: row, column: column))
                }
            }
        }
    }

    for entry in caseSegments {
        let value = entry.caseValue
        collect(pairs: entry.pairs) { row, column in cases[row * cellColumns + column] == value }
    }

    for value in saddleCaseOrder {
        guard let above = saddleCentreAbove[value], let below = saddleCentreBelow[value] else { continue }
        func centreIsAbove(_ row: Int, _ column: Int) -> Bool {
            let top = row * width + column
            let bottom = (row + 1) * width + column
            return relative[top] + relative[top + 1] + relative[bottom + 1] + relative[bottom] > 0
        }
        collect(pairs: above) { row, column in
            cases[row * cellColumns + column] == value && centreIsAbove(row, column)
        }
        collect(pairs: below) { row, column in
            cases[row * cellColumns + column] == value && !centreIsAbove(row, column)
        }
    }

    guard !segmentStart.isEmpty else { return [] }

    return stitchSegments(starts: segmentStart, ends: segmentEnd).map { chain in
        chain.map { GridPoint(row: pointRow[$0], column: pointColumn[$0]) }
    }
}

/// Interpolate the crossing point on every grid edge.
///
/// Every edge gets a slot whether or not it crosses; only the ids referenced by a
/// segment are ever read back, and computing the crossing once per edge is what
/// lets neighbouring cells agree exactly.
private func edgeCrossingPoints(
    _ relative: ContiguousArray<Double>,
    rows: Int,
    columns: Int,
    horizontalCount: Int
) -> (ContiguousArray<Double>, ContiguousArray<Double>) {
    let total = horizontalCount + (rows - 1) * columns
    var pointRow = ContiguousArray<Double>(repeating: 0, count: total)
    var pointColumn = ContiguousArray<Double>(repeating: 0, count: total)

    // Horizontal edges: between (row, column) and (row, column + 1).
    for row in 0..<rows {
        let base = row * columns
        let out = row * (columns - 1)
        for column in 0..<(columns - 1) {
            let left = relative[base + column]
            let right = relative[base + column + 1]
            let fraction = left != right ? left / (left - right) : 0.0
            pointRow[out + column] = Double(row)
            pointColumn[out + column] = Double(column) + fraction
        }
    }

    // Vertical edges: between (row, column) and (row + 1, column).
    for row in 0..<(rows - 1) {
        let top = row * columns
        let bottom = (row + 1) * columns
        let out = horizontalCount + row * columns
        for column in 0..<columns {
            let above = relative[top + column]
            let below = relative[bottom + column]
            let fraction = above != below ? above / (above - below) : 0.0
            pointRow[out + column] = Double(row) + fraction
            pointColumn[out + column] = Double(column)
        }
    }

    return (pointRow, pointColumn)
}

/// Join undirected edge-to-edge segments into chains of edge ids.
///
/// Segments are keyed by integer edge id rather than by coordinates, so joining
/// is exact: no rounding tolerance, and no risk of a hairline gap splitting one
/// contour into two paths.
///
/// The Python walks a dict and relies on Python's insertion-ordered dicts for a
/// deterministic result. Swift's `Dictionary` has no order at all, so the
/// insertion order is kept explicitly in `edgeOrder`. Without it the same field
/// would export different SVG on different runs.
private func stitchSegments(starts: [Int], ends: [Int]) -> [[Int]] {
    var incident: [Int: [Int]] = [:]
    var edgeOrder: [Int] = []
    incident.reserveCapacity(starts.count * 2)
    edgeOrder.reserveCapacity(starts.count * 2)

    for index in starts.indices {
        for edge in [starts[index], ends[index]] {
            if incident[edge] == nil {
                incident[edge] = [index]
                edgeOrder.append(edge)
            } else {
                incident[edge]!.append(index)
            }
        }
    }

    var used = [Bool](repeating: false, count: starts.count)
    var chains: [[Int]] = []

    func walk(from edge: Int) -> [Int] {
        var chain = [edge]
        var current = edge
        while true {
            var next: Int?
            for candidate in incident[current] ?? [] where !used[candidate] {
                next = candidate
                break
            }
            guard let segment = next else { return chain }
            used[segment] = true
            current = starts[segment] == current ? ends[segment] : starts[segment]
            chain.append(current)
        }
    }

    // Open contours first: starting anywhere else on them would split them in
    // two at the start point.
    for edge in edgeOrder {
        guard let segments = incident[edge], segments.count == 1, !used[segments[0]] else { continue }
        let chain = walk(from: edge)
        if chain.count > 1 { chains.append(chain) }
    }

    for index in used.indices where !used[index] {
        let chain = walk(from: starts[index])
        if chain.count > 1 { chains.append(chain) }
    }

    return chains
}

// MARK: - Winding and projection

/// Return the polyline wound so higher ground lies left of travel.
///
/// Winding order is the only place a contour can carry which side is uphill, and
/// it is the one property that survives the whole pipeline: clipping,
/// simplification and smoothing all preserve vertex order, while feature
/// properties do not. Downstream that is what lets illumination recover a slope
/// aspect from a bare line.
///
/// `sample` reads the field at a point in the same space as `coordinates`;
/// `probe` is how far to step sideways when asking which side is higher.
public func orientUphillLeft(
    _ coordinates: [Coordinate],
    sample: (Coordinate) -> Double,
    level: Double,
    probe: Double
) -> [Coordinate] {
    guard coordinates.count >= 2 else { return coordinates }

    let index = coordinates.count / 2
    let start = coordinates[index - 1]
    let end = coordinates[index]
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return coordinates }

    // Left normal in a y-up space; callers in a y-down space get the mirror,
    // which is why the convention is stated in the caller's own coordinates.
    let leftX = -dy / length * probe
    let leftY = dx / length * probe
    let midpoint = Coordinate(x: (start.x + end.x) / 2.0 + leftX, y: (start.y + end.y) / 2.0 + leftY)
    let value = sample(midpoint)
    if !value.isFinite || value >= level {
        return coordinates
    }
    return coordinates.reversed()
}

/// Map `(row, column)` index-space points onto `(lon, lat)`.
///
/// Row 0 is the north edge, matching how the grid is sampled.
///
/// This is the **equirectangular** mapper, correct for a field sampled evenly in
/// degrees. Terrain tiles are Web Mercator and must not use it — see
/// `WebMercator.lonLatForPixel`, which inverts the projection per vertex.
public func polylineToLonLat(
    _ polyline: [GridPoint],
    bounds: BoundingBox,
    rows: Int,
    columns: Int
) -> [Coordinate] {
    let columnSpan = columns > 1 ? bounds.lonSpan / Double(columns - 1) : 0.0
    let rowSpan = rows > 1 ? bounds.latSpan / Double(rows - 1) : 0.0
    return polyline.map { point in
        Coordinate(
            lon: bounds.minLon + point.column * columnSpan,
            lat: bounds.maxLat - point.row * rowSpan
        )
    }
}
