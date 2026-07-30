import Foundation

/// Illuminated contours: stroke weight that varies along a line to read as depth.
///
/// Ported from `src/hipparchus/geometry/illumination.py`.
///
/// A contour sheet drawn at one weight is flat. Tanaka's illuminated-contour
/// method fixes that by lighting the surface from one corner and weighting each
/// stretch of line by how the slope it traces faces that light: stretches on the
/// shadow side thicken, stretches facing the light thin out, and the sheet lifts
/// into relief without any fill, hachure or shading.
///
/// The slope aspect is recovered from **winding order alone**. Contours arrive
/// wound with higher ground on the left — see `orientUphillLeft` — so the left
/// normal of every segment points uphill. That matters because winding is the only
/// property that survives clipping, simplification and smoothing; a feature
/// property carrying the aspect would have been dropped long before here.
///
/// Lines are split into **runs** of equal weight rather than per segment, which
/// keeps the exported SVG down to a handful of editable paths per contour instead
/// of hundreds.

public let defaultIlluminationAzimuth = 315.0
public let defaultIlluminationBands = 5

/// How a light source turns slope aspect into stroke weight.
public struct IlluminationProfile: Sendable, Equatable {
    /// Compass-style: degrees clockwise from north, so 315 is the conventional
    /// north-west cartographic light.
    public let azimuthDegrees: Double
    public let bands: Int
    /// Stroke-width multipliers at the lit and shadowed extremes.
    public let litScale: Double
    public let shadowScale: Double

    public init(
        azimuthDegrees: Double = defaultIlluminationAzimuth,
        bands: Int = defaultIlluminationBands,
        litScale: Double = 0.4,
        shadowScale: Double = 1.9
    ) {
        self.azimuthDegrees = azimuthDegrees
        self.bands = bands
        self.litScale = litScale
        self.shadowScale = shadowScale
    }

    /// Map `lit` in [-1, 1] onto a quantised weight multiplier.
    ///
    /// Quantised on purpose: a continuously varying weight produces a different
    /// path for every segment, and the point of banding is that neighbouring
    /// segments share a weight and can be merged into one run.
    public func weight(for lit: Double) -> Double {
        let bands = Swift.max(1, self.bands)
        if bands == 1 {
            // One band is one weight: the layer keeps a single uniform stroke.
            return (litScale + shadowScale) / 2.0
        }
        let clamped = Swift.min(Swift.max(lit, -1.0), 1.0)
        var fraction = (1.0 - clamped) / 2.0
        fraction = (fraction * Double(bands - 1)).rounded() / Double(bands - 1)
        return litScale + (shadowScale - litScale) * fraction
    }

    /// Unit vector pointing from the ground towards the light.
    var lightVector: (x: Double, y: Double) {
        let radians = azimuthDegrees * .pi / 180.0
        return (sin(radians), cos(radians))
    }
}

/// One stretch of line at a single stroke weight.
///
/// A pair, not two parallel lists. The Python returns
/// `(list[geometry], list[float])` and relies on the caller keeping them aligned;
/// making a run carry both means they cannot be separated by accident, which is
/// the failure mode kickoff detail 6 describes.
public struct IlluminatedRun: Sendable, Equatable {
    public let line: LineString
    public let weight: Double

    public init(line: LineString, weight: Double) {
        self.line = line
        self.weight = weight
    }
}

/// Split linework into runs of equal weight.
///
/// Must run **after** every other geometry step. Clipping can split a line and
/// smoothing can drop one; producing the weights here, together with the geometry
/// they describe, is what stops the two drifting apart.
public func illuminate(_ geometries: [Geometry], profile: IlluminationProfile) -> [IlluminatedRun] {
    let light = profile.lightVector
    var runs: [IlluminatedRun] = []

    for geometry in geometries {
        // Polygons and points have no aspect to recover; they are skipped rather
        // than guessed at.
        for line in geometry.lineStrings {
            runs.append(contentsOf: splitByWeight(line.coordinates, profile: profile, light: light))
        }
    }
    return runs
}

/// Walk the segments, and cut a new run wherever the weight changes.
private func splitByWeight(
    _ coordinates: [Coordinate],
    profile: IlluminationProfile,
    light: (x: Double, y: Double)
) -> [IlluminatedRun] {
    guard coordinates.count >= 2 else { return [] }

    var runs: [IlluminatedRun] = []
    var runStart = 0
    var runWeight: Double?

    for index in 0..<(coordinates.count - 1) {
        let weight = segmentWeight(coordinates[index], coordinates[index + 1], profile: profile, light: light)
        guard let current = runWeight else {
            runWeight = weight
            continue
        }
        if weight != current {
            // The shared vertex belongs to both runs, or the line shows a gap where
            // the weight changes.
            runs.append(IlluminatedRun(line: LineString(Array(coordinates[runStart...index])), weight: current))
            runStart = index
            runWeight = weight
        }
    }

    if let current = runWeight, coordinates.count - runStart >= 2 {
        runs.append(IlluminatedRun(line: LineString(Array(coordinates[runStart...])), weight: current))
    }
    return runs
}

private func segmentWeight(
    _ start: Coordinate,
    _ end: Coordinate,
    profile: IlluminationProfile,
    light: (x: Double, y: Double)
) -> Double {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = (dx * dx + dy * dy).squareRoot()
    guard length > 0 else { return profile.weight(for: 0) }

    // Higher ground lies left of travel, so the RIGHT normal points down-slope.
    // A slope faces the way it falls, so that — not the up-slope — is the direction
    // to test against the light: a north-west flank is lit by a north-west sun even
    // though its climb runs south-east.
    let downhillX = dy / length
    let downhillY = -dx / length
    return profile.weight(for: downhillX * light.x + downhillY * light.y)
}
