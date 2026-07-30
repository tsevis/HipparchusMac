import Foundation

/// A uniform grid over bounding boxes, for finding which things might touch.
///
/// Stands in for the Python's `STRtree`, and for the same job: road intersections
/// are found by testing pairs of lines, and a city has tens of thousands of them.
/// Testing every pair against every other is quadratic — ten thousand roads is fifty
/// million tests — where bucketing by cell reduces it to pairs that share one.
///
/// A uniform grid rather than an R-tree because the inputs here are road segments
/// spread fairly evenly over a frame, which is the case a uniform grid is good at,
/// and because it is thirty lines that can be read in one sitting.
public struct SpatialGrid: Sendable {
    private let cellSize: Double
    private let origin: Coordinate
    private var cells: [Cell: [Int]] = [:]

    private struct Cell: Hashable {
        let column: Int
        let row: Int
    }

    /// - Parameter targetPerCell: how many boxes to aim for in a cell. Too few and
    ///   the dictionary dominates; too many and the pair tests come back.
    public init(bounds: [Bounds], targetPerCell: Double = 4) {
        let usable = bounds.filter { $0.width.isFinite && $0.height.isFinite }
        guard let first = usable.first else {
            self.cellSize = 1
            self.origin = Coordinate(x: 0, y: 0)
            return
        }

        let extent = usable.dropFirst().reduce(first) { $0.union($1) }
        self.origin = Coordinate(x: extent.minX, y: extent.minY)

        // Size cells so an average one holds about `targetPerCell` boxes.
        let area = Swift.max(extent.width * extent.height, .leastNormalMagnitude)
        let perCell = Swift.max(area * targetPerCell / Double(Swift.max(usable.count, 1)), 0)
        self.cellSize = Swift.max(perCell.squareRoot(), .leastNormalMagnitude)

        for (index, box) in bounds.enumerated() where box.width.isFinite && box.height.isFinite {
            for cell in self.cellsCovering(box) {
                cells[cell, default: []].append(index)
            }
        }
    }

    private func cellsCovering(_ box: Bounds) -> [Cell] {
        let minColumn = Int(((box.minX - origin.x) / cellSize).rounded(.down))
        let maxColumn = Int(((box.maxX - origin.x) / cellSize).rounded(.down))
        let minRow = Int(((box.minY - origin.y) / cellSize).rounded(.down))
        let maxRow = Int(((box.maxY - origin.y) / cellSize).rounded(.down))

        // A single box spanning the whole extent would otherwise enumerate every
        // cell; cap it, because such a box is a candidate for everything anyway.
        guard (maxColumn - minColumn + 1) * (maxRow - minRow + 1) <= 4096 else {
            return [Cell(column: minColumn, row: minRow)]
        }

        var result: [Cell] = []
        for column in minColumn...maxColumn {
            for row in minRow...maxRow {
                result.append(Cell(column: column, row: row))
            }
        }
        return result
    }

    /// Every pair of indices whose boxes share a cell **and** actually overlap,
    /// each pair reported once with the lower index first.
    public func overlappingPairs(_ bounds: [Bounds]) -> [(Int, Int)] {
        var seen = Set<Int>()
        var pairs: [(Int, Int)] = []

        for indices in cells.values where indices.count > 1 {
            for outer in 0..<(indices.count - 1) {
                for inner in (outer + 1)..<indices.count {
                    let first = Swift.min(indices[outer], indices[inner])
                    let second = Swift.max(indices[outer], indices[inner])
                    // A pair can share more than one cell; count it once.
                    let key = first &* 1_000_003 &+ second
                    guard seen.insert(key).inserted else { continue }
                    guard bounds[first].intersects(bounds[second]) else { continue }
                    pairs.append((first, second))
                }
            }
        }
        return pairs
    }
}
