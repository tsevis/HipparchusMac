import CoreGraphics
import Foundation
import HipparchusGeometry
import ImageIO

/// Satellite imagery from NASA GIBS, contoured into vector iso-lines.
///
/// Ported from `data_sources/gibs_provider.py`.
///
/// Kickoff detail 10, in full, because every part of it changes what the output
/// means: **GIBS is rendered brightness, not calibrated radiance.** The WMS serves a
/// visualisation product, so the contoured quantity is picture brightness. It
/// saturates over city cores — the render clips to white, and a bright centre can
/// come back with *no* contours at all because there is no gradient left to trace.
/// It is a coarse regional product, so a city-sized frame upsamples into blocks.
/// And it returns transient 500s, so one failure must not end the fetch.
///
/// That is why this source declares `uncalibrated`. A night-lights sheet from here
/// is a picture of a picture, and the provenance is what stops it being read as a
/// measurement.
public enum NightLightsLayer {
    public static let name = "night_lights"
}

/// Which GIBS layer to sample, and how finely.
public struct SatelliteImagerySettings: Sendable {
    public var endpoint = "https://gibs.earthdata.nasa.gov/wms/epsg4326/best/wms.cgi"
    public var layer = "VIIRS_Black_Marble"
    /// Empty asks GIBS for its default epoch, which is what a static composite such
    /// as Black Marble wants.
    public var date = ""
    public var maxPixels = 1024
    public var timeoutSeconds: TimeInterval = 45
    /// GIBS answers a repeated request fine after returning 500 on the first,
    /// observed in testing, so one failure must not end the fetch.
    public var maxAttempts = 3
    public var retryDelay: Duration = .seconds(1)
    public var levels = 14
    public var minContourLengthCells = 3.0
    /// GIBS upsamples its imagery to whatever size is asked for, so the returned PNG
    /// carries large blocks of one value and raw contours staircase along the source
    /// pixel edges. A couple of box-blur passes restore smooth iso-lines without
    /// inventing detail the imagery does not have.
    public var smoothingPasses = 2

    public init() {}
}

public struct SatelliteImageryError: Error, CustomStringConvertible {
    public let reason: String
    public var description: String { "GIBS imagery could not be used: \(reason)" }
}

public struct GIBSImageryProvider: MapProvider {
    public let providerID = SourceID.gibsImagery
    public let label = "Night Lights (NASA GIBS)"
    public let provenance = Provenance.uncalibrated

    public let settings: SatelliteImagerySettings
    private let http: any HTTPFetching

    public init(
        settings: SatelliteImagerySettings = SatelliteImagerySettings(),
        http: any HTTPFetching = URLSessionFetcher()
    ) {
        self.settings = settings
        self.http = http
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let bbox = query.bbox
        let size = Self.imageSize(bbox: bbox, maxPixels: settings.maxPixels)
        let data = try await request(bbox: bbox, width: size.width, height: size.height)
        let grid = try Self.luminanceGrid(data).smoothed(passes: settings.smoothingPasses)

        let finite = grid.values.filter(\.isFinite)
        let lowest = finite.min() ?? 0
        let highest = finite.max() ?? 0

        var features: [Feature] = []
        for level in Self.levels(between: lowest, and: highest, count: settings.levels) {
            for polyline in contourPolylines(grid, level: level) {
                guard Self.length(of: polyline) >= settings.minContourLengthCells else { continue }
                let coordinates = polylineToLonLat(polyline, bounds: bbox, rows: grid.rows, columns: grid.columns)
                guard coordinates.count >= 2 else { continue }

                // Winding carries the aspect, the same as it does for terrain: it is
                // the only property that survives clipping and smoothing.
                let oriented = orientUphillLeft(
                    coordinates,
                    sample: { Self.sample(grid, at: $0, bbox: bbox) },
                    level: level,
                    probe: Self.probeStep(grid: grid, bbox: bbox)
                )

                features.append(Feature(
                    id: "\(providerID)/\(NightLightsLayer.name)/\(String(format: "%.2f", level))/\(features.count)",
                    layer: NightLightsLayer.name,
                    source: providerID,
                    geometry: .lineString(LineString(oriented)),
                    provenance: .uncalibrated,
                    properties: [
                        "brightness": .double(level),
                        "gibs_layer": .string(settings.layer),
                    ]
                ))
            }
        }

        return FeatureCollection(
            featuresByLayer: [NightLightsLayer.name: features],
            metadata: [
                "source": .string(providerID),
                "format": .string("gibs_wms_png"),
                "gibs_layer": .string(settings.layer),
                "brightness_min": .double(lowest),
                "brightness_max": .double(highest),
                "contour_count": .int(features.count),
                // Not a measurement. Carried into the exported diagnostics so the
                // disclosure travels with the file.
                "calibration": .string("uncalibrated rendered brightness, not radiance"),
                // A window that clips to white has nothing left to contour, and that
                // is worth saying rather than leaving as a mysteriously empty layer.
                "saturated": .bool(features.isEmpty && highest > 0),
            ],
            bbox: bbox,
            provenance: .uncalibrated
        )
    }

    // MARK: - The request

    /// Build the WMS GetMap URL.
    ///
    /// **Kickoff detail 1, and the single most expensive line in this file.** WMS
    /// 1.3.0 with EPSG:4326 orders BBOX as `minLat,minLon,maxLat,maxLon` — latitude
    /// first. Reversing it does not fail; it silently returns imagery of somewhere
    /// else entirely.
    func requestURL(bbox: BoundingBox, width: Int, height: Int) -> URL? {
        var components = URLComponents(string: settings.endpoint)
        var items = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "LAYERS", value: settings.layer),
            URLQueryItem(name: "CRS", value: "EPSG:4326"),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "WIDTH", value: String(width)),
            URLQueryItem(name: "HEIGHT", value: String(height)),
            URLQueryItem(
                name: "BBOX",
                value: "\(bbox.minLat),\(bbox.minLon),\(bbox.maxLat),\(bbox.maxLon)"
            ),
        ]
        if !settings.date.isEmpty {
            items.append(URLQueryItem(name: "TIME", value: settings.date))
        }
        components?.queryItems = items
        return components?.url
    }

    private func request(bbox: BoundingBox, width: Int, height: Int) async throws -> Data {
        guard let url = requestURL(bbox: bbox, width: width, height: height) else {
            throw SatelliteImageryError(reason: "could not build the request URL")
        }

        var lastError = "unknown"
        for attempt in 1...Swift.max(1, settings.maxAttempts) {
            try Task.checkCancellation()
            do {
                return try await http.data(from: url, timeout: settings.timeoutSeconds)
            } catch {
                lastError = String(describing: error)
            }
            guard attempt < settings.maxAttempts else { break }
            try? await Task.sleep(for: settings.retryDelay)
        }
        throw SatelliteImageryError(reason: "after \(settings.maxAttempts) attempts: \(lastError)")
    }

    // MARK: - Imagery

    /// Pixel size matching the area's aspect, capped on the long side.
    static func imageSize(bbox: BoundingBox, maxPixels: Int) -> (width: Int, height: Int) {
        let lonSpan = abs(bbox.maxLon - bbox.minLon)
        let latSpan = abs(bbox.maxLat - bbox.minLat)
        guard lonSpan > 0, latSpan > 0 else { return (maxPixels, maxPixels) }
        if lonSpan >= latSpan {
            return (maxPixels, Swift.max(2, Int((Double(maxPixels) * latSpan / lonSpan).rounded())))
        }
        return (Swift.max(2, Int((Double(maxPixels) * lonSpan / latSpan).rounded())), maxPixels)
    }

    /// Rec. 709 luma coefficients — the same weighting the Python uses.
    static let luma = (red: 0.2126, green: 0.7152, blue: 0.0722)

    /// Decode a PNG into a luminance field, row 0 at the north edge.
    ///
    /// Alpha is read rather than ignored, and a transparent pixel becomes `NaN`:
    /// GIBS uses transparency for "no data", and treating it as black ground would
    /// draw a bright coastline around every gap in the mosaic.
    static func luminanceGrid(_ data: Data) throws -> Field2D {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary)
        else {
            throw SatelliteImageryError(reason: "the response is not a decodable image")
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw SatelliteImageryError(reason: "the image has no pixels")
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        let decoded: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: space,
                    // Premultiplied because a bitmap context supports nothing else
                    // at 8 bits per component — straight `.last` is rejected. The
                    // premultiplication is undone per pixel below, so brightness is
                    // not quietly scaled by opacity.
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard decoded else {
            throw SatelliteImageryError(reason: "could not draw the image into a bitmap")
        }

        var values = ContiguousArray<Double>()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let base = row * bytesPerRow
            for column in 0..<width {
                let offset = base + column * bytesPerPixel
                let alpha = Double(pixels[offset + 3])
                guard alpha > 0 else {
                    values.append(.nan)
                    continue
                }
                // Undo the premultiplication. A no-op for the fully opaque pixels
                // that make up almost all of a GIBS response, and the difference
                // between brightness and brightness-times-opacity for the rest.
                let scale = 255.0 / alpha
                values.append(
                    (Double(pixels[offset]) * luma.red
                        + Double(pixels[offset + 1]) * luma.green
                        + Double(pixels[offset + 2]) * luma.blue) * scale
                )
            }
        }
        return Field2D(rows: height, columns: width, values: values)
    }

    // MARK: - Contouring

    /// Evenly spaced levels strictly inside the range.
    ///
    /// Strictly inside on purpose: a level at the exact minimum or maximum traces the
    /// frame edge rather than anything in the picture.
    static func levels(between lowest: Double, and highest: Double, count: Int) -> [Double] {
        guard highest > lowest, count > 0 else { return [] }
        let step = (highest - lowest) / Double(count + 1)
        return (1...count).map { lowest + step * Double($0) }
    }

    static func length(of polyline: [GridPoint]) -> Double {
        guard polyline.count >= 2 else { return 0 }
        var total = 0.0
        for (start, end) in zip(polyline, polyline.dropFirst()) {
            let dRow = end.row - start.row
            let dColumn = end.column - start.column
            total += (dRow * dRow + dColumn * dColumn).squareRoot()
        }
        return total
    }

    /// Read the field at a longitude and latitude, for the winding pass.
    static func sample(_ grid: Field2D, at coordinate: Coordinate, bbox: BoundingBox) -> Double {
        guard grid.rows > 1, grid.columns > 1 else { return .nan }
        let lonSpan = bbox.maxLon - bbox.minLon
        let latSpan = bbox.maxLat - bbox.minLat
        guard lonSpan != 0, latSpan != 0 else { return .nan }

        let column = (coordinate.lon - bbox.minLon) / lonSpan * Double(grid.columns - 1)
        // Row 0 is the north edge, so latitude runs the other way.
        let row = (bbox.maxLat - coordinate.lat) / latSpan * Double(grid.rows - 1)
        return grid.clamped(row: Int(row.rounded()), column: Int(column.rounded()))
    }

    /// One cell, in degrees — how far to step when testing which side is brighter.
    static func probeStep(grid: Field2D, bbox: BoundingBox) -> Double {
        guard grid.rows > 1, grid.columns > 1 else { return 1e-6 }
        let lonStep = abs(bbox.maxLon - bbox.minLon) / Double(grid.columns - 1)
        let latStep = abs(bbox.maxLat - bbox.minLat) / Double(grid.rows - 1)
        return Swift.max(1e-9, Swift.min(lonStep, latStep))
    }
}
