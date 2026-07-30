import Foundation
import HipparchusGEOS
import HipparchusGeometry

/// Real elevation for any area on Earth, from public terrain tiles.
///
/// Ported from `src/hipparchus/data_sources/terrain_tiles.py`.
///
/// Measured ground, not a generated field: AWS's `elevation-tiles-prod` mosaic
/// (SRTM, NED, GMTED and friends) served as terrarium-encoded PNG over plain
/// HTTPS with no key and no account. Tiles for the area are fetched, stitched,
/// cropped and contoured, so a real mountain arrives as editable vector linework.
///
/// Two things worth knowing about what comes out:
///
/// - The mosaic is a **surface** model. In cities the maxima are buildings.
/// - Faint straight diagonals are void-fill seams and dataset boundaries in the
///   source mosaic, present in the raw grid before any contouring. One light
///   smoothing pass softens them; removing them properly would mean blurring real
///   terrain, so they are left alone.

public let terrainTilesProviderID = "terrain_tiles"

/// The layer names, matching the Python so styles and presets port unchanged.
public enum TerrainLayer {
    public static let minorContours = "terrain_contours"
    public static let indexContours = "terrain_index_contours"
    /// Terrarium carries bathymetry in the same band as land, so the sea floor
    /// comes free with the coast — but it is a different thing and reads as a
    /// different thing, so it gets its own layer rather than being drawn as if it
    /// were land.
    public static let bathymetry = "bathymetry"
    public static let summits = "summits"
    public static let elevationBands = "elevation_bands"

    public static let all = [elevationBands, bathymetry, minorContours, indexContours, summits]
}

/// How much real elevation to fetch, and how to contour it.
///
/// Ported field for field, including the reasoning behind the numbers — they were
/// each arrived at by looking at output.
public struct TerrainTileSettings: Sendable {
    public var urlTemplate = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
    /// Sampling width to aim for across the area. More pixels means finer
    /// contours and more tiles to fetch.
    public var targetPixels = 1200
    public var maxTiles = 64
    /// The mosaic's own limit; asking beyond it returns nothing useful.
    public var maxZoom = 15
    public var timeoutSeconds: TimeInterval = 30.0
    public var maxAttempts = 3
    public var retryDelaySeconds: TimeInterval = 0.7
    public var maxParallelRequests = 8
    /// 0 chooses a round interval from the relief actually in view. A fixed
    /// interval empties a small window and floods a large one.
    public var contourIntervalMetres = 0.0
    public var targetLineCount = 60
    public var indexEvery = 5
    public var minContourLengthCells = 2.0
    /// Sub-sea contours are split off so the sea floor can be styled apart from
    /// the land, or switched off entirely.
    public var separateBathymetry = true
    /// Summits are labelled with their real height. A block this wide has to
    /// contain the peak for it to count, which keeps a rough slope from sprouting
    /// a label on every bump.
    public var summitBlockPixels = 96
    public var maxSummits = 24
    public var minSummitProminenceMetres = 40.0
    /// A high point on the sea floor is not a summit. Without this an ocean area
    /// gets two dozen labelled "peaks" nobody can stand on.
    public var minSummitElevationMetres = 1.0
    /// Filled hypsometric bands. Broad areas, so they are traced on a decimated
    /// copy of the grid: full resolution costs time and adds detail no fill can
    /// show.
    public var emitElevationBands = true
    public var elevationBandCount = 10
    public var bandGridMaxPixels = 520
    /// Real DEMs carry step noise from their source resolution; one light pass
    /// settles it without moving the landforms.
    public var smoothingPasses = 1

    public init() {}
}

/// Fetches and contours real elevation for an area.
public struct TerrainTileProvider: MapProvider {
    public let providerID = terrainTilesProviderID
    public let label = "Elevation"
    public let provenance = Provenance.measured

    public let settings: TerrainTileSettings
    private let http: any HTTPFetching

    public init(settings: TerrainTileSettings = TerrainTileSettings(), http: any HTTPFetching = URLSessionFetcher()) {
        self.settings = settings
        self.http = http
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let bounds = query.bbox
        let zoom = chooseZoom(bounds: bounds, settings: settings)
        let (mosaic, origin) = try await mosaic(bounds: bounds, zoom: zoom)

        guard let (cropped, window) = cropToBounds(mosaic: mosaic, origin: origin, zoom: zoom, bounds: bounds) else {
            throw TerrainTileError.coveredNothing
        }
        let grid = cropped.smoothed(passes: settings.smoothingPasses)
        guard let range = grid.finiteRange else {
            throw TerrainTileError.noTilesReadable
        }

        var interval = settings.contourIntervalMetres
        if interval <= 0 {
            interval = niceInterval(range: range.maximum - range.minimum, targetLines: settings.targetLineCount)
        }
        let levels = contourLevels(
            minimum: range.minimum,
            maximum: range.maximum,
            interval: interval,
            indexEvery: settings.indexEvery
        )

        var featuresByLayer: [String: [Feature]] = Dictionary(uniqueKeysWithValues: TerrainLayer.all.map { ($0, []) })

        let toLonLat = lonLatMapper(window: window, zoom: zoom)
        let sample = lonLatSampler(grid: grid, window: window, zoom: zoom)
        let probe = probeStep(zoom: zoom)

        for (layer, layerLevels) in [
            (TerrainLayer.minorContours, levels.minor),
            (TerrainLayer.indexContours, levels.index),
        ] {
            for level in layerLevels {
                for polyline in contourPolylines(grid, level: level) {
                    guard polylineLength(polyline) >= settings.minContourLengthCells else { continue }
                    let coordinates = polyline.map(toLonLat)
                    guard coordinates.count >= 2 else { continue }
                    // Winding carries the slope aspect from here to the renderer;
                    // it is the only channel that survives clipping and smoothing.
                    let oriented = orientUphillLeft(coordinates, sample: sample, level: level, probe: probe)

                    let target = settings.separateBathymetry && level < 0 ? TerrainLayer.bathymetry : layer
                    featuresByLayer[target, default: []].append(Feature(
                        id: "\(providerID)/\(target)/\(String(format: "%.1f", level))/\(featuresByLayer[target]?.count ?? 0)",
                        layer: target,
                        source: providerID,
                        geometry: .lineString(LineString(oriented)),
                        provenance: .measured,
                        properties: [
                            "elevation": .double(level),
                            "contour_interval": .double(interval),
                            "index_contour": .bool(layer == TerrainLayer.indexContours),
                        ]
                    ))
                }
            }
        }

        if settings.emitElevationBands {
            featuresByLayer[TerrainLayer.elevationBands] = try bandFeatures(
                grid: grid, window: window, zoom: zoom
            )
        }

        featuresByLayer[TerrainLayer.summits] = summitFeatures(grid: grid, toLonLat: toLonLat)

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "format": .string("terrarium_tiles"),
                "provenance": .string(Provenance.measured.rawValue),
                "measured": .bool(true),
                "zoom": .int(zoom),
                "grid_rows": .int(grid.rows),
                "grid_columns": .int(grid.columns),
                "elevation_min_metres": .double(range.minimum),
                "elevation_max_metres": .double(range.maximum),
                "contour_interval_metres": .double(interval),
                "index_every": .int(settings.indexEvery),
                "summit_count": .int(featuresByLayer[TerrainLayer.summits]?.count ?? 0),
                "elevation_band_count": .int(featuresByLayer[TerrainLayer.elevationBands]?.count ?? 0),
                // The mosaic is a surface model, and saying so in the diagnostics
                // is cheaper than explaining a rooftop "summit" later.
                "elevation_model": .string("surface"),
            ],
            bbox: bounds,
            provenance: .measured
        )
    }

    // MARK: - Tiles

    /// Fetch and stitch the tiles covering the area.
    ///
    /// Tiles are independent network round trips, so fetching them one after
    /// another spends the whole time waiting: the Python measured 23 s serial
    /// against 5 s pooled. Concurrency is bounded rather than unbounded — a public
    /// bucket does not need 64 simultaneous requests from one desktop app.
    func mosaic(bounds: BoundingBox, zoom: Int) async throws -> (Field2D, origin: (x: Int, y: Int)) {
        let topLeft = WebMercator.tile(lon: bounds.minLon, lat: bounds.maxLat, zoom: zoom)
        let bottomRight = WebMercator.tile(lon: bounds.maxLon, lat: bounds.minLat, zoom: zoom)
        let columns = bottomRight.x - topLeft.x + 1
        let rows = bottomRight.y - topLeft.y + 1
        let needed = columns * rows
        guard needed <= settings.maxTiles else {
            throw TerrainTileError.tileBudgetExceeded(needed: needed, limit: settings.maxTiles, zoom: zoom)
        }

        let tilePixels = WebMercator.tilePixels
        var values = ContiguousArray<Double>(repeating: .nan, count: rows * tilePixels * columns * tilePixels)
        let mosaicColumns = columns * tilePixels

        let requests = (0..<rows).flatMap { row in (0..<columns).map { (row: row, column: $0) } }
        let limit = max(1, min(settings.maxParallelRequests, requests.count))

        try await withThrowingTaskGroup(of: (row: Int, column: Int, tile: Field2D?).self) { group in
            var next = 0
            func submit() {
                guard next < requests.count else { return }
                let request = requests[next]
                next += 1
                group.addTask { [settings, http, providerID] in
                    // Cancellation is checked here, between tiles, which is the
                    // only place this provider ever waits. A request already sent
                    // still completes; its result is simply discarded.
                    if Task.isCancelled { throw FetchCancelled(source: providerID) }
                    let tile = await Self.tile(
                        zoom: zoom,
                        x: topLeft.x + request.column,
                        y: topLeft.y + request.row,
                        settings: settings,
                        http: http
                    )
                    return (request.row, request.column, tile)
                }
            }
            for _ in 0..<limit { submit() }

            while let finished = try await group.next() {
                submit()
                guard let tile = finished.tile else { continue }
                let rowOffset = finished.row * tilePixels
                let columnOffset = finished.column * tilePixels
                for tileRow in 0..<min(tilePixels, tile.rows) {
                    let destination = (rowOffset + tileRow) * mosaicColumns + columnOffset
                    for tileColumn in 0..<min(tilePixels, tile.columns) {
                        values[destination + tileColumn] = tile[tileRow, tileColumn]
                    }
                }
            }
        }

        let mosaic = Field2D(rows: rows * tilePixels, columns: mosaicColumns, values: values)
        guard mosaic.hasFiniteValues else {
            throw TerrainTileError.noTilesReadable
        }
        return (mosaic, (topLeft.x, topLeft.y))
    }

    /// One tile, retried, or nil.
    ///
    /// A missing tile is a hole, not a failure: the rest of the area still draws.
    /// Only *every* tile failing is an error, and that is raised by the caller.
    private static func tile(
        zoom: Int,
        x: Int,
        y: Int,
        settings: TerrainTileSettings,
        http: any HTTPFetching
    ) async -> Field2D? {
        let urlString = settings.urlTemplate
            .replacingOccurrences(of: "{z}", with: String(zoom))
            .replacingOccurrences(of: "{x}", with: String(x))
            .replacingOccurrences(of: "{y}", with: String(y))
        guard let url = URL(string: urlString) else { return nil }

        let attempts = max(1, settings.maxAttempts)
        for attempt in 0..<attempts {
            if Task.isCancelled { return nil }
            do {
                return try decodeTerrarium(try await http.data(from: url, timeout: settings.timeoutSeconds))
            } catch {
                if attempt + 1 < attempts {
                    // Linear backoff, matching the Python. A tile bucket that is
                    // briefly unhappy usually is not for long.
                    let delay = settings.retryDelaySeconds * Double(attempt + 1)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        return nil
    }

    // MARK: - Bands and summits

    private func bandFeatures(grid: Field2D, window: PixelWindow, zoom: Int) throws -> [Feature] {
        guard settings.elevationBandCount >= 2 else { return [] }

        let step = max(1, Int(ceil(Double(max(grid.rows, grid.columns)) / Double(max(16, settings.bandGridMaxPixels)))))
        let coarse = grid.decimated(step: step)
        guard let range = coarse.finiteRange else { return [] }

        let geos = GEOSContext()
        let bands = try elevationBands(
            coarse,
            boundaries: bandBoundaries(minimum: range.minimum, maximum: range.maximum, count: settings.elevationBandCount),
            using: geos
        )
        guard !bands.isEmpty else { return [] }

        var features: [Feature] = []
        for (index, band) in bands.enumerated() {
            // Decimation changes the index scale, not the geography.
            let geometry = mapIndexSpaceToLonLat(band.geometry) { point in
                WebMercator.lonLatForPixel(
                    x: Double(window.left) + point.column * Double(step),
                    y: Double(window.top) + point.row * Double(step),
                    zoom: zoom
                )
            }
            if geometry.isEmpty { continue }
            features.append(Feature(
                id: "\(providerID)/\(TerrainLayer.elevationBands)/\(index)",
                layer: TerrainLayer.elevationBands,
                source: providerID,
                geometry: geometry,
                provenance: .measured,
                properties: [
                    "elevation_low": .double(band.lower),
                    "elevation_high": .double(band.upper),
                    "band_index": .int(index),
                    "band_count": .int(bands.count),
                ]
            ))
        }
        return features
    }

    /// Label the highest ground, with the height actually measured there.
    ///
    /// A contour sheet tells you the shape but never the number. Taking the
    /// maximum of each block, and keeping only blocks that stand clear of their
    /// own surroundings, puts a real height on the peaks without labelling every
    /// bump on a slope.
    private func summitFeatures(grid: Field2D, toLonLat: (GridPoint) -> Coordinate) -> [Feature] {
        let block = settings.summitBlockPixels
        guard grid.rows >= block, grid.columns >= block, settings.maxSummits > 0 else { return [] }

        var candidates: [(peak: Double, row: Int, column: Int)] = []
        for top in stride(from: 0, through: grid.rows - block, by: block) {
            for left in stride(from: 0, through: grid.columns - block, by: block) {
                var peak = -Double.infinity
                var lowest = Double.infinity
                var peakRow = top
                var peakColumn = left
                var sawFinite = false
                for row in top..<(top + block) {
                    for column in left..<(left + block) {
                        let value = grid[row, column]
                        guard value.isFinite else { continue }
                        sawFinite = true
                        if value > peak {
                            peak = value
                            peakRow = row
                            peakColumn = column
                        }
                        if value < lowest { lowest = value }
                    }
                }
                guard sawFinite else { continue }
                // Kickoff detail 8: the sea floor has highs too, and labelling two
                // dozen "peaks" in open water is what happens without this.
                guard peak >= settings.minSummitElevationMetres else { continue }
                // A block whose peak barely stands above its own floor is a slope,
                // not a summit. Block-local, so not true topographic prominence.
                guard peak - lowest >= settings.minSummitProminenceMetres else { continue }
                candidates.append((peak, peakRow, peakColumn))
            }
        }

        candidates.sort { $0.peak > $1.peak }
        return candidates.prefix(settings.maxSummits).enumerated().map { index, candidate in
            let point = toLonLat(GridPoint(row: Double(candidate.row), column: Double(candidate.column)))
            return Feature(
                id: "\(providerID)/summit/\(index)",
                layer: TerrainLayer.summits,
                source: providerID,
                geometry: .point(point),
                provenance: .measured,
                properties: [
                    "name": .string("\(Int(candidate.peak.rounded())) m"),
                    "elevation": .double(candidate.peak),
                ]
            )
        }
    }
}

// MARK: - Grid geometry

/// Where a cropped grid sits in the mosaic's global pixel space.
struct PixelWindow: Sendable, Equatable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int
}

/// Highest zoom that samples the area finely without over-fetching tiles.
func chooseZoom(bounds: BoundingBox, settings: TerrainTileSettings) -> Int {
    let lonSpan = max(1e-9, abs(bounds.lonSpan))
    for zoom in stride(from: min(settings.maxZoom, 15), through: 0, by: -1) {
        let pixelsAcross = lonSpan / 360.0 * Double(1 << zoom) * Double(WebMercator.tilePixels)
        if pixelsAcross > Double(settings.targetPixels) { continue }
        let topLeft = WebMercator.tile(lon: bounds.minLon, lat: bounds.maxLat, zoom: zoom)
        let bottomRight = WebMercator.tile(lon: bounds.maxLon, lat: bounds.minLat, zoom: zoom)
        if (bottomRight.x - topLeft.x + 1) * (bottomRight.y - topLeft.y + 1) <= settings.maxTiles {
            return zoom
        }
    }
    return 0
}

func cropToBounds(
    mosaic: Field2D,
    origin: (x: Int, y: Int),
    zoom: Int,
    bounds: BoundingBox
) -> (Field2D, PixelWindow)? {
    let originX = origin.x * WebMercator.tilePixels
    let originY = origin.y * WebMercator.tilePixels

    let topLeft = WebMercator.pixel(lon: bounds.minLon, lat: bounds.maxLat, zoom: zoom)
    let bottomRight = WebMercator.pixel(lon: bounds.maxLon, lat: bounds.minLat, zoom: zoom)

    let left = max(0, Int((topLeft.x - Double(originX)).rounded(.down)))
    let top = max(0, Int((topLeft.y - Double(originY)).rounded(.down)))
    let right = min(mosaic.columns, Int((bottomRight.x - Double(originX)).rounded(.up)))
    let bottom = min(mosaic.rows, Int((bottomRight.y - Double(originY)).rounded(.up)))
    guard right - left >= 2, bottom - top >= 2 else { return nil }

    var values = ContiguousArray<Double>()
    values.reserveCapacity((bottom - top) * (right - left))
    for row in top..<bottom {
        for column in left..<right {
            values.append(mosaic[row, column])
        }
    }
    let grid = Field2D(rows: bottom - top, columns: right - left, values: values)
    return (grid, PixelWindow(left: originX + left, top: originY + top, width: grid.columns, height: grid.rows))
}

/// Grid index to lon/lat, inverting the Mercator projection per vertex.
func lonLatMapper(window: PixelWindow, zoom: Int) -> (GridPoint) -> Coordinate {
    { point in
        WebMercator.lonLatForPixel(
            x: Double(window.left) + point.column,
            y: Double(window.top) + point.row,
            zoom: zoom
        )
    }
}

/// Read the field at a lon/lat, for the uphill-left probe.
func lonLatSampler(grid: Field2D, window: PixelWindow, zoom: Int) -> (Coordinate) -> Double {
    { coordinate in
        let pixel = WebMercator.pixel(lon: coordinate.lon, lat: coordinate.lat, zoom: zoom)
        let column = Int((pixel.x - Double(window.left)).rounded())
        let row = Int((pixel.y - Double(window.top)).rounded())
        return grid.clamped(row: row, column: column)
    }
}

/// One pixel, expressed in degrees of longitude.
func probeStep(zoom: Int) -> Double {
    max(1e-12, 360.0 / WebMercator.worldPixels(zoom: zoom))
}

func polylineLength(_ polyline: [GridPoint]) -> Double {
    guard polyline.count >= 2 else { return 0 }
    var total = 0.0
    for index in 0..<(polyline.count - 1) {
        let a = polyline[index]
        let b = polyline[index + 1]
        total += ((b.row - a.row) * (b.row - a.row) + (b.column - a.column) * (b.column - a.column)).squareRoot()
    }
    return total
}
