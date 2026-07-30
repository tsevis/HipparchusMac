import Foundation
import HipparchusData
import HipparchusGEOS
import HipparchusGeometry

/// Turn a fetched `FeatureCollection` into a drawable, exportable scene.
///
/// Ported from `application/scene_builder.py`.
///
/// **Pipeline order matters and is not negotiable:**
///
///     project → clip → simplify → smooth → cap → colour and weight
///
/// Clipping can split one feature into two, simplification can reject one and
/// smoothing can drop one outright. Any of those shifts a parallel array of
/// colours or stroke weights out of step with the geometry it describes, and the
/// map then draws the right shapes in the wrong colours. That is kickoff detail 6,
/// and it bit the Python twice — which is why `RenderLayer` only lets geometry,
/// weight and fill be appended together, and why illumination runs last.
///
/// A preset says what the map should look like; a quality profile says how much
/// work to spend getting there. They multiply rather than override.
public struct SceneBuilder: Sendable {

    public struct Options: Sendable {
        public var preset: ArtisticPreset
        public var quality: QualityProfile
        /// Trim geometry to the requested area. A contour traced from a tile mosaic
        /// runs past the frame, because the mosaic does.
        public var clipToArea: Bool

        public init(
            preset: ArtisticPreset = Presets.preset("Hypsometric Relief"),
            quality: QualityProfile = Quality.default,
            clipToArea: Bool = true
        ) {
            self.preset = preset
            self.quality = quality
            self.clipToArea = clipToArea
        }
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Draw order: ground first, linework over it, labels last.
    ///
    /// Relief sits above land cover and below the built environment, the way a
    /// printed topographic sheet stacks it. Bands are fills and must go under the
    /// contours that describe the same ground, or the fills paint over the lines.
    ///
    /// A layer not named here sorts alphabetically after everything that is, so a
    /// new source appears somewhere predictable rather than wherever the dictionary
    /// happened to put it.
    public static let preferredLayerOrder = [
        // Ground cover.
        "coastline", "water", "fields", "forests", "natural", "landuse", "parks",
        // Relief.
        "elevation_bands", "terrain_hillshade", "bathymetry",
        "terrain_contours", "terrain_index_contours",
        // The built environment.
        "buildings", "barriers", "power",
        // Roads, major to minor.
        "roads_motorway", "roads_trunk", "roads_primary", "roads_secondary",
        "roads_tertiary", "roads_residential", "roads_service", "roads_other", "roads",
        "railways",
        // Orbital geometry floats above the ground it passes over.
        "satellite_footprints", "satellite_tracks",
        // Measured point phenomena sit above the base map.
        "earthquakes_deep", "earthquakes_intermediate", "earthquakes_shallow",
        // Labels on top, by importance.
        "summits", "places", "street_names", "amenities", "shops",
        // Derived artistic layers.
        "voronoi_cells", "delaunay_mesh", "hex_grid", "circle_packing",
    ]

    /// Sort layer names into draw order.
    public static func ordered(_ names: some Collection<String>) -> [String] {
        let present = Set(names)
        let known = preferredLayerOrder.filter(present.contains)
        let rest = present.subtracting(known).sorted()
        return known + rest
    }

    public func build(from collection: FeatureCollection) throws -> RenderScene {
        let quality = options.quality
        let geometryProfile = options.preset.geometryProfile
        let styleProfile = options.preset.styleProfile

        let projection = ProjectionProfile(bbox: collection.bbox, mode: quality.projectionMode)
        let geos = GEOSContext()

        let tolerance = geometryProfile.simplifyTolerance(for: quality)
        let cap = Swift.max(
            1,
            Int(Double(geometryProfile.maxOnScreenFeaturesPerLayer) * quality.geometryCapScale)
        )

        let clipRegion: Geometry? = {
            guard options.clipToArea, let bbox = collection.bbox else { return nil }
            return .polygon(Polygon.box(projection.project(bbox)))
        }()

        var counts = BuildCounts()
        var layers: [RenderLayer] = []
        var illuminatedLayers: [String] = []

        for name in Self.ordered(collection.featuresByLayer.keys) {
            let features = collection.features(in: name)
            let style = styleProfile.style(for: name)
            var layer = RenderLayer(name: name, style: style, rawFeatureCount: features.count)

            // One feature at a time, on purpose. A feature's own colour lives in its
            // properties, and processing the layer in a batch would separate the
            // colour list from the geometry list the moment clipping split a band.
            // Do not "optimise" this back into a batch.
            var processed: [(geometry: Geometry, fillColor: RGBAColor?)] = []

            for feature in features {
                guard processed.count < cap else { break }

                // A point with a name is a label, not linework. The height on a
                // summit is the whole reason that layer exists.
                if case .point(let point) = feature.geometry {
                    if let name = feature.property("name")?.stringValue, !name.isEmpty {
                        layer.labels.append(PlaceLabel(
                            name: name,
                            position: projection.project(point),
                            placeType: feature.property("place")?.stringValue
                                ?? feature.property("amenity")?.stringValue
                                ?? feature.property("shop")?.stringValue
                                ?? labelType(for: layer.name)
                        ))
                    }
                    continue
                }

                guard let geometry = try process(
                    feature.geometry,
                    layer: name,
                    projection: projection,
                    clipRegion: clipRegion,
                    tolerance: tolerance,
                    smoothingIterations: geometryProfile.smoothingIterations(for: name, quality: quality),
                    geos: geos,
                    counts: &counts
                ) else { continue }

                processed.append((geometry, rampColor(for: feature, style: style)))
            }

            layer.labels = thinned(
                layer.labels, clippedTo: clipRegion?.bounds, limit: labelLimit(for: name)
            )

            // Colour and weight last, in the same step as the geometry they belong to.
            if style.illumination > 0, !processed.isEmpty {
                let profile = IlluminationProfile(
                    azimuthDegrees: style.illuminationAzimuth,
                    bands: style.illuminationBands,
                    litScale: style.illuminationLitScale,
                    shadowScale: style.illuminationShadowScale
                )
                for run in illuminate(processed.map(\.geometry), profile: profile) {
                    layer.append(.lineString(run.line), weight: run.weight)
                }
                illuminatedLayers.append(name)
            } else {
                for item in processed {
                    layer.append(item.geometry, fillColor: item.fillColor)
                }
            }

            layers.append(layer)
        }

        var metadata = collection.metadata
        for (key, value) in projection.metadata(bbox: collection.bbox) {
            metadata["projection_\(key)"] = .string(value)
        }
        if let provenance = collection.provenance {
            metadata["provenance"] = .string(provenance.rawValue)
        }
        metadata["preset"] = .string(options.preset.name)
        metadata["quality_profile"] = .string(quality.key)

        return RenderScene(
            layers: layers,
            bbox: collection.bbox,
            projection: projection,
            background: styleProfile.background,
            metadata: metadata,
            diagnostics: [
                "clipped_geometries": .int(counts.clipped),
                "dropped_geometries": .int(counts.dropped),
                "smoothed_geometries": .int(counts.smoothed),
                "invalid_geometries": .int(counts.invalid),
                "simplify_tolerance": .double(tolerance),
                "quality_profile": .string(quality.key),
                "preset": .string(options.preset.name),
                "illuminated_layers": .string(illuminatedLayers.sorted().joined(separator: ", ")),
                "geos_version": .string(geos.version),
            ]
        )
    }

    // MARK: - One feature through the pipeline

    private struct BuildCounts {
        var clipped = 0
        var dropped = 0
        var smoothed = 0
        var invalid = 0
    }

    private func process(
        _ source: Geometry,
        layer: String,
        projection: ProjectionProfile,
        clipRegion: Geometry?,
        tolerance: Double,
        smoothingIterations: Int,
        geos: GEOSContext,
        counts: inout BuildCounts
    ) throws -> Geometry? {
        var geometry = projection.project(source)

        if let clipRegion {
            // Ask whether it needs trimming before trimming it. Most features are
            // wholly inside, and an overlay on each of them is both wasted work and a
            // lie in the diagnostics: GEOS normalises ring order, so comparing before
            // and after reports untouched geometry as clipped.
            if try geos.covers(clipRegion, geometry) {
                // Already inside; leave it exactly as it is.
            } else {
                geometry = try geos.intersection(geometry, clipRegion)
                if geometry.isEmpty {
                    counts.dropped += 1
                    return nil
                }
                counts.clipped += 1
            }
        }

        if tolerance > 0 {
            let simplified = try geos.simplify(geometry, tolerance: tolerance, preserveTopology: true)
            // A simplification that empties a feature is worse than no
            // simplification: keep the original rather than lose the line.
            if !simplified.isEmpty { geometry = simplified }
        }

        if smoothingIterations > 0 {
            let result = try geos.smoothLayer(layer, geometries: [geometry], iterations: smoothingIterations)
            counts.smoothed += result.smoothed
            counts.invalid += result.invalid
            guard let smoothed = result.geometries.first else { return nil }
            geometry = smoothed
        }

        return geometry
    }

    // MARK: - Colour

    /// A feature's place in a sequence becomes its place on the layer's colour ramp.
    ///
    /// Only layers whose features carry `band_index` and `band_count` ramp; every
    /// other layer takes the flat fill and ignores `fillColorHigh`.
    private func rampColor(for feature: Feature, style: LayerStyle) -> RGBAColor? {
        guard style.fillEnabled,
              let high = style.fillColorHigh,
              let index = feature.property("band_index")?.doubleValue,
              let count = feature.property("band_count")?.doubleValue,
              count > 1
        else {
            return nil
        }
        return style.fillColor.mixed(towards: high, amount: index / (count - 1))
    }

    // MARK: - Labels

    /// The type a label carries when the feature does not name one itself.
    private func labelType(for layer: String) -> String {
        switch layer {
        case "summits": "summit"
        case "satellite_tracks": "satellite"
        case let name where name.hasPrefix("earthquakes"): "earthquake"
        default: ""
        }
    }

    /// How many labels a layer may place. Ported from the Python's per-layer budgets.
    private func labelLimit(for layer: String) -> Int {
        switch layer {
        case "places": 120
        case "street_names": 90
        case "amenities", "shops": 80
        case "earthquakes_shallow", "earthquakes_intermediate", "earthquakes_deep": 60
        case "summits": 24
        case "satellite_tracks": 20
        default: 60
        }
    }

    /// Drop labels outside the frame, then drop those that would collide.
    ///
    /// Providers return everything that touches the area, so a fetch carries features
    /// whose label anchor sits outside it. Those go first — otherwise the budget is
    /// spent on names nobody can see.
    private func thinned(_ labels: [PlaceLabel], clippedTo bounds: Bounds?, limit: Int) -> [PlaceLabel] {
        var candidates = labels
        if let bounds {
            candidates = candidates.filter {
                $0.position.x >= bounds.minX && $0.position.x <= bounds.maxX
                    && $0.position.y >= bounds.minY && $0.position.y <= bounds.maxY
            }
        }

        // Settlements before anything else, then anything that names its type, then
        // the rest — and alphabetically inside each tier, so the same map thins the
        // same way every time it is drawn.
        let settlements: Set<String> = ["city", "town", "village", "hamlet", "suburb", "neighbourhood"]
        candidates.sort { first, second in
            func rank(_ label: PlaceLabel) -> Int {
                if settlements.contains(label.placeType) { return 0 }
                return label.placeType.isEmpty ? 2 : 1
            }
            let (a, b) = (rank(first), rank(second))
            return a == b ? first.name < second.name : a < b
        }

        var accepted: [PlaceLabel] = []
        var occupied: [Bounds] = []
        for label in candidates {
            guard accepted.count < limit else { break }
            // A rough box in projected units, sized from the text it will hold.
            let width = Swift.max(50.0, Double(label.name.count) * 8.0)
            let box = Bounds(
                minX: label.position.x - width * 0.5, minY: label.position.y - 10.0,
                maxX: label.position.x + width * 0.5, maxY: label.position.y + 10.0
            )
            if occupied.contains(where: { $0.intersects(box) }) { continue }
            occupied.append(box)
            accepted.append(label)
        }
        return accepted
    }
}
