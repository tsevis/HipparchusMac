import Foundation
import HipparchusGeometry

/// Smoothing one layer's geometry, with repair.
///
/// Ported from `smoothing.smooth_layer_geometries`. The Chaikin pass itself is
/// pure arithmetic and lives in `HipparchusGeometry`; this is the part that needs
/// GEOS, because corner-cutting a nearly-degenerate ring can produce a
/// self-intersecting polygon. Those get one `buffer(0)` repair, and are dropped
/// rather than drawn if that fails.
///
/// Dropping is the right answer over keeping the unsmoothed original: a layer where
/// most shapes are eased and a few are not reads as a mistake, and an invalid
/// polygon can crash a downstream overlay.
public struct SmoothingResult: Sendable {
    public let geometries: [Geometry]
    public let smoothed: Int
    /// Geometry Chaikin made unusable, and repair could not save.
    public let invalid: Int

    public init(geometries: [Geometry], smoothed: Int, invalid: Int) {
        self.geometries = geometries
        self.smoothed = smoothed
        self.invalid = invalid
    }
}

extension GEOSContext {
    public func smoothLayer(
        _ layerName: String,
        geometries: [Geometry],
        iterations: Int
    ) throws -> SmoothingResult {
        let rule = smoothingRule(for: layerName, baseIterations: iterations)
        guard rule.isEnabled else {
            return SmoothingResult(geometries: geometries, smoothed: 0, invalid: 0)
        }

        var out: [Geometry] = []
        var smoothedCount = 0
        var invalidCount = 0

        for geometry in geometries {
            var next = HipparchusGeometry.smoothed(
                geometry, iterations: rule.iterations, smoothPolygons: rule.smoothPolygons
            )
            if next.isEmpty {
                invalidCount += 1
                continue
            }
            if try !isValid(next) {
                let repaired = try self.repaired(next)
                if try repaired.isEmpty || !isValid(repaired) {
                    invalidCount += 1
                    continue
                }
                next = repaired
            }
            if next != geometry { smoothedCount += 1 }
            out.append(next)
        }

        return SmoothingResult(geometries: out, smoothed: smoothedCount, invalid: invalidCount)
    }
}
