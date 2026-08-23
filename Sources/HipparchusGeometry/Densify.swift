import Foundation

/// Add vertices along a straight run so a curved projection can bend it.
///
/// A projection is applied vertex by vertex, and everything between two vertices
/// is drawn as a straight line. That is exact for `webMercator` and
/// `localAzimuthal`, where a segment straight in degrees is straight on the
/// sheet as well. It is not exact for `equalEarth`, where a meridian is a curve:
/// a run given only its two ends comes out as the chord across that curve.
///
/// The failure this was written for is visible rather than theoretical. The
/// hillshade lays down a quadrilateral covering the whole grid — four vertices,
/// one per corner — and on the first world sheet in Equal Earth it drew as a
/// hard-edged rectangle sitting over the middle of the ocean, because those four
/// corners were joined by straight lines while everything with real detail in it
/// bent correctly around them. Natural Earth would do the same to any border
/// that follows a parallel: the United States' northern boundary is a handful of
/// vertices along 49°N, and a chord between them cuts visibly into Canada.
public enum Densify {

    /// A degree is about four pixels on a world sheet at working size, and the
    /// sagitta of a one-degree chord is far smaller than that. Anything finer
    /// costs vertices to no visible end — and the simplifier downstream removes
    /// whatever this adds that the projection did not actually bend.
    public static let defaultStepDegrees = 1.0

    /// Guards a run of nonsense — a non-finite coordinate would otherwise ask
    /// for an unbounded number of steps.
    static let maxStepsPerSegment = 1024

    public static func coordinates(_ input: [Coordinate], stepDegrees: Double) -> [Coordinate] {
        guard input.count >= 2, stepDegrees > 0 else { return input }
        var result: [Coordinate] = [input[0]]
        result.reserveCapacity(input.count)
        for index in 1..<input.count {
            let start = input[index - 1]
            let end = input[index]
            let span = Swift.max(abs(end.x - start.x), abs(end.y - start.y))
            let steps = span.isFinite
                ? Swift.min(Int((span / stepDegrees).rounded(.up)), maxStepsPerSegment)
                : 1
            if steps > 1 {
                for step in 1..<steps {
                    let fraction = Double(step) / Double(steps)
                    result.append(Coordinate(
                        x: start.x + (end.x - start.x) * fraction,
                        y: start.y + (end.y - start.y) * fraction
                    ))
                }
            }
            result.append(end)
        }
        return result
    }
}

extension Geometry {

    /// The same shape with no segment longer than `stepDegrees`.
    ///
    /// Points are returned untouched: there is nothing between a point and
    /// itself to bend.
    public func densified(stepDegrees: Double = Densify.defaultStepDegrees) -> Geometry {
        func line(_ value: LineString) -> LineString {
            LineString(Densify.coordinates(value.coordinates, stepDegrees: stepDegrees))
        }
        func ring(_ value: Ring) -> Ring {
            Ring(Densify.coordinates(value.coordinates, stepDegrees: stepDegrees))
        }
        func polygon(_ value: Polygon) -> Polygon {
            Polygon(exterior: ring(value.exterior), holes: value.holes.map(ring))
        }

        switch self {
        case .empty, .point, .multiPoint:
            return self
        case .lineString(let value):
            return .lineString(line(value))
        case .multiLineString(let values):
            return .multiLineString(values.map(line))
        case .polygon(let value):
            return .polygon(polygon(value))
        case .multiPolygon(let values):
            return .multiPolygon(values.map(polygon))
        case .collection(let parts):
            return .collection(parts.map { $0.densified(stepDegrees: stepDegrees) })
        }
    }
}
