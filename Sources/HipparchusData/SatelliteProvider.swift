import Foundation
import HipparchusGeometry

/// Satellite ground tracks from live Celestrak element sets.
///
/// Ported from `data_sources/satellite_provider.py`.
///
/// The most Hipparchus-of-Nicaea layer in the app: where satellites actually pass
/// overhead, drawn as vector tracks with the circle of ground that can see them.
/// Element sets come from Celestrak over plain HTTPS with no key; propagation is
/// this app's own approximate Keplerian/J2 model, so it needs no dependency and
/// claims no ephemeris accuracy — which is why every feature it makes says
/// `approximate` rather than `measured`.

public enum SatelliteLayer {
    public static let tracks = "satellite_tracks"
    public static let footprints = "satellite_footprints"
    public static let all = [tracks, footprints]
}

/// Which satellites to draw, and how much of their path.
public struct SatelliteTrackSettings: Sendable {
    public var endpoint = "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle"
    /// Celestrak asks that clients cache, and a handful of satellites over a few
    /// orbits is all one sheet can carry legibly anyway.
    public var maxSatellites = 12
    public var windowMinutes = 200.0
    public var stepSeconds = 30.0
    public var footprintSegments = 72
    public var timeoutSeconds: TimeInterval = 30
    /// Draw only the satellites whose track actually crosses the area. Off by
    /// default, matching the Python: on a city-sized frame it would usually leave
    /// the layer empty, and an empty layer is not what someone ticking this wants.
    public var onlyOverhead = false

    public init() {}
}

public struct SatelliteTrackError: Error, CustomStringConvertible {
    public let underlying: String
    public var description: String { "satellite element sets could not be read: \(underlying)" }
}

public struct SatelliteTrackProvider: MapProvider {
    public let providerID = SourceID.satelliteTracks
    public let label = "Satellite Ground Tracks"
    public let provenance = Provenance.approximate

    public let settings: SatelliteTrackSettings
    private let http: any HTTPFetching
    private let cache: any CacheStoring
    private let now: @Sendable () -> Date

    public init(
        settings: SatelliteTrackSettings = SatelliteTrackSettings(),
        http: any HTTPFetching = URLSessionFetcher(),
        cache: any CacheStoring = MemoryCacheStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.http = http
        self.cache = cache
        self.now = now
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let satellites = try await elements()
        let start = now()

        var featuresByLayer: [String: [Feature]] = [
            SatelliteLayer.tracks: [],
            SatelliteLayer.footprints: [],
        ]

        for (index, satellite) in satellites.prefix(Swift.max(1, settings.maxSatellites)).enumerated() {
            let runs = Orbits.groundTrack(
                of: satellite,
                start: start,
                minutes: settings.windowMinutes,
                stepSeconds: settings.stepSeconds
            )
            guard !runs.isEmpty else { continue }

            if settings.onlyOverhead,
               !runs.contains(where: { $0.contains { query.bbox.bounds.contains($0.coordinate) } }) {
                continue
            }

            for (runIndex, run) in runs.enumerated() {
                featuresByLayer[SatelliteLayer.tracks]?.append(
                    trackFeature(satellite, run: run, index: index, runIndex: runIndex)
                )
            }

            // The footprint is where the satellite is *now*, not where it will be.
            let position = Orbits.subpoint(of: satellite, at: start)
            featuresByLayer[SatelliteLayer.footprints]?.append(
                footprintFeature(satellite, position: position, index: index)
            )
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "format": .string("celestrak_tle"),
                "satellite_count": .int(featuresByLayer[SatelliteLayer.footprints]?.count ?? 0),
                "window_minutes": .double(settings.windowMinutes),
                // This is not SGP4, and a map that implies otherwise is a lie.
                "propagator": .string("keplerian_j2_secular"),
                "accuracy_note": .string(
                    "approximate: a few kilometres over a few hours, degrading over days"
                ),
            ],
            bbox: query.bbox,
            provenance: .approximate
        )
    }

    // MARK: -

    private func elements() async throws -> [TwoLineElements] {
        let key = "celestrak:\(settings.endpoint)"
        if let cached = await cache.data(for: key) {
            return TwoLineElements.parseListing(String(decoding: cached, as: UTF8.self))
        }

        guard let url = URL(string: settings.endpoint) else {
            throw SatelliteTrackError(underlying: "bad endpoint")
        }
        let data: Data
        do {
            data = try await http.data(from: url, timeout: settings.timeoutSeconds)
        } catch {
            throw SatelliteTrackError(underlying: String(describing: error))
        }

        let parsed = TwoLineElements.parseListing(String(decoding: data, as: UTF8.self))
        guard !parsed.isEmpty else {
            throw SatelliteTrackError(underlying: "the listing held no readable element sets")
        }
        await cache.store(data, for: key)
        return parsed
    }

    private func trackFeature(
        _ satellite: TwoLineElements,
        run: [SubPoint],
        index: Int,
        runIndex: Int
    ) -> Feature {
        let altitudes = run.map(\.altitudeKm)
        return Feature(
            id: "\(providerID)/track/\(satellite.catalogNumber)/\(runIndex)",
            layer: SatelliteLayer.tracks,
            source: providerID,
            geometry: .lineString(LineString(run.map(\.coordinate))),
            provenance: .approximate,
            properties: [
                // Only the first run of a satellite is named, or a track split at
                // the antimeridian gets labelled twice.
                "name": .string(runIndex == 0 ? satellite.name : ""),
                "catalog_number": .string(satellite.catalogNumber),
                "period_minutes": .double(satellite.periodMinutes),
                "inclination_deg": .double(satellite.inclinationDegrees),
                "altitude_km": .double(altitudes.reduce(0, +) / Double(Swift.max(1, altitudes.count))),
            ]
        )
    }

    private func footprintFeature(
        _ satellite: TwoLineElements,
        position: SubPoint,
        index: Int
    ) -> Feature {
        let radius = Orbits.horizonRadiusDegrees(altitudeKm: position.altitudeKm)
        // Built unwrapped and then divided: a footprint over the date line
        // belongs against both edges of the sheet, not stretched between them.
        let pieces = Orbits.splitAtAntimeridian(smallCircle(
            centre: position.coordinate,
            radiusDegrees: radius,
            segments: settings.footprintSegments
        )).map { Polygon(exterior: $0) }
        return Feature(
            id: "\(providerID)/footprint/\(satellite.catalogNumber)",
            layer: SatelliteLayer.footprints,
            source: providerID,
            geometry: pieces.count == 1
                ? .polygon(pieces[0])
                : .multiPolygon(pieces),
            provenance: .approximate,
            properties: [
                "name": .string(""),
                "catalog_number": .string(satellite.catalogNumber),
                "satellite": .string(satellite.name),
                "altitude_km": .double(position.altitudeKm),
                "horizon_radius_deg": .double(radius),
            ]
        )
    }

    /// A circle of constant angular radius on the sphere.
    ///
    /// Not a circle in degrees: at 60° north a degree of longitude is half a degree
    /// of latitude, and an uncorrected ring would draw the footprint as an ellipse.
    /// Latitude is clamped at the poles rather than allowed to fold over the top.
    ///
    /// **Longitude is left unwrapped**, running continuously past ±180°, because
    /// wrapping each vertex on its own turns a ring over the date line into a
    /// band across the whole map. `Orbits.splitAtAntimeridian` divides it after.
    func smallCircle(centre: Coordinate, radiusDegrees: Double, segments: Int) -> [Coordinate] {
        let cosLat = Swift.max(0.05, cos(Swift.min(Swift.max(centre.lat, -89.9), 89.9) * .pi / 180))
        return (0..<Swift.max(8, segments)).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(Swift.max(8, segments))
            let lat = Swift.min(Swift.max(centre.lat + radiusDegrees * sin(angle), -90), 90)
            // Half a world either side, at most. Near the pole the `cosLat`
            // divisor runs away — at 88° a 20° radius asks for 573° of longitude
            // — and a satellite that high over the pole genuinely sees every
            // meridian, so a full band is the honest answer and anything wider
            // is arithmetic rather than geography.
            let offset = Swift.min(Swift.max(radiusDegrees * cos(angle) / cosLat, -180), 180)
            return Coordinate(lon: centre.lon + offset, lat: lat)
        }
    }
}
