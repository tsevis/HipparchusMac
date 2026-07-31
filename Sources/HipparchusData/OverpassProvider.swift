import Foundation
import HipparchusGeometry

/// The OpenStreetMap source: streets, buildings, water, places.
///
/// Ported from `data_sources/overpass_provider.py`.
///
/// **Overpass dominates fetch time.** A 0.32° area with every layer took 331 s in
/// the Python, of which 325 s was this source and 5 s was elevation. Three things
/// follow, and all three are here: ask only for the layers wanted, cache the answer
/// so the same area is never paid for twice, and warn before a fetch that will take
/// minutes.
///
/// The public instances are shared and unmetered, so this rate-limits itself, backs
/// off between attempts and falls through to mirrors rather than hammering one host.
public struct OverpassSettings: Sendable {
    public var endpoint = "https://overpass-api.de/api/interpreter"
    /// Mirrors, tried in turn within each attempt.
    public var fallbackEndpoints = [
        "https://lz4.overpass-api.de/api/interpreter",
        "https://z.overpass-api.de/api/interpreter",
        "https://overpass.kumi.systems/api/interpreter",
    ]
    public var timeoutSeconds: TimeInterval = 60
    public var maxRetries = 3
    public var baseRetryDelay: Duration = .seconds(1)
    public var requestsPerSecond = 1.0
    /// Which layers to ask for. Empty means all of them, which is the slow path.
    public var layers: Set<String> = []

    public init() {}

    /// Every endpoint to try, in order, without duplicates or blanks.
    public var candidateEndpoints: [String] {
        var seen: [String] = []
        for endpoint in [endpoint] + fallbackEndpoints {
            let cleaned = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !seen.contains(cleaned) { seen.append(cleaned) }
        }
        return seen
    }
}

/// A fixed minimum interval between requests, shared across every caller.
///
/// An actor because that is exactly what this is: one piece of mutable state that
/// several concurrent fetches have to agree on.
public actor RateLimiter {
    private let minimumInterval: Duration
    private var lastRequest: ContinuousClock.Instant?

    public init(requestsPerSecond: Double) {
        let rate = Swift.max(requestsPerSecond, 0.001)
        self.minimumInterval = .seconds(1.0 / rate)
    }

    public func waitTurn() async {
        let now = ContinuousClock.now

        // The slot is claimed *before* sleeping, not after waking.
        //
        // `await` releases the actor, so callers that read the same
        // `lastRequest` before any of them slept would all compute the same
        // delay, wake together and fire at once — the limiter spacing nothing
        // precisely when several fetches run concurrently, which is the case it
        // exists for. Reserving first hands each caller its own slot.
        let slot: ContinuousClock.Instant
        if let lastRequest, lastRequest + minimumInterval > now {
            slot = lastRequest + minimumInterval
        } else {
            slot = now
        }
        lastRequest = slot

        if slot > now {
            try? await Task.sleep(until: slot, clock: ContinuousClock())
        }
    }
}

public struct OverpassRequestError: Error, CustomStringConvertible {
    public let attempts: Int
    public let endpoints: Int
    public let lastError: String

    public var description: String {
        "Overpass request failed after \(attempts) attempts across \(endpoints) endpoints: \(lastError)"
    }
}

public struct OverpassProvider: MapProvider {
    public let providerID = SourceID.overpass
    public let label = "OpenStreetMap"
    public let provenance = Provenance.measured

    public let settings: OverpassSettings
    private let http: any HTTPFetching
    private let cache: any CacheStoring
    private let limiter: RateLimiter

    public init(
        settings: OverpassSettings = OverpassSettings(),
        http: any HTTPFetching = URLSessionFetcher(),
        cache: any CacheStoring = MemoryCacheStore()
    ) {
        self.settings = settings
        self.http = http
        self.cache = cache
        self.limiter = RateLimiter(requestsPerSecond: settings.requestsPerSecond)
    }

    public func fetch(_ query: BBoxQuery) async throws -> FeatureCollection {
        let request = resolved(query)
        let key = Self.cacheKey(request)

        if let cached = await cache.data(for: key) {
            var collection = try OverpassDecode.featureCollection(from: cached, bbox: request.bbox)
            collection.metadata["cache"] = .string("hit")
            return collection
        }

        let payload = try await execute(OverpassQuery.build(request, timeoutSeconds: Int(settings.timeoutSeconds)))
        await cache.store(payload, for: key)

        var collection = try OverpassDecode.featureCollection(from: payload, bbox: request.bbox)
        collection.metadata["cache"] = .string("miss")
        return collection
    }

    /// The query actually sent: the caller's layers, or the provider's own if the
    /// caller did not narrow it.
    private func resolved(_ query: BBoxQuery) -> BBoxQuery {
        guard query.layers.isEmpty, !settings.layers.isEmpty else { return query }
        return BBoxQuery(bbox: query.bbox, layers: settings.layers)
    }

    /// Try every endpoint within an attempt, then back off and try again.
    ///
    /// Cancellation is checked between attempts, which is the granularity the app
    /// promises: a request already sent runs to completion, but the next one is
    /// never made.
    private func execute(_ queryText: String) async throws -> Data {
        var lastError = "unknown"
        let endpoints = settings.candidateEndpoints

        for attempt in 1...Swift.max(1, settings.maxRetries) {
            for endpoint in endpoints {
                try Task.checkCancellation()
                guard let url = URL(string: endpoint) else {
                    lastError = "bad endpoint \(endpoint)"
                    continue
                }
                await limiter.waitTurn()
                do {
                    return try await http.post(
                        ["data": queryText], to: url, timeout: settings.timeoutSeconds
                    )
                } catch {
                    lastError = String(describing: error)
                }
            }

            guard attempt < settings.maxRetries else { break }
            try Task.checkCancellation()
            // Exponential: 1 s, 2 s, 4 s. A busy public instance answers a retry far
            // more often than it answers an immediate repeat.
            try? await Task.sleep(for: settings.baseRetryDelay * Int(pow(2.0, Double(attempt - 1))))
        }

        throw OverpassRequestError(
            attempts: Swift.max(1, settings.maxRetries),
            endpoints: endpoints.count,
            lastError: lastError
        )
    }

    static func cacheKey(_ query: BBoxQuery) -> String {
        let bbox = String(
            format: "%.6f,%.6f,%.6f,%.6f",
            query.bbox.minLon, query.bbox.minLat, query.bbox.maxLon, query.bbox.maxLat
        )
        return "overpass:bbox:\(bbox):layers:\(query.layers.sorted().joined(separator: ","))"
    }
}

// MARK: - Fetch cost

/// How long a fetch is likely to take, and whether to say so first.
///
/// Kickoff detail 13: Overpass took 325 s of a 331 s fetch for a 0.32° area with
/// every layer. A warning before that wait is the difference between a slow app and
/// a broken-looking one.
public enum FetchCost {
    /// Degrees squared beyond which a full-layer Overpass fetch is worth warning
    /// about. The measured 0.32° x 0.32° area is 0.1 square degrees and took five
    /// and a half minutes.
    public static let warnAboveSquareDegrees = 0.08

    public static func shouldWarn(bbox: BoundingBox, layers: Set<String>) -> Bool {
        let area = abs(bbox.maxLon - bbox.minLon) * abs(bbox.maxLat - bbox.minLat)
        guard area >= warnAboveSquareDegrees else { return false }
        // A narrowed request is a different proposition: most of the time in that
        // measurement went on layers nobody had asked for.
        return layers.isEmpty || layers.count > 6
    }

    public static func warning(bbox: BoundingBox) -> String {
        let area = abs(bbox.maxLon - bbox.minLon) * abs(bbox.maxLat - bbox.minLat)
        let minutes = Swift.max(1, Int((area / 0.1 * 5.5).rounded()))
        return """
        This area is large enough that OpenStreetMap may take around \(minutes) \
        minute\(minutes == 1 ? "" : "s") to answer. Fewer layers, or a smaller area, \
        will be much faster.
        """
    }

    /// Beyond this, OpenStreetMap is refused outright rather than merely warned
    /// about. A locator that can be panned to the whole world makes it an easy
    /// accident to ask for the entire planet, and past a few hundred square
    /// degrees — comfortably more than a large country — there is no
    /// legitimate single query left, only one the shared public service
    /// should not be asked to try. `warning(bbox:)`'s own linear estimate
    /// would otherwise answer with something like "3,366,000 minutes," which
    /// reads as broken rather than as the plain "no" this is instead.
    public static let refuseAboveSquareDegrees = 300.0

    public static func isTooLargeToFetch(bbox: BoundingBox) -> Bool {
        let area = abs(bbox.maxLon - bbox.minLon) * abs(bbox.maxLat - bbox.minLat)
        return area > refuseAboveSquareDegrees
    }

    public static func refusalMessage(bbox: BoundingBox) -> String {
        "This area is too large for OpenStreetMap to answer. Choose something "
            + "no bigger than roughly \(Int(refuseAboveSquareDegrees.squareRoot()))° × "
            + "\(Int(refuseAboveSquareDegrees.squareRoot()))°, or turn OpenStreetMap off "
            + "and use Elevation or another source instead."
    }
}
