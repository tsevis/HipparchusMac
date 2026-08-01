import Foundation
import HipparchusGEOS
import HipparchusGeometry

/// Turning a shaded field into drawable features, for whichever provider has a
/// field to shade.
///
/// Two providers make elevation grids — real tiles and the simulated field — and
/// both should be able to shade them. Written once here rather than twice
/// because the delicate parts are not the shading, which is a page of
/// arithmetic in `Hillshade.swift`, but the decisions around it: decimate before
/// shading, band on a fixed scale, and index the bands by where they sit on that
/// scale rather than by where they sit in the returned list. Each of those was
/// arrived at by looking at output, and each is silently wrong in a way that
/// still produces a picture.
///
/// - Parameters:
///   - grid: the elevation field, at full resolution.
///   - cellMetres: how many metres of ground one *full-resolution* cell covers.
///   - toLonLat: a point in full-resolution grid indices, as a geographic
///     coordinate. Decimation is handled here, so callers need not know the
///     step.
func shadeBandFeatures(
    grid: Field2D,
    cellMetres: Double,
    sun: SunPosition,
    exaggeration: Double,
    bandCount: Int,
    maxPixels: Int,
    smoothingPasses: Int,
    source: String,
    provenance: Provenance,
    toLonLat: (GridPoint) -> Coordinate
) throws -> [Feature] {
    guard bandCount >= 2 else { return [] }

    // Shading is a derivative, so it carries several times the noise of the
    // ground it describes. Banding that noise makes speckle: thousands of
    // one-cell polygons that cost paths and show nothing at any size a sheet is
    // printed at.
    let step = max(1, Int(ceil(Double(max(grid.rows, grid.columns)) / Double(max(16, maxPixels)))))
    let coarse = grid.decimated(step: step)
    guard coarse.rows >= 3, coarse.columns >= 3 else { return [] }

    let shaded = hillshade(
        coarse,
        sun: sun,
        cellSizeMetres: cellMetres * Double(step),
        exaggeration: exaggeration
    ).smoothed(passes: smoothingPasses)
    guard let range = shaded.finiteRange, range.maximum > range.minimum else { return [] }

    // A fixed 0...1 scale, not the observed range. Stretching the observed range
    // turns "how much relief is there" into "always maximum contrast", and
    // covered flat ground in a mottle that looked like terrain and was not.
    let geos = GEOSContext()
    let bands = try elevationBands(
        shaded,
        boundaries: bandBoundaries(minimum: 0.0, maximum: 1.0, count: bandCount),
        using: geos
    )
    // One tone is a tint, not relief: it dulls the sheet and says nothing.
    guard bands.count >= 2 else { return [] }

    var features: [Feature] = []
    for band in bands {
        // The band's place on the fixed scale, not in this list. Compacting it
        // would put ground reaching only two adjacent tones at the ramp's two
        // extremes, which is the stretching above, moved one step downstream.
        let index = Int((band.lower * Double(bandCount)).rounded())
        let geometry = mapIndexSpaceToLonLat(band.geometry) { point in
            toLonLat(GridPoint(row: point.row * Double(step), column: point.column * Double(step)))
        }
        if geometry.isEmpty { continue }
        features.append(Feature(
            id: "\(source)/\(TerrainLayer.hillshade)/\(index)",
            layer: TerrainLayer.hillshade,
            source: source,
            geometry: geometry,
            provenance: provenance,
            properties: [
                "shade_low": .double(band.lower),
                "shade_high": .double(band.upper),
                "band_index": .int(index),
                // The whole scale, so two tones out of seven reads as gentle
                // ground rather than as maximum contrast.
                "band_count": .int(bandCount),
                "sun_azimuth": .double(sun.azimuthDegrees),
                "sun_altitude": .double(sun.altitudeDegrees),
            ]
        ))
    }
    return features
}
