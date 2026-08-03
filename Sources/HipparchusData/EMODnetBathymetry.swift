import Foundation
import HipparchusGeometry

/// High-resolution bathymetry for European seas, from EMODnet's coverage service.
///
/// **Why this exists.** The elevation this application draws comes from the AWS
/// terrarium mosaic, whose *ocean* component is a global grid on the order of a
/// kilometre or two, upsampled to whatever zoom was asked for. A Myrtoan Sea
/// sheet with hundreds of smooth confident isobaths was drawing interpolation
/// with the same authority as the SRTM land beside it. EMODnet's DTM is about
/// 115 m over European waters — the Aegean, the Ionian, the Levantine, Cyprus,
/// which is most of the water this project keeps returning to.
///
/// **It is a WCS, and it answers with the easiest possible GeoTIFF**:
/// uncompressed, one band, IEEE float32, north-up, EPSG:4326. That is the whole
/// reason this is a provider rather than a note telling the user to run GDAL —
/// see `GeoTIFF.swift`, which is short because of it.
///
/// **The coverage carries land as well as sea.** Southern Cyprus reaches 688 m
/// in it. So the blend is sea-only: below the waterline EMODnet wins, above it
/// the terrain mosaic keeps its SRTM, which is the better answer for ground
/// anyone can stand on. That was learned from the data rather than from the
/// documentation, and there is a test that pins it.
///
/// **Licence.** EMODnet Bathymetry is open, and attribution is required. See the
/// attribution note in `About` — a source added without its wording is a licence
/// breach that nobody notices until somebody else does.
public struct EMODnetSettings: Sendable {
    public var endpoint = "https://ows.emodnet-bathymetry.eu/wcs"
    /// `mean` is the current DTM; the dated coverages are kept by the service
    /// for reproducibility and are not what a map should default to.
    public var coverage = "emodnet:mean"
    /// Sampled to match the terrain grid it will be blended into, capped so a
    /// wide frame does not ask for a coverage nobody needs at that size.
    public var maximumPixels = 1200
    public var timeoutSeconds: TimeInterval = 30
    public var maxAttempts = 2

    public init() {}
}

/// The service's own extent, from its `GetCapabilities`. Asking outside it
/// returns an error document rather than a coverage, and an error document that
/// is parsed as a grid is worse than no grid at all.
public let emodnetCoverage = BoundingBox(
    minLon: -70.5, minLat: 11.0, maxLon: 43.0, maxLat: 90.0
)

public struct EMODnetBathymetry {
    public let settings: EMODnetSettings
    private let http: any HTTPFetching

    public init(settings: EMODnetSettings = EMODnetSettings(), http: any HTTPFetching = URLSessionFetcher()) {
        self.settings = settings
        self.http = http
    }

    /// The frame plus the margin the feather needs, clamped to the service's own
    /// extent — asking outside it returns a complaint rather than a coverage.
    static func widened(_ bbox: BoundingBox) -> BoundingBox {
        let lonMargin = (bbox.maxLon - bbox.minLon) * requestMargin
        let latMargin = (bbox.maxLat - bbox.minLat) * requestMargin
        return BoundingBox(
            minLon: Swift.max(emodnetCoverage.minLon, bbox.minLon - lonMargin),
            minLat: Swift.max(emodnetCoverage.minLat, bbox.minLat - latMargin),
            maxLon: Swift.min(emodnetCoverage.maxLon, bbox.maxLon + lonMargin),
            maxLat: Swift.min(emodnetCoverage.maxLat, bbox.maxLat + latMargin)
        )
    }

    /// Whether it is worth asking at all.
    ///
    /// A frame entirely outside European waters gets nothing, and this is how it
    /// costs nothing rather than a round trip and a parse failure.
    public static func covers(_ bbox: BoundingBox) -> Bool {
        bbox.maxLon > emodnetCoverage.minLon && bbox.minLon < emodnetCoverage.maxLon
            && bbox.maxLat > emodnetCoverage.minLat && bbox.minLat < emodnetCoverage.maxLat
    }

    /// The coverage over an area, at roughly the given grid size.
    ///
    /// Returns `nil` rather than throwing when the service declines or answers
    /// with something unreadable: this is an *improvement* to a map that already
    /// works, and a sheet is better drawn from the global mosaic than not drawn.
    /// The caller records what happened in the diagnostics either way.
    /// How much wider than the frame to ask for.
    ///
    /// **The feather has to fall outside the drawing.** It ramps from the edge of
    /// whatever coverage comes back, and what comes back is exactly what was
    /// asked for — so asking for the frame alone put a diluted margin around
    /// every sheet, including sheets sitting in the middle of EMODnet's coverage
    /// with nothing to feather against. The Myrtoan Sea reported 89% of its sea
    /// floor surveyed when the true figure was all of it.
    ///
    /// Asking wider moves that margin off the page, and leaves the bounds-based
    /// feather meaning what it was written to mean: the place where the service
    /// genuinely runs out of data, which is where it clips the request.
    static let requestMargin = 0.09

    public func grid(for bbox: BoundingBox, rows: Int, columns: Int) async -> GeoTIFFGrid? {
        guard Self.covers(bbox) else { return nil }
        let bbox = Self.widened(bbox)

        let width = Swift.max(2, Swift.min(columns, settings.maximumPixels))
        let height = Swift.max(2, Swift.min(rows, settings.maximumPixels))
        guard let url = url(for: bbox, width: width, height: height) else { return nil }

        for attempt in 0..<Swift.max(1, settings.maxAttempts) {
            if Task.isCancelled { return nil }
            do {
                let data = try await http.data(from: url, timeout: settings.timeoutSeconds)
                // A WCS reports failure as an XML document with a 200, so the
                // first two bytes decide whether this is a coverage or a
                // complaint about the request.
                guard data.count > 8, data.starts(with: [0x49, 0x49]) || data.starts(with: [0x4D, 0x4D]) else {
                    return nil
                }
                return try GeoTIFF.read(data)
            } catch {
                if attempt == settings.maxAttempts - 1 { return nil }
            }
        }
        return nil
    }

    func url(for bbox: BoundingBox, width: Int, height: Int) -> URL? {
        var components = URLComponents(string: settings.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "service", value: "WCS"),
            URLQueryItem(name: "version", value: "1.0.0"),
            URLQueryItem(name: "request", value: "GetCoverage"),
            URLQueryItem(name: "coverage", value: settings.coverage),
            URLQueryItem(name: "crs", value: "EPSG:4326"),
            // WCS 1.0.0 states a bbox as minx,miny,maxx,maxy — longitude first,
            // which is the opposite of the Overpass convention two files away.
            URLQueryItem(name: "bbox", value: "\(bbox.minLon),\(bbox.minLat),\(bbox.maxLon),\(bbox.maxLat)"),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "format", value: "GeoTIFF"),
        ]
        return components?.url
    }
}

// MARK: - Blending

/// Put a finer sea floor under a coarser one, without a seam.
///
/// The two grids are the same ground at different resolutions and rarely the
/// same size, so the finer one is sampled at each of the coarser one's cells
/// rather than either being resampled wholesale.
///
/// Three rules, and each is there because of a way this goes wrong:
///
/// - **Sea only.** EMODnet carries land, and its land is coarser than SRTM's.
/// - **Only where it has something to say.** A hole in the coverage keeps
///   whatever was there before, rather than punching a hole in the map.
/// - **Feathered at the edge of coverage.** A hard switch between two grids that
///   disagree by a few metres draws a straight line across open water, and a
///   straight line on a bathymetric sheet reads as a fault or a survey track —
///   which is to say, as data. The blend ramps over a margin instead.
public func blendSeaFloor(
    _ base: Field2D,
    with finer: GeoTIFFGrid,
    over bbox: BoundingBox,
    featherFraction: Double = 0.06
) -> BlendedSeaFloor {
    guard base.rows > 0, base.columns > 0,
          finer.field.rows > 0, finer.field.columns > 0 else {
        return BlendedSeaFloor(field: base, surveyed: .zeros(like: base), replaced: 0)
    }

    let coverage = finer.bounds
    let lonSpan = coverage.maxLon - coverage.minLon
    let latSpan = coverage.maxLat - coverage.minLat
    guard lonSpan > 0, latSpan > 0 else {
        return BlendedSeaFloor(field: base, surveyed: .zeros(like: base), replaced: 0)
    }

    let feather = Swift.max(1e-9, Swift.min(lonSpan, latSpan) * Swift.max(0, featherFraction))
    var values = base.values
    // How much of each cell's depth came from the survey compilation. Not a
    // flag: a feathered cell is genuinely part one grid and part the other, and
    // rounding that to "surveyed" would be the same overclaim in miniature.
    var surveyed = ContiguousArray<Double>(repeating: 0, count: base.count)
    var replaced = 0

    for row in 0..<base.rows {
        // The base grid spans `bbox`, row 0 at the north.
        let lat = bbox.maxLat - (Double(row) + 0.5) / Double(base.rows) * (bbox.maxLat - bbox.minLat)
        guard lat >= coverage.minLat, lat <= coverage.maxLat else { continue }

        for column in 0..<base.columns {
            let lon = bbox.minLon + (Double(column) + 0.5) / Double(base.columns) * (bbox.maxLon - bbox.minLon)
            guard lon >= coverage.minLon, lon <= coverage.maxLon else { continue }

            let x = (lon - coverage.minLon) / lonSpan * Double(finer.field.columns)
            let y = (coverage.maxLat - lat) / latSpan * Double(finer.field.rows)
            let sampleRow = Swift.min(finer.field.rows - 1, Swift.max(0, Int(y)))
            let sampleColumn = Swift.min(finer.field.columns - 1, Swift.max(0, Int(x)))
            let depth = finer.field[sampleRow, sampleColumn]

            // A hole in the coverage says nothing, and its land is not wanted.
            guard depth.isFinite, depth < 0 else { continue }

            let index = row * base.columns + column
            let existing = values[index]
            guard existing.isFinite else {
                // Nothing to disagree with: a hole in the mosaic is filled
                // outright, because something is better than nothing.
                values[index] = depth
                surveyed[index] = 1
                replaced += 1
                continue
            }
            // **Land is the mosaic's job**, and this is the guard that means it.
            // Testing only the coverage's own sign was not enough: where the two
            // disagree at a coastline — the mosaic saying +100 and EMODnet −500 —
            // the sea would climb up the beach. Above the waterline the mosaic's
            // SRTM is the better answer for ground anyone can stand on.
            guard existing < 0 else { continue }

            // How far inside the coverage this cell sits, 0 at the edge and 1 a
            // feather's width in.
            let inside = Swift.min(
                Swift.min(lon - coverage.minLon, coverage.maxLon - lon),
                Swift.min(lat - coverage.minLat, coverage.maxLat - lat)
            )
            let weight = Swift.min(1.0, Swift.max(0.0, inside / feather))
            guard weight > 0 else { continue }

            values[index] = existing + (depth - existing) * weight
            surveyed[index] = weight
            replaced += 1
        }
    }

    return BlendedSeaFloor(
        field: Field2D(rows: base.rows, columns: base.columns, values: values),
        surveyed: Field2D(rows: base.rows, columns: base.columns, values: surveyed),
        replaced: replaced
    )
}

/// A grid, and how much of each cell anybody actually surveyed.
///
/// **This is as close to GEBCO's TID grid as this application can honestly get.**
/// TID says, per cell, whether a depth was measured by multibeam, by singlebeam,
/// interpolated, or predicted from satellite gravity — and it is published as a
/// picture and not as values. GEBCO's WCS offers no coverages at all, and
/// EMODnet's `quality_index` and `source_references` are WMS layers, so the only
/// route to the codes would be reverse-engineering a colour ramp out of a
/// rendered image. That is the thing this codebase refuses elsewhere by name.
///
/// What *is* known per cell, without asking anybody, is which of two grids a
/// depth came from: a survey compilation at about 115 m, or a global grid at a
/// kilometre or two. That is the distinction a reader is actually making a
/// decision on, and it is derived rather than claimed.
///
/// Note what this deliberately does **not** say. A cell outside the coverage is
/// `unsurveyed` here, not "predicted" — the global grid is measured along ship
/// tracks and interpolated between them, and without TID there is no way to know
/// which any one cell is. Saying "predicted" would be inventing the very
/// certainty this type exists to avoid.
public struct BlendedSeaFloor: Sendable {
    public let field: Field2D
    /// 1 where the depth is the survey compilation's, 0 where it is the global
    /// grid's, and in between across the feathered edge of coverage.
    public let surveyed: Field2D
    public let replaced: Int

    /// What a feature crossing these cells may claim.
    ///
    /// The weakest-claim rule, the same one `Provenance.merged` applies to a
    /// whole map: a contour that runs from surveyed ground onto the global grid
    /// is not a surveyed contour. `measured` requires every sample to be.
    public static func claim(forSamples samples: [Double]) -> Provenance {
        guard !samples.isEmpty else { return .approximate }
        return samples.allSatisfy { $0 >= 0.999 } ? .measured : .approximate
    }
}

/// What share of a frame's *sea floor* anybody surveyed.
///
/// Sea only, and that is the point: averaging the mask over the whole grid would
/// dilute the answer with land, which is not what the number is about and would
/// read lower the more coast a sheet contains.
public func surveyedShareOfSea(grid: Field2D, surveyed: Field2D) -> Double {
    guard grid.count == surveyed.count, grid.count > 0 else { return 0 }
    var total = 0.0
    var cells = 0
    for index in 0..<grid.count {
        let depth = grid.values[index]
        guard depth.isFinite, depth < 0 else { continue }
        total += surveyed.values[index]
        cells += 1
    }
    return cells == 0 ? 0 : total / Double(cells)
}

extension Geometry {
    /// Every coordinate in this geometry, put through `sample`.
    ///
    /// `mapCoordinates` rebuilds a geometry; this only wants to look at the
    /// points, which for a band means sampling a mask under each vertex of the
    /// ring. Only the exterior of a polygon is walked: a hole is somewhere the
    /// band is not, so what the mask says under it describes other ground.
    func mapCoordinatesToArray(_ sample: (Coordinate) -> Double) -> [Double] {
        switch self {
        case .empty: []
        case .point(let coordinate): [sample(coordinate)]
        case .multiPoint(let coordinates): coordinates.map(sample)
        case .lineString(let line): line.coordinates.map(sample)
        case .multiLineString(let lines): lines.flatMap { $0.coordinates.map(sample) }
        case .polygon(let polygon): polygon.exterior.coordinates.map(sample)
        case .multiPolygon(let polygons):
            polygons.flatMap { $0.exterior.coordinates.map(sample) }
        case .collection(let parts): parts.flatMap { $0.mapCoordinatesToArray(sample) }
        }
    }
}

extension Field2D {
    static func zeros(like other: Field2D) -> Field2D {
        Field2D(rows: other.rows, columns: other.columns, repeating: 0)
    }

    /// The value at a fractional position in another grid's index space.
    ///
    /// Depth bands are traced on a decimated copy, so a band's coordinates are
    /// in a smaller grid than the mask. Scaling here rather than resampling the
    /// mask keeps one array and no interpolation nobody asked for.
    func sampleScaled(row: Double, column: Double, ofRows: Int, ofColumns: Int) -> Double {
        guard rows > 0, columns > 0, ofRows > 0, ofColumns > 0 else { return 0 }
        let r = Int((row / Double(ofRows) * Double(rows)).rounded(.down))
        let c = Int((column / Double(ofColumns) * Double(columns)).rounded(.down))
        return clamped(row: r, column: c)
    }
}
