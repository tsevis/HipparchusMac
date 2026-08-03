import Foundation

/// A flow field, drawn the way a printed chart has always drawn one.
///
/// **The signature visual of every modern marine application is animated GPU
/// particle advection, and this application cannot have it — and should not want
/// it.** Particles are a raster technique on a screen; the product here is a
/// sheet, and a moving dot has nowhere to go in an SVG or on paper. What a
/// printed current chart does instead is draw *streamlines*: curves everywhere
/// tangent to the flow, spaced evenly enough to read as a field.
///
/// So the field is integrated rather than animated. Seed a lattice, follow the
/// velocity forward and backward from each seed with RK4, stop on the edge of
/// the data, on still water, or on approach to a line already drawn — the last
/// of those being what keeps the spacing even, and is Jobard and Lefer's
/// contribution to this problem.
///
/// **The direction is normalised before stepping.** A streamline's *shape* is
/// the direction field, not its magnitude: stepping by the velocity itself makes
/// a fast current take enormous strides and a slow one crawl, and the drawing
/// then says more about the integrator than about the sea. Speed is carried
/// along each vertex instead, for whatever the caller wants to do with it.

/// One vertex of a streamline, in the grid's own index space.
public struct StreamlinePoint: Sendable, Equatable {
    /// Fractional grid indices, row 0 north, matching `Field2D` everywhere else.
    public let row: Double
    public let column: Double
    /// The speed of the flow here, in the units the field arrived in.
    public let speed: Double

    public init(row: Double, column: Double, speed: Double) {
        self.row = row
        self.column = column
        self.speed = speed
    }
}

public struct StreamlineSettings: Sendable {
    /// How close two lines may come, in cells. The one number that decides
    /// whether this reads as a field or as a tangle.
    public var separation: Double = 1.6
    /// Integration step, in cells. Smaller is smoother and slower; past about a
    /// third of a cell the curve stops changing because the field does not have
    /// that much detail in it.
    public var stepSize: Double = 0.3
    /// Bounds a spiral that never returns to its own start: 600 steps at the
    /// default is 180 cells of arc, far longer than any real feature and short
    /// enough that a runaway is a curve rather than a scribble.
    public var maxSteps = 600
    /// Lines shorter than this are noise rather than flow.
    public var minLengthCells: Double = 4
    /// Still water has no direction, and integrating one produces a curl that
    /// is entirely the interpolator's invention.
    public var minSpeed: Double = 0.01
    /// Seed lattice spacing, in cells.
    public var seedSpacing: Double = 1.6

    public init() {}
}

/// Streamlines through a velocity field.
///
/// - Parameters:
///   - u: eastward velocity, one sample per cell. NaN means no data.
///   - v: northward velocity, the same shape as `u`.
///   - cellLonDegrees: the grid's east-west spacing.
///   - cellLatDegrees: the grid's north-south spacing.
///   - latitudeForRow: the latitude of a fractional row, for the convergence of
///     the meridians. A degree of longitude is shorter than a degree of latitude
///     everywhere but the equator, so a field integrated without it leans — the
///     same correction the earthquake circles and the sea mark symbols need, in
///     a third place.
public func streamlines(
    u: Field2D,
    v: Field2D,
    cellLonDegrees: Double,
    cellLatDegrees: Double,
    latitudeForRow: (Double) -> Double,
    settings: StreamlineSettings = StreamlineSettings()
) -> [[StreamlinePoint]] {
    guard u.rows > 1, u.columns > 1, u.rows == v.rows, u.columns == v.columns else { return [] }
    guard cellLonDegrees > 0, cellLatDegrees > 0 else { return [] }

    let separation = Swift.max(0.2, settings.separation)
    let step = Swift.max(0.02, settings.stepSize)

    // Points already drawn, bucketed at the separation distance so "is anything
    // near here" is a lookup over nine buckets rather than a scan of everything
    // drawn so far.
    let occupancyRows = Swift.max(1, Int(Double(u.rows) / separation) + 1)
    let occupancyColumns = Swift.max(1, Int(Double(u.columns) / separation) + 1)
    var buckets = [[(row: Double, column: Double)]](
        repeating: [], count: occupancyRows * occupancyColumns
    )

    func bucketIndex(row: Double, column: Double) -> Int? {
        let r = Int(row / separation), c = Int(column / separation)
        guard r >= 0, r < occupancyRows, c >= 0, c < occupancyColumns else { return nil }
        return r * occupancyColumns + c
    }

    /// Whether anything already drawn is nearer than `separation`.
    ///
    /// **The distance is measured, not inferred from the bucket.** Treating a
    /// non-empty neighbouring bucket as "too close" rejects everything within
    /// three separations rather than one, and the drawing comes out as a dozen
    /// stray curves across a whole sea instead of a field. The buckets are an
    /// index; the test is still a distance.
    func tooClose(row: Double, column: Double) -> Bool {
        let r = Int(row / separation), c = Int(column / separation)
        let limit = separation * separation
        for dr in -1...1 {
            for dc in -1...1 {
                let rr = r + dr, cc = c + dc
                guard rr >= 0, rr < occupancyRows, cc >= 0, cc < occupancyColumns else { continue }
                for point in buckets[rr * occupancyColumns + cc] {
                    let dRow = point.row - row, dColumn = point.column - column
                    if dRow * dRow + dColumn * dColumn < limit { return true }
                }
            }
        }
        return false
    }

    /// The flow at a fractional position, bilinearly, in index space.
    ///
    /// Returns `nil` where any corner is missing, which is what makes a
    /// streamline stop at a coast rather than wander onto the land and
    /// interpolate a current out of nothing.
    func flow(row: Double, column: Double) -> (dRow: Double, dColumn: Double, speed: Double)? {
        guard row >= 0, column >= 0,
              row <= Double(u.rows - 1), column <= Double(u.columns - 1) else { return nil }
        let r0 = Int(row), c0 = Int(column)
        let r1 = Swift.min(r0 + 1, u.rows - 1), c1 = Swift.min(c0 + 1, u.columns - 1)
        let fr = row - Double(r0), fc = column - Double(c0)

        func sample(_ field: Field2D) -> Double? {
            let a = field[r0, c0], b = field[r0, c1]
            let c = field[r1, c0], d = field[r1, c1]
            guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return nil }
            return (a * (1 - fc) + b * fc) * (1 - fr) + (c * (1 - fc) + d * fc) * fr
        }
        guard let east = sample(u), let north = sample(v) else { return nil }

        let speed = (east * east + north * north).squareRoot()
        guard speed >= settings.minSpeed else { return nil }

        // Metres per cell differs by axis and by latitude, so the two components
        // are scaled into cells before the direction means anything.
        let cosLat = Swift.max(0.05, cos(latitudeForRow(row) * .pi / 180))
        let dColumn = east / (cellLonDegrees * cosLat)
        // Row 0 is north, so northward velocity walks *up* the grid.
        let dRow = -north / cellLatDegrees

        let length = (dRow * dRow + dColumn * dColumn).squareRoot()
        guard length > 0, length.isFinite else { return nil }
        // Normalised: the shape is the direction field, and the magnitude rides
        // along as `speed` rather than as a step length.
        return (dRow / length, dColumn / length, speed)
    }

    /// How much of its own tail a line ignores before the approach test applies
    /// to it.
    ///
    /// Half a circle of radius `separation`, in steps. Shorter than that and a
    /// legitimately curving streamline meets its own tail and stops — an eddy is
    /// *supposed* to come back near itself, and cutting it there loses the
    /// feature the drawing exists to show. Set to three cells of travel first,
    /// this threw away four fifths of the field.
    let selfLag = Swift.max(8, Int(Double.pi * separation / step))

    /// One half of a streamline, from a seed outward.
    func trace(fromRow: Double, fromColumn: Double, forward: Bool) -> [StreamlinePoint] {
        var points: [StreamlinePoint] = []
        var row = fromRow, column = fromColumn
        let sign = forward ? 1.0 : -1.0

        /// Whether the line has come back to where it started.
        ///
        /// The separation test only sees lines already *finished*, so without
        /// something here a streamline entering a convergence coils onto itself
        /// indefinitely — one over the north Aegean wound into a spiral of
        /// dozens of turns, which is the integrator drawing its own behaviour
        /// rather than the sea's.
        ///
        /// **The test is against the start, not against the whole tail.** Any
        /// earlier point is the wrong question: an eddy is *supposed* to come
        /// back near itself, and rejecting that threw away four fifths of the
        /// field — the very features the drawing exists to show. A closed loop
        /// returns to its origin, and that is the thing worth stopping on.
        func hasClosedTheLoop(row: Double, column: Double) -> Bool {
            guard points.count > selfLag else { return false }
            let dRow = fromRow - row, dColumn = fromColumn - column
            return dRow * dRow + dColumn * dColumn < (separation * 0.5) * (separation * 0.5)
        }

        for taken in 0..<settings.maxSteps {
            guard let k1 = flow(row: row, column: column) else { break }
            // Classic RK4 over the normalised direction field.
            guard let k2 = flow(
                row: row + sign * k1.dRow * step / 2,
                column: column + sign * k1.dColumn * step / 2
            ) else { break }
            guard let k3 = flow(
                row: row + sign * k2.dRow * step / 2,
                column: column + sign * k2.dColumn * step / 2
            ) else { break }
            guard let k4 = flow(
                row: row + sign * k3.dRow * step,
                column: column + sign * k3.dColumn * step
            ) else { break }

            let dRow = (k1.dRow + 2 * k2.dRow + 2 * k3.dRow + k4.dRow) / 6
            let dColumn = (k1.dColumn + 2 * k2.dColumn + 2 * k3.dColumn + k4.dColumn) / 6
            row += sign * dRow * step
            column += sign * dColumn * step

            guard row >= 0, column >= 0,
                  row <= Double(u.rows - 1), column <= Double(u.columns - 1) else { break }
            // Give the line a few steps to clear its own seed before the
            // separation test can stop it.
            if taken > 2, tooClose(row: row, column: column) { break }
            if hasClosedTheLoop(row: row, column: column) { break }

            points.append(StreamlinePoint(row: row, column: column, speed: k1.speed))
        }
        return points
    }

    var lines: [[StreamlinePoint]] = []
    let spacing = Swift.max(0.2, settings.seedSpacing)
    var seedRow = 0.0
    while seedRow <= Double(u.rows - 1) {
        var seedColumn = 0.0
        while seedColumn <= Double(u.columns - 1) {
            defer { seedColumn += spacing }
            guard !tooClose(row: seedRow, column: seedColumn) else { continue }
            guard let here = flow(row: seedRow, column: seedColumn) else { continue }

            let backward = trace(fromRow: seedRow, fromColumn: seedColumn, forward: false)
            let forward = trace(fromRow: seedRow, fromColumn: seedColumn, forward: true)
            let seed = StreamlinePoint(row: seedRow, column: seedColumn, speed: here.speed)
            let line = backward.reversed() + [seed] + forward

            guard length(of: line) >= settings.minLengthCells else { continue }
            for point in line {
                if let index = bucketIndex(row: point.row, column: point.column) {
                    buckets[index].append((row: point.row, column: point.column))
                }
            }
            lines.append(line)
        }
        seedRow += spacing
    }
    return lines
}

/// Total length of a streamline in cells, which is what `minLengthCells` is
/// measured against.
public func length(of line: [StreamlinePoint]) -> Double {
    guard line.count > 1 else { return 0 }
    var total = 0.0
    for (a, b) in zip(line, line.dropFirst()) {
        let dr = b.row - a.row, dc = b.column - a.column
        total += (dr * dr + dc * dc).squareRoot()
    }
    return total
}
