import Foundation
import HipparchusGeometry

/// One client for a federated network of ocean data.
///
/// ERDDAP is a REST protocol with server-side subsetting, and hundreds of
/// servers speak it — NOAA CoastWatch, IOOS, IFREMER, academic institutions.
/// Sea surface temperature, salinity, wave height, ocean colour, surface winds,
/// buoy observations: one client reaches all of it, and each product arrives as
/// a grid this application already knows how to contour, band and shade.
///
/// That is the whole argument for writing this rather than a provider per
/// product. **Every subsequent ocean scalar is a `Dataset` and a style**, not a
/// new network path.
///
/// **CSV, not NetCDF and not GeoTIFF.** griddap offers all three. NetCDF would
/// need an HDF5 reader this does not have. GeoTIFF would reuse `GeoTIFF.swift` —
/// and the server answered a real request for one with a 503, while the CSV of
/// the same subset came back immediately and self-describing, with its units in
/// the second header row. A format that states what its numbers mean is worth
/// more here than one that saves a few bytes, and the parsing is twenty lines.
public struct ERDDAPDataset: Sendable {
    /// The server root, without a trailing slash — `https://…/erddap`.
    public let server: String
    public let datasetID: String
    /// The grid variable to fetch. A dataset may carry several; asking for one
    /// keeps the response to what is going to be drawn.
    public let variable: String
    /// What the layers are called. `sst` gives `sst_contours` and `sst_bands`.
    public let layerPrefix: String
    /// For the sheet's own metadata, so a reader knows what the numbers are.
    public let unit: String
    /// The grid's nominal spacing in degrees, used **only** to choose a stride.
    ///
    /// Wrong here costs a coarser or a finer sample than intended and nothing
    /// else — never a wrong value, never a wrong place. Declared rather than
    /// discovered so a fetch is one request instead of three.
    public let nominalResolution: Double

    public init(
        server: String, datasetID: String, variable: String,
        layerPrefix: String, unit: String, nominalResolution: Double
    ) {
        self.server = server
        self.datasetID = datasetID
        self.variable = variable
        self.layerPrefix = layerPrefix
        self.unit = unit
        self.nominalResolution = nominalResolution
    }

    public var contourLayer: String { "\(layerPrefix)_contours" }
    public var bandLayer: String { "\(layerPrefix)_bands" }

    /// Sea surface temperature, and the first thing to point this at.
    ///
    /// MUR is a global daily analysis at 0.01°, which is finer than anything
    /// else here draws, and it is a number a reader can check against their own
    /// experience of the sea in August.
    public static let seaSurfaceTemperature = ERDDAPDataset(
        server: "https://coastwatch.pfeg.noaa.gov/erddap",
        datasetID: "jplMURSST41",
        variable: "analysed_sst",
        layerPrefix: "sst",
        unit: "°C",
        nominalResolution: 0.01
    )
}

public struct ERDDAPGrid: Sendable {
    public let field: Field2D
    public let bounds: BoundingBox
    /// What the server said the values are, from the CSV's own second row —
    /// read rather than assumed, so a dataset that changes units says so.
    public let unit: String
    /// The time step the server actually returned, for the diagnostics. `last`
    /// is a moving target and a sheet should record which one it drew.
    public let time: String
}

public enum ERDDAPError: Error, CustomStringConvertible, Equatable {
    case refused(String)
    case noRows
    case notAGrid(String)

    public var description: String {
        switch self {
        case .refused(let why): "the server refused: \(why)"
        case .noRows: "the response carried no data rows"
        case .notAGrid(let why): "the response is not a grid: \(why)"
        }
    }
}

public struct ERDDAPClient: Sendable {
    public let dataset: ERDDAPDataset
    /// Roughly how many samples to bring back across the longer side. Server-
    /// side striding is what keeps a frame the size of the Aegean from being a
    /// million rows of text.
    public var targetSamples: Int
    public var timeoutSeconds: TimeInterval
    private let http: any HTTPFetching

    public init(
        dataset: ERDDAPDataset = .seaSurfaceTemperature,
        targetSamples: Int = 220,
        timeoutSeconds: TimeInterval = 45,
        http: any HTTPFetching = URLSessionFetcher()
    ) {
        self.dataset = dataset
        self.targetSamples = targetSamples
        self.timeoutSeconds = timeoutSeconds
        self.http = http
    }

    /// The stride that brings a bbox back at about `targetSamples` across.
    ///
    /// griddap strides in *index* steps, so this needs the grid's spacing; that
    /// is what `nominalResolution` is for.
    func stride(for bbox: BoundingBox) -> Int {
        let span = Swift.max(bbox.maxLon - bbox.minLon, bbox.maxLat - bbox.minLat)
        let cells = span / Swift.max(1e-9, dataset.nominalResolution)
        return Swift.max(1, Int((cells / Double(Swift.max(1, targetSamples))).rounded()))
    }

    /// A griddap request for the latest time step over an area.
    ///
    /// The dimension order is the dataset's own — time, latitude, longitude —
    /// and latitude is stated **south to north** because that is the order MUR
    /// stores it in. A dataset stored the other way would need its range
    /// reversed, which is the sort of thing that returns a valid grid of
    /// nowhere; `bounds` is read back from the response rather than assumed for
    /// exactly that reason.
    public func url(for bbox: BoundingBox) -> URL? {
        let step = stride(for: bbox)
        let query = "\(dataset.variable)"
            + "[(last)]"
            + "[(\(bbox.minLat)):\(step):(\(bbox.maxLat))]"
            + "[(\(bbox.minLon)):\(step):(\(bbox.maxLon))]"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "()-._:,")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(dataset.server)/griddap/\(dataset.datasetID).csv?\(encoded)")
    }

    /// Two variables in one request, for a vector field.
    ///
    /// griddap takes a comma-separated list, each with its own dimension
    /// selection, and answers with one CSV carrying both columns — so a current
    /// costs one round trip rather than two, and the two components are
    /// guaranteed to be the same time step and the same lattice. Fetched
    /// separately they might not be.
    public func vectorURL(for bbox: BoundingBox, second: String) -> URL? {
        let step = stride(for: bbox)
        let selection = "[(last)]"
            + "[(\(bbox.minLat)):\(step):(\(bbox.maxLat))]"
            + "[(\(bbox.minLon)):\(step):(\(bbox.maxLon))]"
        let query = "\(dataset.variable)\(selection),\(second)\(selection)"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "()-._:,")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(dataset.server)/griddap/\(dataset.datasetID).csv?\(encoded)")
    }

    /// The eastward and northward halves of a flow, on one lattice.
    public func vectorGrid(
        for bbox: BoundingBox, second: String
    ) async throws -> (east: ERDDAPGrid, north: ERDDAPGrid) {
        guard let url = vectorURL(for: bbox, second: second) else {
            throw ERDDAPError.refused("the request could not be formed")
        }
        let data = try await http.data(from: url, timeout: timeoutSeconds)
        let text = String(decoding: data, as: UTF8.self)
        return (
            try Self.parse(text, variable: dataset.variable),
            try Self.parse(text, variable: second)
        )
    }

    public func grid(for bbox: BoundingBox) async throws -> ERDDAPGrid {
        guard let url = url(for: bbox) else {
            throw ERDDAPError.refused("the request could not be formed")
        }
        let data = try await http.data(from: url, timeout: timeoutSeconds)
        return try Self.parse(String(decoding: data, as: UTF8.self), variable: dataset.variable)
    }

    // MARK: - Reading the answer

    /// griddap's CSV: a row of column names, a row of units, then the data.
    ///
    /// The grid is rebuilt from the coordinates rather than assumed from the
    /// request — a server is free to snap a range to its own cell edges, and a
    /// grid laid out by what was *asked for* rather than by what came back is a
    /// map of somewhere slightly else.
    ///
    /// Row 0 is north, as everywhere else here, so the latitudes are sorted
    /// downward whatever order the response arrived in.
    public static func parse(_ text: String, variable: String) throws -> ERDDAPGrid {
        // ERDDAP reports failure as a plain-text `Error { … }` document with a
        // perfectly ordinary status, so the shape of the body is what decides.
        if text.hasPrefix("Error") || text.hasPrefix("<") {
            let first = text.split(separator: "\n").prefix(3).joined(separator: " ")
            throw ERDDAPError.refused(String(first.prefix(200)))
        }

        var lines = text.split(whereSeparator: \.isNewline)
        guard lines.count > 2 else { throw ERDDAPError.noRows }

        let names = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let units = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let latColumn = names.firstIndex(of: "latitude"),
              let lonColumn = names.firstIndex(of: "longitude"),
              let valueColumn = names.firstIndex(of: variable) else {
            throw ERDDAPError.notAGrid("no latitude, longitude and \(variable) columns")
        }
        let timeColumn = names.firstIndex(of: "time")

        var byPosition: [Double: [Double: Double]] = [:]
        var latitudes = Set<Double>()
        var longitudes = Set<Double>()
        var time = ""

        for line in lines {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count > Swift.max(latColumn, Swift.max(lonColumn, valueColumn)) else { continue }
            guard let lat = Double(parts[latColumn]), let lon = Double(parts[lonColumn]) else { continue }
            // A missing sample arrives as an empty field or as NaN, and has to
            // stay missing: the tracer reads NaN as "no ground here", and a
            // zero would be a real and very cold temperature.
            let value = Double(parts[valueColumn]) ?? .nan
            latitudes.insert(lat)
            longitudes.insert(lon)
            byPosition[lat, default: [:]][lon] = value
            if time.isEmpty, let timeColumn, parts.count > timeColumn {
                time = String(parts[timeColumn])
            }
        }

        guard latitudes.count >= 2, longitudes.count >= 2 else {
            throw ERDDAPError.notAGrid("fewer than two rows or columns came back")
        }

        let sortedLats = latitudes.sorted(by: >)   // north first
        let sortedLons = longitudes.sorted()
        var values = ContiguousArray<Double>(repeating: .nan, count: sortedLats.count * sortedLons.count)
        for (row, lat) in sortedLats.enumerated() {
            let line = byPosition[lat] ?? [:]
            for (column, lon) in sortedLons.enumerated() {
                values[row * sortedLons.count + column] = line[lon] ?? .nan
            }
        }

        return ERDDAPGrid(
            field: Field2D(rows: sortedLats.count, columns: sortedLons.count, values: values),
            bounds: BoundingBox(
                minLon: sortedLons.first!, minLat: sortedLats.last!,
                maxLon: sortedLons.last!, maxLat: sortedLats.first!
            ),
            unit: valueColumn < units.count ? units[valueColumn] : "",
            time: time
        )
    }
}
