import Foundation

/// A procedural terrain field: relief that is generated rather than measured.
///
/// Ported from `data_sources/simulated_field.py`.
///
/// Every other rich source reads data someone downloaded first. This one invents
/// it, so contour work is reachable on a bare install with no file, no account and
/// no network. The field is deterministic in the seed and **anchored to geography
/// rather than to the window**: panning shows more of the same landscape instead of
/// re-rolling a new one, which is what makes the result usable as a map rather than
/// as wallpaper.
///
/// The elevations are **invented**. Everything built from this is tagged
/// `synthetic`, so a generated map is never mistaken for measured ground.
public struct TerrainFieldSettings: Sendable, Equatable {
    public var seed: Int = 1729
    public var gridSize = 320
    /// Relief at the *reference* landform size, not a global ceiling.
    public var reliefMetres = 1200.0
    public var seaLevelMetres = 0.0

    /// Degrees spanned by the largest landform at the reference zoom. Areas range
    /// over two orders of magnitude, and a landform size that suits one end suits
    /// neither the other: too large and every window is one flank of one hill,
    /// drawn as parallel wood grain; too small and a wide window silts up into
    /// undifferentiated mush. The working size is derived from the window; this is
    /// the anchor of that ladder.
    public var baseWavelengthDegrees = 0.3
    /// Largest landform as a fraction of the window, before quantisation.
    public var landformSpanRatio = 1.2
    /// Relief grows with landform size, near-linearly as real terrain does: a
    /// 1 km-wide window with a kilometre of relief would be a cliff, not a hill.
    public var reliefExponent = 0.85

    /// A ceiling on the octave ladder, not a fixed count — how many are actually
    /// summed depends on what the sampling grid can resolve.
    public var maxOctaves = 12
    public var warpOctaves = 4
    /// Octaves finer than this many grid cells are dropped: they cannot be
    /// resolved, and summing them only adds speckle. Zooming in lowers the cell
    /// size, so finer detail appears the way it does on a real DEM.
    public var minCellsPerFeature = 8.0
    public var lacunarity = 2.0
    public var gain = 0.42
    public var warpStrength = 0.45
    public var ridgeWeight = 0.45
    /// Slope contrast. Above 1 the low ground flattens and the high ground
    /// steepens, which is what opens empty basins next to dense faces — the
    /// density contrast a printed relief sheet reads as depth.
    public var shapingExponent = 2.4

    /// 0 means "choose a round interval that keeps the window readable".
    public var contourIntervalMetres = 0.0
    public var indexEvery = 5
    public var targetLineCount = 44
    /// Where the field is steep, contours crowd closer than the sampling grid can
    /// resolve and break into sub-cell specks. Measured in grid cells.
    public var minContourLengthCells = 3.0

    public init() {}

    /// The dense hairline sheet: hundreds of levels on a fine grid and no accented
    /// lines, so depth is carried entirely by how tightly the lines crowd. Costs a
    /// few seconds per fetch rather than a few hundred milliseconds, which is the
    /// trade for a sheet meant to be printed rather than panned around.
    public static var denseRelief: TerrainFieldSettings {
        var settings = TerrainFieldSettings()
        settings.gridSize = 512
        settings.targetLineCount = 160
        settings.indexEvery = 0
        return settings
    }
}

public enum SimulatedField {

    /// Fixed offsets that decorrelate the warp fields from the base field.
    /// Constants rather than seed arithmetic, so a seed always names the same
    /// landscape.
    static let warpOffsetX = (x: 5.2, y: 1.3)
    static let warpOffsetY = (x: 9.7, y: 3.4)

    /// Shorter side of the window in degrees, corrected for latitude.
    public static func windowSpanDegrees(_ bounds: BoundingBox) -> Double {
        let meanLat = Swift.min(Swift.max((bounds.minLat + bounds.maxLat) / 2, -89.9), 89.9)
        let lonSpan = abs(bounds.maxLon - bounds.minLon) * cos(meanLat * .pi / 180)
        let latSpan = abs(bounds.maxLat - bounds.minLat)
        let spans = [lonSpan, latSpan].filter { $0 > 0 }
        return spans.min() ?? 0
    }

    /// Size of the largest landform for this window, on a power-of-two ladder.
    ///
    /// Quantising rather than tracking the window exactly is what keeps the result
    /// usable: the wavelength depends only on how wide the window is, never on
    /// where it is, so panning at one zoom walks across one continuous landscape.
    /// Nudging the area's size by a few percent lands on the same rung and changes
    /// nothing. Zooming far enough crosses a rung and the landscape rescales, which
    /// is the deliberate trade for every zoom looking like terrain.
    public static func wavelengthDegrees(
        _ bounds: BoundingBox,
        settings: TerrainFieldSettings = TerrainFieldSettings()
    ) -> Double {
        let anchor = Swift.max(1e-6, settings.baseWavelengthDegrees)
        let span = windowSpanDegrees(bounds)
        guard span > 0 else { return anchor }
        let target = span * Swift.max(1e-6, settings.landformSpanRatio)
        // Half-way rungs round to even, which is what Python's `round` does. A
        // window sitting exactly on a boundary must land on the same rung in both,
        // or the two draw different landscapes for the same request.
        return anchor * pow(2.0, (log2(target / anchor)).rounded(.toNearestOrEven))
    }

    /// Full relief of the landform this window is looking at.
    public static func reliefMetres(
        _ bounds: BoundingBox,
        settings: TerrainFieldSettings = TerrainFieldSettings()
    ) -> Double {
        let anchor = Swift.max(1e-6, settings.baseWavelengthDegrees)
        let wavelength = wavelengthDegrees(bounds, settings: settings)
        return settings.reliefMetres * pow(wavelength / anchor, settings.reliefExponent)
    }

    /// How many octaves this window's sampling grid can actually carry.
    ///
    /// Band-limiting to the grid keeps a wide window from summing detail it has no
    /// pixels to draw, which would only arrive as speckle. Amplitudes stay absolute,
    /// so dropping an octave removes detail rather than rescaling what remains.
    public static func resolvableOctaves(
        _ bounds: BoundingBox,
        settings: TerrainFieldSettings = TerrainFieldSettings()
    ) -> Int {
        let span = windowSpanDegrees(bounds)
        guard span > 0 else { return Swift.max(1, settings.maxOctaves) }

        let cellDegrees = span / Double(Swift.max(2, settings.gridSize) - 1)
        let finest = Swift.max(1e-9, settings.minCellsPerFeature * cellDegrees)
        let wavelength = wavelengthDegrees(bounds, settings: settings)
        let lacunarity = Swift.max(1.0001, settings.lacunarity)

        var octaves = 1
        while octaves < settings.maxOctaves,
              wavelength / pow(lacunarity, Double(octaves)) >= finest {
            octaves += 1
        }
        return octaves
    }

    /// Sample the field over an area. Row 0 is the north edge.
    ///
    /// The metres returned are a pure function of the sampled coordinates and the
    /// seed — no per-window normalisation, which is what keeps neighbouring windows
    /// continuous with each other.
    public static func elevationGrid(
        _ bounds: BoundingBox,
        settings: TerrainFieldSettings = TerrainFieldSettings()
    ) -> Field2D {
        let size = Swift.max(2, settings.gridSize)
        let wavelength = wavelengthDegrees(bounds, settings: settings)
        let octaves = resolvableOctaves(bounds, settings: settings)
        let warpOctaves = Swift.min(settings.warpOctaves, octaves)
        let relief = reliefMetres(bounds, settings: settings)

        var values = ContiguousArray<Double>()
        values.reserveCapacity(size * size)

        for row in 0..<size {
            // Row 0 is the north edge, so latitude runs down from the top.
            let lat = bounds.maxLat + (bounds.minLat - bounds.maxLat)
                * Double(row) / Double(size - 1)
            for column in 0..<size {
                let lon = bounds.minLon + (bounds.maxLon - bounds.minLon)
                    * Double(column) / Double(size - 1)

                // Sinusoidal-equal-area-style coordinates: one (lon, lat) always
                // maps to one noise coordinate worldwide, and features do not
                // stretch towards the poles.
                let x = lon * cos(lat * .pi / 180) / wavelength
                let y = lat / wavelength

                let warpX = fbm(
                    x: x + warpOffsetX.x, y: y + warpOffsetX.y,
                    settings: settings, octaves: warpOctaves, salt: 101
                )
                let warpY = fbm(
                    x: x + warpOffsetY.x, y: y + warpOffsetY.y,
                    settings: settings, octaves: warpOctaves, salt: 211
                )
                let warpedX = x + settings.warpStrength * (2 * warpX - 1)
                let warpedY = y + settings.warpStrength * (2 * warpY - 1)

                let base = fbm(
                    x: warpedX, y: warpedY, settings: settings, octaves: octaves, salt: 0
                )
                // Ridged noise carves the valley and crest structure that makes
                // contour spacing read as slope; plain fBm alone gives soft,
                // undifferentiated blobs.
                let ridged = 1 - abs(2 * base - 1)
                var shaped = (1 - settings.ridgeWeight) * base
                    + settings.ridgeWeight * pow(ridged, 1.5)
                shaped = pow(Swift.min(Swift.max(shaped, 0), 1), settings.shapingExponent)

                values.append(shaped * relief - settings.seaLevelMetres)
            }
        }
        return Field2D(rows: size, columns: size, values: values)
    }

    // MARK: - Noise

    /// Fractal sum of value noise, normalised to [0, 1].
    ///
    /// The normaliser covers the **whole** octave ladder, not just the octaves
    /// summed here. Normalising by the octaves actually used would rescale the field
    /// every time the window changed how many are resolvable — zooming in would
    /// inflate small ripples into mountains instead of revealing them.
    static func fbm(
        x: Double,
        y: Double,
        settings: TerrainFieldSettings,
        octaves: Int,
        salt: Int
    ) -> Double {
        var total = 0.0
        var amplitude = 1.0
        var frequency = 1.0

        for octave in 0..<Swift.max(1, octaves) {
            total += amplitude * valueNoise(
                x: x * frequency, y: y * frequency,
                seed: settings.seed + salt + octave * 7919
            )
            amplitude *= settings.gain
            frequency *= settings.lacunarity
        }

        var normaliser = 0.0
        for octave in 0..<Swift.max(1, settings.maxOctaves) {
            normaliser += pow(settings.gain, Double(octave))
        }
        return normaliser == 0 ? total : total / normaliser
    }

    /// Lattice value noise with quintic interpolation, in [0, 1].
    static func valueNoise(x: Double, y: Double, seed: Int) -> Double {
        let x0 = x.rounded(.down)
        let y0 = y.rounded(.down)
        let fx = quintic(x - x0)
        let fy = quintic(y - y0)
        let ix = Int64(x0)
        let iy = Int64(y0)

        let c00 = hashUnit(ix, iy, seed)
        let c10 = hashUnit(ix + 1, iy, seed)
        let c01 = hashUnit(ix, iy + 1, seed)
        let c11 = hashUnit(ix + 1, iy + 1, seed)

        let top = c00 + (c10 - c00) * fx
        let bottom = c01 + (c11 - c01) * fx
        return top + (bottom - top) * fy
    }

    static func quintic(_ t: Double) -> Double {
        t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// A deterministic value in [0, 1) for each integer lattice point.
    ///
    /// An integer hash rather than a seeded generator: the value at a lattice point
    /// must depend only on that point and the seed, so a window sampled anywhere
    /// agrees with its neighbours. Every step wraps on overflow, matching NumPy's
    /// `uint64` arithmetic exactly — the two implementations have to produce the
    /// same landscape from the same seed, bit for bit.
    static func hashUnit(_ ix: Int64, _ iy: Int64, _ seed: Int) -> Double {
        let x = UInt64(bitPattern: ix)
        let y = UInt64(bitPattern: iy)
        let key = UInt64(bitPattern: Int64(seed))

        var h = x &* 0x9E37_79B9_7F4A_7C15
        h ^= y &* 0xC2B2_AE3D_27D4_EB4F
        h ^= key &* 0x1656_67B1_9E37_79F9
        h ^= h >> 30
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27
        h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31

        return Double(h >> 11) / Double(1 << 53)
    }
}
