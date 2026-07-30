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

        /// Overrides the preset's geometry profile, and the only way to turn a
        /// derived layer on.
        ///
        /// None of the sixteen presets enables one — not here and not in the Python,
        /// where every preset styles the four derived layers and three tune their
        /// sizes, but all sixty-four switches are off. So without this the machinery
        /// would be unreachable, and a feature nothing can reach is a feature that
        /// quietly rots. `nil` means "whatever the preset says", which is off.
        public var derivations: GeometryPipelineProfile?

        public init(
            preset: ArtisticPreset = Presets.preset("Hypsometric Relief"),
            quality: QualityProfile = Quality.default,
            clipToArea: Bool = true,
            derivations: GeometryPipelineProfile? = nil
        ) {
            self.preset = preset
            self.quality = quality
            self.clipToArea = clipToArea
            self.derivations = derivations
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
        "railways", "ferry_routes",
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

    /// Where a layer sits in the draw order. Anything unnamed sorts after
    /// everything named, which is what keeps a new layer somewhere predictable.
    static func rank(_ name: String) -> Int {
        preferredLayerOrder.firstIndex(of: name) ?? preferredLayerOrder.count
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

        // Roads arrive as one layer and are drawn as eight. Split before anything
        // else touches them, so the rest of the pipeline sees the layers the
        // presets actually style.
        let featuresByLayer = Self.classifyRoads(collection.featuresByLayer)

        for name in Self.ordered(featuresByLayer.keys) {
            let features = featuresByLayer[name] ?? []
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

        // Derived layers last, and built from the projected, clipped geometry the
        // base layers just produced — not from the raw features. A Voronoi diagram
        // of building centroids has to be a diagram of where the buildings ended up
        // on the page, not of where they were before the frame was applied.
        for derived in try derive(from: layers, styleProfile: styleProfile, geos: geos) {
            layers.append(derived)
        }
        // Name breaks the tie, matching `ordered`: Swift's sort is not stable, and
        // every unnamed layer ranks the same.
        layers.sort { first, second in
            (Self.rank(first.name), first.name) < (Self.rank(second.name), second.name)
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

    // MARK: - Derived layers

    /// The layers a preset invents rather than fetches.
    ///
    /// Ported from `_derive_layers` and `_scene_boundary`. Every one of them is
    /// **synthetic** — a pattern read out of the data, not a measurement of
    /// anything — which is why the scene records that it derived them.
    ///
    /// Nothing here runs unless a preset asks. None of the sixteen built-in presets
    /// does, in this port or in the Python; they all *style* the four layers, and
    /// three of them tune the hex radius and circle sizes, but the switches are off.
    /// Turning one on is `SceneBuilder.Options.derivations`.
    private func derive(
        from layers: [RenderLayer],
        styleProfile: StyleProfile,
        geos: GEOSContext
    ) throws -> [RenderLayer] {
        let profile = options.derivations ?? options.preset.geometryProfile
        guard profile.deriveVoronoi || profile.deriveDelaunay
            || profile.deriveHexGrid || profile.deriveCirclePacking
        else {
            return []
        }

        // A preview of a dense city is already a hundred thousand shapes; deriving
        // a second structure on top of it is not what "fast preview" means.
        let total = layers.reduce(0) { $0 + $1.geometries.count }
        guard !(options.quality.isExport == false && total > 100_000) else { return [] }

        func geometries(_ name: String) -> [Geometry] {
            layers.first { $0.name == name }?.geometries ?? []
        }
        guard let boundary = try sceneBoundary(from: layers, geos: geos) else { return [] }

        func layer(_ name: String, _ shapes: [Polygon]) -> RenderLayer? {
            guard !shapes.isEmpty else { return nil }
            var layer = RenderLayer(
                name: name, style: styleProfile.style(for: name), rawFeatureCount: shapes.count
            )
            for shape in shapes { layer.append(.polygon(shape)) }
            return layer
        }

        var derived: [RenderLayer] = []

        if profile.deriveVoronoi {
            let buildings = geometries("buildings")
            if !buildings.isEmpty {
                let cells = try geos.voronoiCells(around: buildings, boundary: boundary)
                if let made = layer("voronoi_cells", cells) { derived.append(made) }
            }
        }

        if profile.deriveDelaunay {
            let roads = geometries("roads") + Self.roadHierarchy.flatMap(geometries)
            if !roads.isEmpty {
                let sites = try geos.roadIntersections(roads)
                let mesh = try geos.delaunayTriangles(sites: sites, boundary: boundary)
                if let made = layer("delaunay_mesh", mesh) { derived.append(made) }
            }
        }

        if profile.deriveHexGrid {
            let grid = try geos.hexGrid(
                boundary: boundary,
                options: HexGridOptions(radius: profile.hexRadius, clipToBoundary: true)
            )
            if let made = layer("hex_grid", grid) { derived.append(made) }
        }

        if profile.deriveCirclePacking {
            let circles = try geos.packedCircles(in: boundary, options: CirclePackingOptions(
                minRadius: profile.circleMinRadius,
                maxRadius: profile.circleMaxRadius,
                radiusStep: Swift.max(1.0, profile.circleMinRadius * 0.25),
                sampleStep: Swift.max(4.0, profile.circleMinRadius),
                maxCircles: 350,
                clearance: 0.5
            ))
            if let made = layer("circle_packing", circles) { derived.append(made) }
        }

        return derived
    }

    static let roadHierarchy = [
        "roads_motorway", "roads_trunk", "roads_primary", "roads_secondary",
        "roads_tertiary", "roads_residential", "roads_service", "roads_other",
    ]

    /// The `highway` values that make up each class, major to minor.
    ///
    /// Ported from `_classify_roads`. Order matters only in that the first match
    /// wins, and no value appears twice.
    static let roadClasses: [(layer: String, values: Set<String>)] = [
        ("roads_motorway", ["motorway", "motorway_link"]),
        ("roads_trunk", ["trunk", "trunk_link"]),
        ("roads_primary", ["primary", "primary_link"]),
        ("roads_secondary", ["secondary", "secondary_link"]),
        ("roads_tertiary", ["tertiary", "tertiary_link"]),
        ("roads_residential", ["residential", "living_street", "unclassified"]),
        ("roads_service", ["service", "track", "path", "footway", "cycleway", "pedestrian"]),
    ]

    /// Split the road layer into the hierarchy the presets are written for.
    ///
    /// Every one of the sixteen presets styles eight road classes with distinct
    /// weights and colours — a motorway at five units in blue, a primary at four in
    /// red, a residential at two in white — and until this ran, none of it was ever
    /// used: everything landed in the generic `roads` layer and drew at one weight.
    /// An Athens fetch is 111 208 roads, and a map that draws a footpath exactly
    /// like a motorway is not a map of a road network.
    ///
    /// **One departure from the Python.** It caps the *total* across the classes
    /// while classifying, so in a dense city the 45 000 residential ways can use up
    /// the budget before the motorways are reached. Here the split happens first and
    /// each class meets the per-layer cap on its own, which is how every other layer
    /// in this builder is already treated — and it means a motorway is never dropped
    /// because forty thousand footpaths came first.
    static func classifyRoads(_ featuresByLayer: [String: [Feature]]) -> [String: [Feature]] {
        guard let roads = featuresByLayer["roads"], !roads.isEmpty else { return featuresByLayer }

        var result = featuresByLayer
        // The generic layer goes: with the hierarchy populated, an always-empty
        // "Roads" row above eight full ones is noise rather than information.
        result.removeValue(forKey: "roads")

        for feature in roads {
            let highway = feature.property("highway")?.stringValue ?? ""
            let layer = roadClasses.first { $0.values.contains(highway) }?.layer ?? "roads_other"
            // Rebuilt rather than moved, so the feature's own record of which layer
            // it is in stays true — the exporter and the diagnostics both read it.
            result[layer, default: []].append(Feature(
                id: feature.id,
                layer: layer,
                source: feature.source,
                geometry: feature.geometry,
                provenance: feature.provenance,
                properties: feature.properties
            ))
        }
        return result
    }

    /// The part of the frame the map actually occupies.
    ///
    /// A union of every building, road and park is a shape full of holes and
    /// inlets, and a hex grid clipped to it would be lace rather than a grid, so
    /// the hull is what the derivations are built inside.
    private func sceneBoundary(from layers: [RenderLayer], geos: GEOSContext) throws -> Geometry? {
        let candidates = ["buildings", "water", "parks", "roads"].flatMap { name in
            layers.first { $0.name == name }?.geometries ?? []
        }
        guard !candidates.isEmpty else { return nil }

        // Unioning thousands of geometries is very expensive, and for a preview the
        // difference between the hull and the bounding box is not worth the wait.
        if !options.quality.isExport, candidates.count > 5000 {
            var extent: Bounds?
            for candidate in candidates {
                guard let bounds = candidate.bounds else { continue }
                extent = extent?.union(bounds) ?? bounds
            }
            return extent.map { .polygon(Polygon.box($0)) }
        }

        let hull = try geos.convexHull(geos.unaryUnion(candidates))
        return hull.isEmpty ? nil : hull
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
