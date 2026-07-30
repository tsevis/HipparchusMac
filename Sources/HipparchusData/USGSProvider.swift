import Foundation
import HipparchusGeometry

/// Live seismicity from the USGS FDSN event service.
///
/// Ported from `data_sources/usgs_provider.py`.
///
/// The first source that draws *measured* geophysics: real recorded earthquakes for
/// the area on screen, fetched over HTTPS with no key and no account. Events arrive
/// as GeoJSON points, which nothing in the renderer can draw, so each becomes a
/// circle scaled by magnitude — editable vector artwork rather than a symbol font.
///
/// Events are split into the standard depth classes so the SVG carries them as
/// separate groups, and so depth reads through styling instead of being buried in a
/// property nobody sees.

public enum EarthquakeLayer {
    public static let shallow = "earthquakes_shallow"
    public static let intermediate = "earthquakes_intermediate"
    public static let deep = "earthquakes_deep"
    public static let all = [shallow, intermediate, deep]

    /// Seismological depth classes, in kilometres.
    public static let intermediateDepthKm = 70.0
    public static let deepDepthKm = 300.0

    public static func forDepth(_ depthKm: Double) -> String {
        if depthKm < intermediateDepthKm { return shallow }
        if depthKm < deepDepthKm { return intermediate }
        return deep
    }
}

/// What to ask the catalogue for, and how big to draw the answer.
public struct SeismicitySettings: Sendable {
    public var endpoint = "https://earthquake.usgs.gov/fdsnws/event/1/query"
    /// A single month of events leaves a city map empty; a few years of everything
    /// above the noise floor makes a map worth drawing.
    public var days = 1825
    public var minMagnitude = 2.5
    public var limit = 2000
    public var timeoutSeconds: TimeInterval = 30

    /// Circle radius as a fraction of the area's shorter side, so symbols stay
    /// legible whether the window is a city or a subduction zone.
    public var baseRadiusFraction = 0.005
    public var radiusGrowth = 1.55
    public var referenceMagnitude = 3.0
    public var maxRadiusFraction = 0.09
    /// Below this an event is drawn but not named — otherwise a swarm of small
    /// events buries the map in text.
    public var labelMinMagnitude = 4.0

    public init() {}
}

public struct SeismicityRequestError: Error, CustomStringConvertible {
    public let underlying: String
    public var description: String { "USGS event request failed: \(underlying)" }
}

public struct USGSEarthquakeProvider: MapProvider {
    public let providerID = SourceID.usgsEarthquakes
    public let label = "Live Earthquakes (USGS)"
    public let provenance = Provenance.measured

    public let settings: SeismicitySettings
    private let http: any HTTPFetching
    /// Injected so a test can pin the request window; production passes the clock.
    private let now: @Sendable () -> Date

    public init(
        settings: SeismicitySettings = SeismicitySettings(),
        http: any HTTPFetching = URLSessionFetcher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.http = http
        self.now = now
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        guard let url = requestURL(for: query) else {
            throw SeismicityRequestError(underlying: "could not build the request URL")
        }

        let data: Data
        do {
            data = try await http.data(from: url, timeout: settings.timeoutSeconds)
        } catch {
            throw SeismicityRequestError(underlying: String(describing: error))
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let events = payload?["features"] as? [[String: Any]] ?? []

        var featuresByLayer: [String: [Feature]] = [:]
        for layer in EarthquakeLayer.all { featuresByLayer[layer] = [] }

        let span = radiusSpan(query.bbox)
        var strongest = 0.0
        var counted = 0

        for event in events {
            guard let feature = self.feature(from: event, span: span, index: counted) else { continue }
            featuresByLayer[feature.layer, default: []].append(feature)
            strongest = Swift.max(strongest, feature.property("magnitude")?.doubleValue ?? 0)
            counted += 1
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: [
                "source": .string(providerID),
                "format": .string("usgs_fdsn_geojson"),
                "event_count": .int(counted),
                "strongest_magnitude": .double(strongest),
                "window_days": .int(settings.days),
                "min_magnitude": .double(settings.minMagnitude),
                // The catalogue was cut off, so the map is a sample rather than a
                // census, and saying so is the difference between the two.
                "truncated": .bool(counted >= settings.limit),
            ],
            bbox: query.bbox,
            provenance: .measured
        )
    }

    // MARK: -

    func requestURL(for query: BBoxQuery) -> URL? {
        let end = now()
        let start = end.addingTimeInterval(-Double(Swift.max(1, settings.days)) * 86400)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var components = URLComponents(string: settings.endpoint)
        components?.queryItems = [
            URLQueryItem(name: "format", value: "geojson"),
            URLQueryItem(name: "minlongitude", value: String(format: "%.6f", query.bbox.minLon)),
            URLQueryItem(name: "maxlongitude", value: String(format: "%.6f", query.bbox.maxLon)),
            URLQueryItem(name: "minlatitude", value: String(format: "%.6f", query.bbox.minLat)),
            URLQueryItem(name: "maxlatitude", value: String(format: "%.6f", query.bbox.maxLat)),
            URLQueryItem(name: "starttime", value: formatter.string(from: start)),
            URLQueryItem(name: "endtime", value: formatter.string(from: end)),
            URLQueryItem(name: "minmagnitude", value: trimmed(settings.minMagnitude)),
            URLQueryItem(name: "limit", value: String(Swift.max(1, settings.limit))),
            // Strongest first, so a truncated answer keeps the events that matter.
            URLQueryItem(name: "orderby", value: "magnitude"),
        ]
        return components?.url
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func feature(from event: [String: Any], span: Double, index: Int) -> Feature? {
        guard let geometry = event["geometry"] as? [String: Any],
              let coordinates = geometry["coordinates"] as? [Any],
              coordinates.count >= 2,
              let lon = (coordinates[0] as? NSNumber)?.doubleValue,
              let lat = (coordinates[1] as? NSNumber)?.doubleValue
        else {
            return nil
        }
        // USGS reports depth in kilometres as the third ordinate.
        let depthKm = coordinates.count > 2 ? ((coordinates[2] as? NSNumber)?.doubleValue ?? 0) : 0

        let properties = event["properties"] as? [String: Any] ?? [:]
        guard let magnitude = (properties["mag"] as? NSNumber)?.doubleValue, magnitude.isFinite else {
            return nil
        }

        let place = (properties["place"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let layer = EarthquakeLayer.forDepth(depthKm)
        let ring = circleRing(lon: lon, lat: lat, radiusDegrees: radius(for: magnitude, span: span))

        return Feature(
            id: (event["id"] as? String) ?? "\(providerID)/\(index)",
            layer: layer,
            source: providerID,
            geometry: .polygon(Polygon(exterior: ring)),
            provenance: .measured,
            properties: [
                // `name` is what the label pass reads, so only events worth naming
                // carry one.
                "name": .string(magnitude >= settings.labelMinMagnitude
                    ? String(format: "M %.1f", magnitude) : ""),
                "magnitude": .double(magnitude),
                "depth_km": .double(depthKm),
                "place": .string(place),
                "event_time": .string(isoTime(properties["time"])),
                "url": .string((properties["url"] as? String) ?? ""),
            ]
        )
    }

    func radius(for magnitude: Double, span: Double) -> Double {
        let steps = Swift.max(0, magnitude - settings.referenceMagnitude)
        let fraction = settings.baseRadiusFraction * pow(settings.radiusGrowth, steps)
        return span * Swift.min(fraction, settings.maxRadiusFraction)
    }

    /// Shorter side of the window, in degrees of latitude.
    func radiusSpan(_ bbox: BoundingBox) -> Double {
        let meanLat = Swift.min(Swift.max((bbox.minLat + bbox.maxLat) / 2, -89.9), 89.9)
        let lonSpan = abs(bbox.maxLon - bbox.minLon) * cos(meanLat * .pi / 180)
        let latSpan = abs(bbox.maxLat - bbox.minLat)
        let spans = [lonSpan, latSpan].filter { $0 > 0 }
        return spans.min() ?? 1.0
    }

    /// A closed ring that is round *on the map*, not round in degrees.
    ///
    /// A degree of longitude is shorter than a degree of latitude everywhere but the
    /// equator, so an uncorrected buffer would draw every epicentre as an ellipse
    /// that flattens as the map moves north.
    func circleRing(lon: Double, lat: Double, radiusDegrees: Double, segments: Int = 48) -> [Coordinate] {
        let cosLat = Swift.max(0.05, cos(Swift.min(Swift.max(lat, -89.9), 89.9) * .pi / 180))
        return (0..<segments).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(segments)
            return Coordinate(
                lon: lon + radiusDegrees * cos(angle) / cosLat,
                lat: lat + radiusDegrees * sin(angle)
            )
        }
    }

    /// USGS reports event time as epoch milliseconds.
    private func isoTime(_ value: Any?) -> String {
        guard let milliseconds = (value as? NSNumber)?.doubleValue else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
