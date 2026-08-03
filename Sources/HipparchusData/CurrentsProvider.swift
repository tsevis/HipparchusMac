import Foundation
import HipparchusGeometry

/// Surface currents, drawn as streamlines rather than animated as particles.
///
/// The brief that asked for this assumed CMEMS and a prepared file, because its
/// toolbox is Python and this application cannot run Python. **That was reasoning
/// rather than checking**, twice over: NOAA publishes global geostrophic
/// velocities through the same ERDDAP the sea surface temperature comes from, as
/// `ugos` and `vgos` on a 0.25° lattice, and both components arrive in one CSV.
/// So a current costs one round trip and no new network path at all.
///
/// What it does need is an integrator, and that is `Streamlines.swift`.
public struct CurrentsSettings: Sendable {
    public var dataset = ERDDAPDataset(
        server: "https://coastwatch.pfeg.noaa.gov/erddap",
        datasetID: "nesdisSSH1day",
        variable: "ugos",
        layerPrefix: "current",
        unit: "m s-1",
        nominalResolution: 0.25
    )
    /// The northward half. The eastward half is the dataset's own `variable`.
    public var northwardVariable = "vgos"
    public var streamlines = StreamlineSettings()
    public var targetSamples = 160
    public var timeoutSeconds: TimeInterval = 45
    /// Weight bands along a line. A streamline drawn at one width says where the
    /// water goes; one that thickens where the water runs says how fast, which
    /// is the other half of what a current chart is for.
    public var speedBands = 5
    /// The thinnest and thickest a streamline gets, as multiples of the layer's
    /// own stroke.
    public var minStrokeScale = 0.45
    public var maxStrokeScale = 2.2

    public init() {}
}

public let currentsProviderID = "erddap_current"

public struct CurrentsProvider: MapProvider {
    public let providerID = currentsProviderID
    public let label = "Surface currents"
    /// Geostrophic velocity is derived from measured sea surface height rather
    /// than measured directly, and it is a model of the flow good enough to draw
    /// — which is what `approximate` means here and is why it is not `measured`.
    public let provenance = Provenance.approximate

    public let settings: CurrentsSettings
    private let http: any HTTPFetching

    public init(settings: CurrentsSettings = CurrentsSettings(), http: any HTTPFetching = URLSessionFetcher()) {
        self.settings = settings
        self.http = http
    }

    public static let layer = "current_streamlines"

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let client = ERDDAPClient(
            dataset: settings.dataset,
            targetSamples: settings.targetSamples,
            timeoutSeconds: settings.timeoutSeconds,
            http: http
        )
        let (east, north) = try await client.vectorGrid(
            for: query.bbox, second: settings.northwardVariable
        )
        let bounds = east.bounds
        let rows = east.field.rows
        let columns = east.field.columns
        guard rows > 1, columns > 1 else {
            throw ERDDAPError.notAGrid("the current field came back smaller than two cells")
        }

        let cellLat = (bounds.maxLat - bounds.minLat) / Double(rows - 1)
        let cellLon = (bounds.maxLon - bounds.minLon) / Double(columns - 1)

        let lines = streamlines(
            u: east.field, v: north.field,
            cellLonDegrees: cellLon, cellLatDegrees: cellLat,
            latitudeForRow: { bounds.maxLat - $0 * cellLat },
            settings: settings.streamlines
        )

        let speeds = lines.flatMap { $0.map(\.speed) }.filter(\.isFinite)
        let fastest = speeds.max() ?? 0
        let slowest = speeds.min() ?? 0

        var features: [Feature] = []
        for (index, line) in lines.enumerated() {
            for run in Self.runs(of: line, bands: settings.speedBands, slowest: slowest, fastest: fastest) {
                let coordinates = run.points.map { point in
                    Coordinate(
                        lon: bounds.minLon + point.column * cellLon,
                        lat: bounds.maxLat - point.row * cellLat
                    )
                }
                guard coordinates.count >= 2 else { continue }
                let scale = settings.minStrokeScale
                    + (settings.maxStrokeScale - settings.minStrokeScale) * run.fraction
                features.append(Feature(
                    id: "\(providerID)/\(Self.layer)/\(index)/\(features.count)",
                    layer: Self.layer,
                    source: providerID,
                    geometry: .lineString(LineString(coordinates)),
                    provenance: .approximate,
                    properties: [
                        "speed": .double(run.speed),
                        "unit": .string(east.unit),
                        // Read by the scene builder as a multiplier on the
                        // layer's stroke, which is how a streamline thickens
                        // where the water runs.
                        "stroke_scale": .double(scale),
                    ]
                ))
            }
        }

        return FeatureCollection(
            featuresByLayer: [Self.layer: features],
            metadata: [
                "source": .string(providerID),
                "provenance": .string(Provenance.approximate.rawValue),
                "erddap_dataset": .string(settings.dataset.datasetID),
                "erddap_time": .string(east.time),
                "current_unit": .string(east.unit),
                "current_max": .double(fastest),
                "streamline_count": .int(lines.count),
                "grid_rows": .int(rows),
                "grid_columns": .int(columns),
            ],
            bbox: bounds,
            provenance: .approximate
        )
    }

    struct Run {
        let points: [StreamlinePoint]
        let speed: Double
        /// Where this run's speed sits between the slowest and fastest water on
        /// the sheet, 0…1.
        let fraction: Double
    }

    /// Split a streamline where its speed crosses a band edge.
    ///
    /// One feature per run, because a stroke width belongs to a feature — which
    /// is the same shape the illuminated contours already take, and it means the
    /// renderer needs to know nothing new. Runs overlap by one vertex so the
    /// line has no gaps at the joins.
    static func runs(
        of line: [StreamlinePoint], bands: Int, slowest: Double, fastest: Double
    ) -> [Run] {
        guard line.count >= 2, bands >= 1 else { return [] }
        let span = fastest - slowest
        func band(_ speed: Double) -> Int {
            guard span > 0 else { return 0 }
            let position = (speed - slowest) / span
            return Swift.min(bands - 1, Swift.max(0, Int(position * Double(bands))))
        }

        var out: [Run] = []
        var current: [StreamlinePoint] = [line[0]]
        var currentBand = band(line[0].speed)

        for point in line.dropFirst() {
            let next = band(point.speed)
            if next == currentBand {
                current.append(point)
                continue
            }
            // Overlap by one, so the runs meet rather than leaving a hairline
            // of paper between them.
            current.append(point)
            out.append(Self.run(current, band: currentBand, bands: bands))
            current = [point]
            currentBand = next
        }
        if current.count >= 2 {
            out.append(Self.run(current, band: currentBand, bands: bands))
        }
        return out
    }

    private static func run(_ points: [StreamlinePoint], band: Int, bands: Int) -> Run {
        let speeds = points.map(\.speed)
        let mean = speeds.reduce(0, +) / Double(Swift.max(1, speeds.count))
        let fraction = bands > 1 ? Double(band) / Double(bands - 1) : 0
        return Run(points: points, speed: mean, fraction: fraction)
    }
}
