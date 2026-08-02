import Foundation

/// Fetch every ticked source and merge what comes back.
///
/// Ported from `data_sources/data_source_manager.py`.
///
/// Sources stack: the plan names a base and everything layered onto it, and the
/// merged collection carries all of their layers. A choice of base never means
/// giving up a layer.
///
/// **Sources are fetched one at a time, on purpose.** It is tempting to run them in
/// a task group, but the honest cancellation this app promises — "skips sources
/// that have not started" — only means anything while some of them have not
/// started. There is little to win either way: a fetch of a city with every layer
/// took 331 s in the Python, of which 325 s was Overpass alone, so overlapping the
/// other sources with it would save seconds off minutes. The concurrency that
/// mattered is inside the terrain provider, where a tile pool turned 23 s into 5 s.
public struct DataSourceManager: Sendable {

    /// A source that failed, and what it said. Kept rather than thrown: one source
    /// failing must not sink a fetch that four others answered.
    public struct ProviderError: Sendable, Equatable {
        public let sourceID: String
        public let message: String
    }

    private let providers: [String: any MapProvider]

    public init(providers: [any MapProvider]) {
        self.providers = Dictionary(providers.map { ($0.providerID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func provider(_ id: String) -> (any MapProvider)? { providers[id] }

    public var registeredIDs: [String] { providers.keys.sorted() }

    /// One source's outcome, kept with its place in the plan.
    ///
    /// The position is carried because the sources no longer finish in the
    /// order they were asked for, and the merge depends on that order: it takes
    /// the *first* answer for keys a single source owns, like the contour
    /// interval. Sorting by position before merging is what stops "which
    /// provider answered fastest" from deciding what the sheet says.
    private struct Outcome {
        let position: Int
        let collection: FeatureCollection?
        let error: ProviderError?
        let cancelled: Bool
    }

    /// Fetch the plan and merge the results.
    ///
    /// Sources are fetched **concurrently**. They were sequential, which made a
    /// fetch cost the sum of its sources rather than the slowest of them: six
    /// ticked sources meant Overpass's retry budget, then the imagery's, then
    /// the earthquakes', one after another, and the reasonable ones waited
    /// behind whichever was having a bad day. They share nothing but the
    /// network, so there was never a reason to serialise them.
    ///
    /// Throws only `FetchCancelled`, and only when cancellation left nothing to
    /// draw. Anything else a provider raises is recorded against that source and the
    /// rest of the fetch carries on.
    public func fetch(
        _ query: BBoxQuery,
        plan: FetchPlan,
        reporter: FetchReporter? = nil
    ) async throws -> FeatureCollection {
        let sourceIDs = plan.sourceIDs
        await reporter?.expect(sourceIDs)

        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            for (position, sourceID) in sourceIDs.enumerated() {
                guard let provider = providers[sourceID] else {
                    await reporter?.failed(sourceID, detail: "not registered")
                    group.addTask {
                        Outcome(
                            position: position, collection: nil,
                            error: ProviderError(sourceID: sourceID, message: "not registered"),
                            cancelled: false
                        )
                    }
                    continue
                }

                group.addTask {
                    // Checked here rather than before the group is built: a
                    // source cancelled before it starts is skipped outright,
                    // which is the part of cancellation that can be instant.
                    if Task.isCancelled {
                        await reporter?.cancelled(sourceID)
                        return Outcome(position: position, collection: nil, error: nil, cancelled: true)
                    }
                    await reporter?.started(sourceID)
                    do {
                        let fetched = try await provider.fetch(query)
                        await reporter?.finished(sourceID, detail: Self.describe(fetched))
                        return Outcome(position: position, collection: fetched, error: nil, cancelled: false)
                    } catch is CancellationError {
                        await reporter?.cancelled(sourceID)
                        return Outcome(position: position, collection: nil, error: nil, cancelled: true)
                    } catch is FetchCancelled {
                        await reporter?.cancelled(sourceID)
                        return Outcome(position: position, collection: nil, error: nil, cancelled: true)
                    } catch {
                        let message = String(describing: error)
                        await reporter?.failed(sourceID, detail: String(message.prefix(40)))
                        return Outcome(
                            position: position, collection: nil,
                            error: ProviderError(sourceID: sourceID, message: message),
                            cancelled: false
                        )
                    }
                }
            }

            var collected: [Outcome] = []
            for await outcome in group { collected.append(outcome) }
            // Back into the plan's order, whatever order they finished in.
            return collected.sorted { $0.position < $1.position }
        }

        let collections = outcomes.compactMap(\.collection)
        let errors = outcomes.compactMap(\.error)
        let wasCancelled = outcomes.contains(where: \.cancelled)

        // Cancelling discards the result rather than drawing it — but only when
        // there is nothing worth drawing. Sources that finished before the cancel
        // still count, which is what keeps a half-cancelled fetch from throwing away
        // work that is already paid for.
        if collections.isEmpty {
            if wasCancelled { throw FetchCancelled(source: plan.base) }
            return FeatureCollection(
                featuresByLayer: [:],
                metadata: metadata(source: "none", errors: errors),
                bbox: query.bbox
            )
        }

        return merged(collections, query: query, errors: errors, cancelled: wasCancelled)
    }

    // MARK: -

    /// A short note for the progress line: what this source actually returned.
    private static func describe(_ collection: FeatureCollection) -> String {
        let layers = collection.featuresByLayer.filter { !$0.value.isEmpty }.count
        let features = collection.featureCount
        guard features > 0 else { return "nothing here" }
        return "\(features) in \(layers) layer\(layers == 1 ? "" : "s")"
    }

    private func metadata(source: String, errors: [ProviderError]) -> [String: PropertyValue] {
        var metadata: [String: PropertyValue] = ["source": .string(source)]
        if !errors.isEmpty {
            metadata["provider_errors"] = .string(
                errors.map { "\($0.sourceID): \($0.message)" }.joined(separator: "; ")
            )
        }
        return metadata
    }

    private func merged(
        _ collections: [FeatureCollection],
        query: BBoxQuery,
        errors: [ProviderError],
        cancelled: Bool
    ) -> FeatureCollection {
        var featuresByLayer: [String: [Feature]] = [:]
        var sources: [String] = []
        var metadata: [String: PropertyValue] = [:]

        for collection in collections {
            let source = collection.metadata["source"]?.stringValue ?? "unknown"
            if !sources.contains(source) { sources.append(source) }

            // Keep each provider's own metadata reachable rather than flattening it
            // away. Flattening loses provenance — including whether a layer was
            // measured or generated — which is the one thing that must survive.
            for (key, value) in collection.metadata {
                metadata["\(source).\(key)"] = value
            }
            for (layer, features) in collection.featuresByLayer {
                featuresByLayer[layer, default: []].append(contentsOf: features)
            }
        }

        metadata["source"] = .string(sources.joined(separator: "+"))
        metadata["sources"] = .string(sources.joined(separator: ", "))
        metadata["feature_count"] = .int(featuresByLayer.values.reduce(0) { $0 + $1.count })
        if cancelled {
            // The map is real but incomplete, and saying so is the difference
            // between a partial map and a wrong one.
            metadata["cancelled"] = .bool(true)
        }
        if !errors.isEmpty {
            metadata["provider_errors"] = .string(
                errors.map { "\($0.sourceID): \($0.message)" }.joined(separator: "; ")
            )
        }

        // Metadata a single source owns and the merge should not rename: the scene
        // and the exporter read these by name.
        for key in ["contour_interval_metres", "elevation_model", "elevation_min_metres", "elevation_max_metres"] {
            if let value = collections.compactMap({ $0.metadata[key] }).first {
                metadata[key] = value
            }
        }

        return FeatureCollection(
            featuresByLayer: featuresByLayer,
            metadata: metadata,
            bbox: query.bbox,
            // The weakest claim any source makes is the claim the merged map can
            // make. A measured contour sheet with a synthetic layer on it is not a
            // measured map.
            provenance: Provenance.merged(collections.compactMap(\.provenance))
        )
    }
}
