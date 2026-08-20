import Foundation
import HipparchusGeometry

/// What a source is, declared by the source itself.
///
/// Ported from the provenance flags the Python carries on features, on merged
/// collection metadata, on the scene and in the exported diagnostics JSON.
///
/// This is an honesty guarantee, not decoration. It is what stops a generated map
/// being mistaken for a survey, and every new source needs it. The Python's
/// `NextStepsClaude.md` says the existing assertions should not be relaxed; they
/// are not relaxed here.
public enum Provenance: String, Sendable, Codable, CaseIterable {
    /// Real instrument data. Terrain tiles, USGS events.
    case measured
    /// Generated. The procedural relief field.
    case synthetic
    /// Real, but not calibrated to physical units. GIBS night lights is rendered
    /// picture brightness, not radiance, and saturates over city cores.
    case uncalibrated
    /// A model good enough to draw with, and no more. Keplerian orbits with J2
    /// secular drift — fine for a ground track, not for a conjunction.
    case approximate

    /// How it reads on a source row in the interface.
    public var label: String { rawValue }

    /// Merging several sources takes the weakest claim any of them makes, because
    /// a map is only as trustworthy as its least trustworthy layer.
    public static func merged(_ values: some Sequence<Provenance>) -> Provenance? {
        let ranking: [Provenance] = [.approximate, .synthetic, .uncalibrated, .measured]
        return values.min { a, b in
            (ranking.firstIndex(of: a) ?? 0) < (ranking.firstIndex(of: b) ?? 0)
        }
    }
}

/// A heterogeneous property value, the typed stand-in for the Python's
/// `dict[str, Any]` feature properties.
public enum PropertyValue: Sendable, Equatable, Codable {
    case string(String)
    case double(Double)
    case int(Int)
    case bool(Bool)

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .double(let value): return String(value)
        case .int(let value): return String(value)
        case .bool(let value): return String(value)
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// One thing on the map.
public struct Feature: Sendable, Equatable {
    /// Stable within a fetch, and carried into the exported SVG so a path can be
    /// traced back to what produced it.
    public let id: String
    public let layer: String
    public let source: String
    public let geometry: Geometry
    public let provenance: Provenance
    public let properties: [String: PropertyValue]

    public init(
        id: String,
        layer: String,
        source: String,
        geometry: Geometry,
        provenance: Provenance,
        properties: [String: PropertyValue] = [:]
    ) {
        self.id = id
        self.layer = layer
        self.source = source
        self.geometry = geometry
        self.provenance = provenance
        self.properties = properties
    }

    public func property(_ key: String) -> PropertyValue? { properties[key] }
}

/// A bounding-box request in WGS84.
public struct BBoxQuery: Sendable, Equatable {
    public let bbox: BoundingBox
    /// Which layers the caller actually wants. A provider that cannot narrow its
    /// request may ignore this, but it must not pretend it honoured it.
    public let layers: Set<String>

    public init(bbox: BoundingBox, layers: Set<String> = []) {
        self.bbox = bbox
        self.layers = layers
    }

    public init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double, layers: Set<String> = []) {
        self.init(bbox: BoundingBox(minLon: minLon, minLat: minLat, maxLon: maxLon, maxLat: maxLat), layers: layers)
    }
}

/// The normalised payload every provider returns.
public struct FeatureCollection: Sendable {
    public var featuresByLayer: [String: [Feature]]
    public var metadata: [String: PropertyValue]
    public var bbox: BoundingBox?
    /// The weakest claim any layer in the collection makes.
    public var provenance: Provenance?

    public init(
        featuresByLayer: [String: [Feature]] = [:],
        metadata: [String: PropertyValue] = [:],
        bbox: BoundingBox? = nil,
        provenance: Provenance? = nil
    ) {
        self.featuresByLayer = featuresByLayer
        self.metadata = metadata
        self.bbox = bbox
        self.provenance = provenance ?? Provenance.merged(featuresByLayer.values.flatMap { $0 }.map(\.provenance))
    }

    public var layerNames: [String] { featuresByLayer.keys.sorted() }
    public var featureCount: Int { featuresByLayer.values.reduce(0) { $0 + $1.count } }

    public func features(in layer: String) -> [Feature] { featuresByLayer[layer] ?? [] }
}

/// A source of map data.
public protocol MapProvider: Sendable {
    var providerID: String { get }
    var label: String { get }
    /// What this source is. Declared here so it cannot be forgotten at the point
    /// features are built.
    var provenance: Provenance { get }

    func fetch(_ query: BBoxQuery) async throws -> FeatureCollection
}

/// The fetch was cancelled.
///
/// Worth being precise about, because the word promises more than any client can
/// deliver: a request already in flight cannot be pulled out of its socket.
/// Cancelling skips sources that have not started, stops sources that check
/// between requests, and discards the result of whatever is still running rather
/// than drawing it. An HTTP request already sent runs to completion.
public struct FetchCancelled: Error, CustomStringConvertible {
    public let source: String

    public init(source: String) {
        self.source = source
    }

    public var description: String { "\(source) fetch cancelled" }
}

// MARK: - HTTP

/// The seam every network test goes through.
///
/// Providers take one of these rather than reaching for `URLSession` directly, so
/// the whole suite runs offline with no fixtures on disk — the same arrangement
/// the Python uses with its injectable `http_get`.
public protocol HTTPFetching: Sendable {
    func data(from url: URL, timeout: TimeInterval) async throws -> Data

    /// Overpass takes its query in a form-encoded body, and a query for a city with
    /// every layer is far too long for a URL. Defaulted so the many GET-only stubs
    /// in the suite do not each have to refuse it by hand.
    func post(
        _ body: [String: String],
        to url: URL,
        timeout: TimeInterval
    ) async throws -> Data
}

extension HTTPFetching {
    public func post(_ body: [String: String], to url: URL, timeout: TimeInterval) async throws -> Data {
        throw HTTPError(url: url, underlying: "this fetcher does not support POST")
    }
}

public struct HTTPError: Error, CustomStringConvertible {
    public let url: URL
    public let statusCode: Int?
    public let underlying: String?

    public init(url: URL, statusCode: Int? = nil, underlying: String? = nil) {
        self.url = url
        self.statusCode = statusCode
        self.underlying = underlying
    }

    public var description: String {
        if let statusCode {
            return "HTTP \(statusCode) from \(url.absoluteString)"
        }
        return "request to \(url.absoluteString) failed: \(underlying ?? "unknown")"
    }
}

public struct URLSessionFetcher: HTTPFetching {
    public static let userAgent = "HipparchusMac/0.1 (native map generator)"

    /// Whether this process was told to stay off the network, read once from its
    /// own launch arguments.
    ///
    /// **A launch flag rather than an injected setting, because the thing being
    /// fixed is an injection nobody performed.** Every provider in this module
    /// takes an `HTTPFetching` and defaults it to this type, so a guard here is
    /// the one place that covers all of them without twelve call sites having to
    /// remember. A run that wants the real network simply does not pass
    /// `--offline`.
    ///
    /// **It covers this application's own fetching and nothing else.** MapKit is
    /// not affected and cannot be from in here: the Locator holds a live
    /// `MKMapView`, which fetches its tiles by routes inside the framework.
    /// Saying otherwise is exactly the mistake this replaces — the UI tests
    /// carried a `HIPPARCHUS_UI_TESTS` variable documented as making the run
    /// offline, which nothing read, for as long as they have existed.
    public static let launchedOffline = ProcessInfo.processInfo.arguments.contains("--offline")

    private let session: URLSession
    private let isOffline: Bool

    public init(session: URLSession = .shared, isOffline: Bool = URLSessionFetcher.launchedOffline) {
        self.session = session
        self.isOffline = isOffline
    }

    /// Fails before the request is built, so an offline run cannot be slow.
    private func refuseIfOffline(_ url: URL) throws {
        guard isOffline else { return }
        throw HTTPError(
            url: url,
            underlying: "refused: this process was launched with --offline"
        )
    }

    public func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        try refuseIfOffline(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // Public tile and API endpoints ask for an identifying agent, and some
        // reject the default.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(url: url, statusCode: http.statusCode)
        }
        return data
    }

    public func post(_ body: [String: String], to url: URL, timeout: TimeInterval) async throws -> Data {
        try refuseIfOffline(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(
            body
                .map { "\($0.key)=\(Self.formEncoded($0.value))" }
                .joined(separator: "&")
                .utf8
        )

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError(url: url, statusCode: http.statusCode)
        }
        return data
    }

    /// `application/x-www-form-urlencoded`, which is not the same as percent-encoding
    /// a URL path: a literal `+` must survive, and a space becomes `%20` rather than
    /// `+` so an Overpass query body reads back exactly as it was written.
    static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
