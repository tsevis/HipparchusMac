import Foundation
import HipparchusGeometry

/// Terrain that is generated rather than fetched.
///
/// Ported from `data_sources/simulated_field.py`.
///
/// The one source that needs nothing: no file, no account, no network. It exists so
/// contour work is reachable on a bare install, and so the rest of the pipeline can
/// be exercised offline.
///
/// Everything it emits declares itself `synthetic`, on the features, in the merged
/// metadata and on the scene. That is the whole reason the provenance vocabulary
/// exists: this source produces beautiful relief that is not a measurement of
/// anywhere, and nothing downstream should be able to forget that.
public struct SimulatedFieldProvider: MapProvider {
    public let providerID = SourceID.simulatedTerrain
    public let label = "Simulated Terrain (synthetic)"
    public let provenance = Provenance.synthetic

    public let settings: TerrainFieldSettings

    public init(settings: TerrainFieldSettings = TerrainFieldSettings()) {
        self.settings = settings
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let bounds = query.bbox
        let grid = SimulatedField.elevationGrid(bounds, settings: settings)

        let finite = grid.values.filter(\.isFinite)
        let lowest = finite.min() ?? 0
        let highest = finite.max() ?? 0

        // Auto: a fixed metre interval empties a small window and floods a large
        // one, so the interval follows the relief actually in view.
        let interval = settings.contourIntervalMetres > 0
            ? settings.contourIntervalMetres
            : niceInterval(range: highest - lowest, targetLines: settings.targetLineCount)

        let levels = contourLevels(
            minimum: lowest, maximum: highest,
            interval: interval, indexEvery: settings.indexEvery
        )

        var featuresByLayer: [String: [Feature]] = [
            TerrainLayer.minorContours: [],
            TerrainLayer.indexContours: [],
        ]

        let probe = probeStep(grid: grid, bounds: bounds)
        for (layer, layerLevels) in [
            (TerrainLayer.minorContours, levels.minor),
            (TerrainLayer.indexContours, levels.index),
        ] {
            for level in layerLevels {
                for polyline in contourPolylines(grid, level: level) {
                    guard length(of: polyline) >= settings.minContourLengthCells else { continue }
                    let coordinates = polylineToLonLat(
                        polyline, bounds: bounds, rows: grid.rows, columns: grid.columns
                    )
                    guard coordinates.count >= 2 else { continue }

                    // Wind every contour with the high ground on its left. That is
                    // what lets the renderer light the sheet without having to drag
                    // the elevation grid through it alongside the geometry.
                    let oriented = orientUphillLeft(
                        coordinates,
                        sample: { sample(grid, at: $0, bounds: bounds) },
                        level: level,
                        probe: probe
                    )

                    featuresByLayer[layer, default: []].append(Feature(
                        id: "\(providerID)/\(layer)/\(String(format: "%.3f", level))/\(featuresByLayer[layer]?.count ?? 0)",
                        layer: layer,
                        source: providerID,
                        geometry: .lineString(LineString(oriented)),
                        provenance: .synthetic,
                        properties: [
                            "elevation": .double(level),
                            "contour_interval": .double(interval),
                            "index_contour": .bool(layer == TerrainLayer.indexContours),
                            "synthetic": .bool(true),
                        ]
                    ))
                }
            }
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "format": .string("synthetic"),
                // Read by the scene and carried into the exported diagnostics, so
                // the disclosure travels with the file.
                "synthetic": .bool(true),
                "seed": .int(settings.seed),
                "contour_interval_metres": .double(interval),
                "index_every": .int(settings.indexEvery),
                "elevation_min_metres": .double(lowest),
                "elevation_max_metres": .double(highest),
                "grid_size": .int(settings.gridSize),
                "elevation_model": .string("generated"),
            ],
            bbox: bounds,
            provenance: .synthetic
        )
    }

    // MARK: -

    /// Path length in grid cells.
    func length(of polyline: [GridPoint]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var total = 0.0
        for (start, end) in zip(polyline, polyline.dropFirst()) {
            let dRow = end.row - start.row
            let dColumn = end.column - start.column
            total += (dRow * dRow + dColumn * dColumn).squareRoot()
        }
        return total
    }

    /// Bilinear read of the field at a longitude and latitude, for the winding pass.
    func sample(_ grid: Field2D, at coordinate: Coordinate, bounds: BoundingBox) -> Double {
        guard grid.rows > 1, grid.columns > 1 else { return .nan }
        let lonSpan = bounds.maxLon - bounds.minLon
        let latSpan = bounds.maxLat - bounds.minLat

        let rawColumn = lonSpan == 0 ? 0 : (coordinate.x - bounds.minLon) / lonSpan * Double(grid.columns - 1)
        let rawRow = latSpan == 0 ? 0 : (bounds.maxLat - coordinate.y) / latSpan * Double(grid.rows - 1)
        let column = Swift.min(Swift.max(rawColumn, 0), Double(grid.columns - 1))
        let row = Swift.min(Swift.max(rawRow, 0), Double(grid.rows - 1))

        let column0 = Int(column)
        let row0 = Int(row)
        let column1 = Swift.min(column0 + 1, grid.columns - 1)
        let row1 = Swift.min(row0 + 1, grid.rows - 1)
        let fx = column - Double(column0)
        let fy = row - Double(row0)

        let top = grid.clamped(row: row0, column: column0) * (1 - fx)
            + grid.clamped(row: row0, column: column1) * fx
        let bottom = grid.clamped(row: row1, column: column0) * (1 - fx)
            + grid.clamped(row: row1, column: column1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// Half a grid cell in degrees — far enough to leave the contour, close enough
    /// to stay on the same slope.
    func probeStep(grid: Field2D, bounds: BoundingBox) -> Double {
        let lonStep = abs(bounds.maxLon - bounds.minLon) / Double(Swift.max(1, grid.columns - 1))
        let latStep = abs(bounds.maxLat - bounds.minLat) / Double(Swift.max(1, grid.rows - 1))
        return Swift.max(1e-12, Swift.min(lonStep, latStep) * 0.5)
    }
}
