import Foundation

/// Relief shading: how brightly each patch of ground faces the sun.
///
/// **No Python counterpart.** `terrain_hillshade` is named in the Python's layer
/// inventory, its scene builder and its draw order, but nothing there ever
/// produces one — the layer exists so a hillshade polygonised in QGIS can be
/// dropped in as a file. This computes one from the elevation grid the terrain
/// provider already fetches, which is a deliberate divergence in the port's
/// favour, like ranking `night_lights` in the draw order.
///
/// The method is Horn's, the one GDAL and ESRI both use: fit a plane to each
/// 3×3 neighbourhood, take its normal, and light it. Written here as the dot
/// product it actually is rather than as the slope/aspect/zenith trigonometry
/// the textbooks state, because the two are the same number and one of them can
/// be read.
///
/// What comes out is a *field*, not geometry. Turning it into something
/// drawable is the caller's problem — the terrain provider bands it into filled
/// polygons the same way it bands elevation, so relief arrives as editable
/// vector shapes rather than as a raster this application has nowhere to put.

public let defaultSunAzimuth = 315.0
public let defaultSunAltitude = 45.0

/// Where the light comes from.
///
/// North-west at 45° is the cartographic convention, and it is a convention for
/// a reason: lit from the south-east, most readers see the valleys as ridges and
/// the ridges as valleys. The inversion is a property of the reader, not of the
/// data, so the default matters more than it looks like it should.
public struct SunPosition: Sendable, Equatable {
    /// Compass-style: degrees clockwise from north, matching
    /// `IlluminationProfile.azimuthDegrees` so the two light sources can be kept
    /// in step.
    public let azimuthDegrees: Double
    /// Degrees above the horizon. 90 is directly overhead, which flattens
    /// everything to one tone; 0 grazes and exaggerates every bump.
    public let altitudeDegrees: Double

    public init(
        azimuthDegrees: Double = defaultSunAzimuth,
        altitudeDegrees: Double = defaultSunAltitude
    ) {
        self.azimuthDegrees = azimuthDegrees
        self.altitudeDegrees = altitudeDegrees
    }

    /// Unit vector pointing from the ground towards the sun, in a right-handed
    /// frame with x east, y north and z up.
    var lightVector: (x: Double, y: Double, z: Double) {
        let azimuth = azimuthDegrees * .pi / 180.0
        let altitude = altitudeDegrees * .pi / 180.0
        let horizontal = cos(altitude)
        return (sin(azimuth) * horizontal, cos(azimuth) * horizontal, sin(altitude))
    }
}

/// Shade every cell of an elevation grid, in 0...1.
///
/// `cellSizeMetres` is what makes the result mean anything: a gradient in metres
/// per pixel is not a gradient until you say how wide a pixel is. Pass the
/// ground resolution of the grid — `WebMercator.groundResolution` for a grid
/// sampled from tiles — or the slope silently scales with zoom and the same
/// mountain shades differently at different sizes.
///
/// Grid convention matches `Field2D` everywhere else here: row 0 is north, and
/// column 0 is west.
///
/// - Returns: a field the same shape as `field`, holding 0 (full shadow) to 1
///   (facing the sun square on), and NaN wherever the source had no elevation.
public func hillshade(
    _ field: Field2D,
    sun: SunPosition = SunPosition(),
    cellSizeMetres: Double,
    exaggeration: Double = 1.0
) -> Field2D {
    guard field.rows > 0, field.columns > 0 else { return field }
    // A zero or negative cell size would divide the gradient into infinity and
    // shade the whole sheet one flat tone. Refuse it rather than produce that.
    guard cellSizeMetres > 0, cellSizeMetres.isFinite else {
        return Field2D(rows: field.rows, columns: field.columns, repeating: .nan)
    }

    let light = sun.lightVector
    let scale = max(0.0, exaggeration) / (8.0 * cellSizeMetres)

    var out = ContiguousArray<Double>(repeating: .nan, count: field.count)
    for row in 0..<field.rows {
        for column in 0..<field.columns {
            let centre = field[row, column]
            // A hole stays a hole. Shading it would invent ground.
            guard centre.isFinite else { continue }

            // Edges read their clamped neighbour, and a NaN neighbour reads the
            // centre — so a missing tile flattens its own rim rather than
            // producing a cliff at the edge of the data and a hard bright line
            // where no slope exists.
            func sample(_ rowOffset: Int, _ columnOffset: Int) -> Double {
                let value = field.clamped(row: row + rowOffset, column: column + columnOffset)
                return value.isFinite ? value : centre
            }

            let northWest = sample(-1, -1), north = sample(-1, 0), northEast = sample(-1, 1)
            let west = sample(0, -1), east = sample(0, 1)
            let southWest = sample(1, -1), south = sample(1, 0), southEast = sample(1, 1)

            // Horn's weighted differences: the middle of each edge counts double,
            // which is what makes this steadier on noisy ground than a plain
            // two-cell difference.
            let eastward = ((northEast + 2 * east + southEast) - (northWest + 2 * west + southWest)) * scale
            let northward = ((northWest + 2 * north + northEast) - (southWest + 2 * south + southEast)) * scale

            // The surface normal of z = f(x, y) is (-∂z/∂x, -∂z/∂y, 1),
            // normalised. Lambert says the brightness is its dot product with the
            // light, and clamping the negative half is what puts a face turned
            // away from the sun into shadow rather than into negative light.
            let length = (eastward * eastward + northward * northward + 1.0).squareRoot()
            let lit = (-eastward * light.x - northward * light.y + light.z) / length
            out[row * field.columns + column] = Swift.min(Swift.max(lit, 0.0), 1.0)
        }
    }
    return Field2D(rows: field.rows, columns: field.columns, values: out)
}
