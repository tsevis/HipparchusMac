import Foundation
import HipparchusGEOS
import HipparchusGeometry

/// An ocean scalar, drawn the way this application draws every other field.
///
/// **The point of this file is how little is in it.** The contour tracer, the
/// GEOS banding and the two-stop ramp were written for elevation and know
/// nothing about metres — so a temperature, a salinity or a wave height is the
/// same pipeline pointed at a different array. What was missing was a way to
/// *get* the array, and that is `ERDDAPClient`.
///
/// Adding the next product is an `ERDDAPDataset` and two style entries. That was
/// the promise the brief made about ERDDAP, and this is it being kept.
public let erddapProviderIDPrefix = "erddap_"

public struct ERDDAPSettings: Sendable {
    public var dataset = ERDDAPDataset.seaSurfaceTemperature
    /// Filled bands under the isolines, the way elevation gets both.
    public var bandCount = 8
    /// Isolines. Zero chooses a round interval from the range actually in view,
    /// the same rule the contour interval follows for elevation: a fixed step
    /// empties a small frame and floods a large one.
    public var contourInterval = 0.0
    public var targetLineCount = 14
    public var targetSamples = 220
    public var timeoutSeconds: TimeInterval = 45
    /// Bands are broad, so they are traced on a decimated copy — full
    /// resolution costs paths and shows nothing a fill can carry.
    public var bandGridMaxPixels = 260

    public init() {}
}

public struct ERDDAPProvider: MapProvider {
    public let settings: ERDDAPSettings
    private let http: any HTTPFetching

    public var providerID: String { erddapProviderIDPrefix + settings.dataset.layerPrefix }
    public var label: String { "Sea surface temperature" }
    /// Instrument data, whatever the pipe. A satellite analysis is a
    /// measurement — an interpolated one, which is what `analysed` means in the
    /// variable's own name, and the sheet records the dataset so a reader can
    /// go and ask how it was made.
    public let provenance = Provenance.measured

    public init(settings: ERDDAPSettings = ERDDAPSettings(), http: any HTTPFetching = URLSessionFetcher()) {
        self.settings = settings
        self.http = http
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let dataset = settings.dataset
        let client = ERDDAPClient(
            dataset: dataset,
            targetSamples: settings.targetSamples,
            timeoutSeconds: settings.timeoutSeconds,
            http: http
        )
        let grid = try await client.grid(for: query.bbox)
        guard let range = grid.field.finiteRange, range.maximum > range.minimum else {
            throw ERDDAPError.notAGrid("every sample is the same value or missing")
        }

        var interval = settings.contourInterval
        if interval <= 0 {
            interval = niceInterval(
                range: range.maximum - range.minimum, targetLines: settings.targetLineCount
            )
        }
        let levels = contourLevels(
            minimum: range.minimum, maximum: range.maximum,
            interval: interval, indexEvery: 0
        )

        var featuresByLayer: [String: [Feature]] = [
            dataset.contourLayer: [],
            dataset.bandLayer: [],
        ]

        // The grid is a plain lon/lat lattice, so index space maps to the world
        // by linear interpolation — no Mercator, no tiles, no window. That is
        // the one thing simpler here than in the terrain provider.
        let toLonLat = Self.mapper(bounds: grid.bounds, rows: grid.field.rows, columns: grid.field.columns)

        for level in levels.minor + levels.index {
            for polyline in contourPolylines(grid.field, level: level) {
                let coordinates = polyline.map(toLonLat)
                guard coordinates.count >= 2 else { continue }
                featuresByLayer[dataset.contourLayer, default: []].append(Feature(
                    id: "\(providerID)/\(dataset.contourLayer)/\(String(format: "%.3f", level))/\(featuresByLayer[dataset.contourLayer]?.count ?? 0)",
                    layer: dataset.contourLayer,
                    source: providerID,
                    geometry: .lineString(LineString(coordinates)),
                    provenance: .measured,
                    properties: [
                        "value": .double(level),
                        "unit": .string(grid.unit),
                        "contour_interval": .double(interval),
                    ]
                ))
            }
        }

        featuresByLayer[dataset.bandLayer] = try bandFeatures(grid: grid, range: range)

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "provenance": .string(Provenance.measured.rawValue),
                "measured": .bool(true),
                "erddap_server": .string(dataset.server),
                "erddap_dataset": .string(dataset.datasetID),
                "erddap_variable": .string(dataset.variable),
                // `last` is a moving target; a sheet that does not record which
                // step it drew cannot be reproduced from its own diagnostics.
                "erddap_time": .string(grid.time),
                "value_unit": .string(grid.unit),
                "value_min": .double(range.minimum),
                "value_max": .double(range.maximum),
                "contour_interval": .double(interval),
                "grid_rows": .int(grid.field.rows),
                "grid_columns": .int(grid.field.columns),
            ],
            bbox: grid.bounds,
            provenance: .measured
        )
    }

    private func bandFeatures(
        grid: ERDDAPGrid, range: (minimum: Double, maximum: Double)
    ) throws -> [Feature] {
        guard settings.bandCount >= 2 else { return [] }
        let step = max(
            1,
            Int(ceil(Double(max(grid.field.rows, grid.field.columns))
                / Double(max(16, settings.bandGridMaxPixels))))
        )
        let coarse = grid.field.decimated(step: step)
        guard let coarseRange = coarse.finiteRange, coarseRange.maximum > coarseRange.minimum else {
            return []
        }

        let geos = GEOSContext()
        let bands = try elevationBands(
            coarse,
            boundaries: bandBoundaries(
                minimum: coarseRange.minimum, maximum: coarseRange.maximum,
                count: settings.bandCount
            ),
            using: geos
        )
        guard !bands.isEmpty else { return [] }

        let toLonLat = Self.mapper(bounds: grid.bounds, rows: coarse.rows, columns: coarse.columns)
        var features: [Feature] = []
        for (index, band) in bands.enumerated() {
            let geometry = mapIndexSpaceToLonLat(band.geometry, toLonLat)
            if geometry.isEmpty { continue }
            features.append(Feature(
                id: "\(providerID)/\(settings.dataset.bandLayer)/\(index)",
                layer: settings.dataset.bandLayer,
                source: providerID,
                geometry: geometry,
                provenance: .measured,
                properties: [
                    "value_low": .double(band.lower),
                    "value_high": .double(band.upper),
                    "unit": .string(grid.unit),
                    "band_index": .int(index),
                    "band_count": .int(bands.count),
                ]
            ))
        }
        return features
    }

    /// Index space to the world, for a plain lon/lat lattice with row 0 north.
    ///
    /// The cell *centres* span the bounds, so a grid of `n` rows has `n - 1`
    /// gaps between the first and the last — dividing by `n` instead walks the
    /// map a cell short of where it should end, which reads as a map very
    /// slightly of the wrong place.
    static func mapper(
        bounds: BoundingBox, rows: Int, columns: Int
    ) -> (GridPoint) -> Coordinate {
        let lonSpan = bounds.maxLon - bounds.minLon
        let latSpan = bounds.maxLat - bounds.minLat
        let lastRow = Double(Swift.max(1, rows - 1))
        let lastColumn = Double(Swift.max(1, columns - 1))
        return { point in
            Coordinate(
                lon: bounds.minLon + point.column / lastColumn * lonSpan,
                lat: bounds.maxLat - point.row / lastRow * latSpan
            )
        }
    }
}
