/// A rectangular grid of samples, indexed `[row, column]` with row 0 at the top.
///
/// This replaces the 2-D numpy array the Python carries through contouring. The
/// storage is one flat buffer because the whole point of the marching-squares
/// pass is a single fused walk over adjacent row pairs — the numpy version reads
/// four shifted slices and allocates a dozen intermediates to do the same work.
///
/// Values may be `NaN`. A missing terrain tile leaves a hole rather than failing
/// the fetch, so every reduction here has to be NaN-aware rather than assuming a
/// complete grid.
public struct Field2D: Sendable, Equatable {
    public let rows: Int
    public let columns: Int
    public let values: ContiguousArray<Double>

    public init(rows: Int, columns: Int, values: ContiguousArray<Double>) {
        precondition(values.count == rows * columns, "Field2D storage must be rows * columns")
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    public init(rows: Int, columns: Int, repeating value: Double = .nan) {
        self.init(rows: rows, columns: columns, values: ContiguousArray(repeating: value, count: max(0, rows * columns)))
    }

    /// Build from a function of `(row, column)`. Used throughout the tests, where
    /// the Python builds the same grids with `meshgrid`.
    public init(rows: Int, columns: Int, _ sample: (Int, Int) -> Double) {
        var values = ContiguousArray<Double>()
        values.reserveCapacity(max(0, rows * columns))
        for row in 0..<max(0, rows) {
            for column in 0..<max(0, columns) {
                values.append(sample(row, column))
            }
        }
        self.init(rows: rows, columns: columns, values: values)
    }

    public static let empty = Field2D(rows: 0, columns: 0, values: [])

    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }

    @inlinable
    public subscript(row: Int, column: Int) -> Double {
        get { values[row * columns + column] }
    }

    /// Nearest-sample read with the indices clamped to the grid, which is what
    /// the elevation sampler needs: a probe just outside the frame should read the
    /// edge rather than crash or return NaN.
    @inlinable
    public func clamped(row: Int, column: Int) -> Double {
        guard rows > 0, columns > 0 else { return .nan }
        let r = Swift.min(Swift.max(row, 0), rows - 1)
        let c = Swift.min(Swift.max(column, 0), columns - 1)
        return self[r, c]
    }

    /// The lowest and highest finite samples, or nil when the grid holds none.
    public var finiteRange: (minimum: Double, maximum: Double)? {
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var seen = false
        for value in values where value.isFinite {
            seen = true
            if value < minimum { minimum = value }
            if value > maximum { maximum = value }
        }
        return seen ? (minimum, maximum) : nil
    }

    public var hasFiniteValues: Bool { values.contains { $0.isFinite } }

    /// Every `step`-th row and column. Elevation bands are traced on a decimated
    /// copy: they are broad areas, and full resolution costs time to add detail no
    /// fill can show.
    public func decimated(step: Int) -> Field2D {
        guard step > 1 else { return self }
        let outRows = (rows + step - 1) / step
        let outColumns = (columns + step - 1) / step
        var out = ContiguousArray<Double>()
        out.reserveCapacity(outRows * outColumns)
        for row in stride(from: 0, to: rows, by: step) {
            for column in stride(from: 0, to: columns, by: step) {
                out.append(self[row, column])
            }
        }
        return Field2D(rows: outRows, columns: outColumns, values: out)
    }

    /// A copy with a `border`-wide frame of `value`, and every NaN inside also
    /// replaced by `value`.
    ///
    /// This is the trick that makes elevation bands work: with a sentinel below
    /// the field's own minimum around the outside, every contour at every level
    /// closes into a ring, and no open chain ever has to be stitched along the
    /// frame by hand.
    public func padded(border: Int, with value: Double) -> Field2D {
        guard border > 0 else {
            return Field2D(rows: rows, columns: columns, values: ContiguousArray(values.map { $0.isFinite ? $0 : value }))
        }
        let outRows = rows + 2 * border
        let outColumns = columns + 2 * border
        var out = ContiguousArray<Double>(repeating: value, count: outRows * outColumns)
        for row in 0..<rows {
            let destination = (row + border) * outColumns + border
            for column in 0..<columns {
                let sample = self[row, column]
                out[destination + column] = sample.isFinite ? sample : value
            }
        }
        return Field2D(rows: outRows, columns: outColumns, values: out)
    }

    /// One separable 3-tap mean, edges extended.
    ///
    /// Ported from `terrain_tiles._box_blur`: horizontal pass then vertical pass,
    /// each a plain average of three neighbours.
    public func boxBlurred() -> Field2D {
        guard rows > 0, columns > 0 else { return self }
        var horizontal = ContiguousArray<Double>(repeating: 0, count: rows * columns)
        for row in 0..<rows {
            let base = row * columns
            for column in 0..<columns {
                let left = values[base + Swift.max(column - 1, 0)]
                let middle = values[base + column]
                let right = values[base + Swift.min(column + 1, columns - 1)]
                horizontal[base + column] = (left + middle + right) / 3.0
            }
        }
        var out = ContiguousArray<Double>(repeating: 0, count: rows * columns)
        for row in 0..<rows {
            let above = Swift.max(row - 1, 0) * columns
            let here = row * columns
            let below = Swift.min(row + 1, rows - 1) * columns
            for column in 0..<columns {
                out[here + column] = (horizontal[above + column] + horizontal[here + column] + horizontal[below + column]) / 3.0
            }
        }
        return Field2D(rows: rows, columns: columns, values: out)
    }

    /// NaN-aware smoothing: blur the values and the validity mask together and
    /// divide, so a hole does not drag its neighbours towards zero. Holes stay
    /// holes.
    ///
    /// Real DEMs carry step noise from their source resolution, and one light
    /// pass settles it without moving the landforms.
    public func smoothed(passes: Int) -> Field2D {
        guard passes > 0, !isEmpty else { return self }

        var filled = Field2D(rows: rows, columns: columns, values: ContiguousArray(values.map { $0.isFinite ? $0 : 0.0 }))
        var weight = Field2D(rows: rows, columns: columns, values: ContiguousArray(values.map { $0.isFinite ? 1.0 : 0.0 }))
        for _ in 0..<passes {
            filled = filled.boxBlurred()
            weight = weight.boxBlurred()
        }

        var out = ContiguousArray<Double>(repeating: .nan, count: values.count)
        for index in values.indices where values[index].isFinite {
            let mass = weight.values[index]
            out[index] = mass > 0 ? filled.values[index] / mass : .nan
        }
        return Field2D(rows: rows, columns: columns, values: out)
    }
}
