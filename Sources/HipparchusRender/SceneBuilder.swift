import Foundation
import HipparchusData
import HipparchusGEOS
import HipparchusGeometry

/// Turn a fetched `FeatureCollection` into a drawable, exportable scene.
///
/// Ported from the terrain path through `application/scene_builder.py`. The other
/// sources, the presets and the illumination pass are later slices; the pipeline
/// order they all depend on is established here.
///
/// **Pipeline order matters and is not negotiable:**
///
///     project → clip → simplify → colour and weight
///
/// Clipping can split one feature into two and simplification can reject one.
/// Either shifts a parallel array of colours or stroke weights out of step with the
/// geometry it describes, and the map then draws the right shapes in the wrong
/// colours. That is kickoff detail 6, and it bit the Python twice — which is why
/// `RenderLayer` only lets geometry, weight and fill be appended together.
public struct SceneBuilder: Sendable {

    public struct Options: Sendable {
        /// Trim geometry to the requested area. A contour traced from a tile mosaic
        /// runs past the frame, because the mosaic does.
        public var clipToArea = true
        /// Douglas–Peucker tolerance in projected units. 0 disables.
        public var simplifyTolerance = 0.0
        public var style: TerrainStyle = TerrainStyle()

        public init() {}
    }

    /// Enough style to draw the terrain slice. The full preset system is a later
    /// slice; these are the `Hypsometric Relief` values from the Python.
    public struct TerrainStyle: Sendable {
        public var background = RGBAColor(247, 244, 236)
        public var contourColor = RGBAColor(120, 98, 74, 190)
        public var contourWidth: Double = 0.35
        public var indexContourColor = RGBAColor(92, 72, 50)
        public var indexContourWidth: Double = 0.75
        public var bathymetryColor = RGBAColor(96, 122, 140, 190)
        public var bathymetryWidth: Double = 0.35
        /// Low and high ends of the hypsometric ramp.
        public var bandLowColor = RGBAColor(214, 221, 199)
        public var bandHighColor = RGBAColor(150, 113, 86)
        public var summitColor = RGBAColor(60, 46, 32)

        public init() {}
    }

    public let options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// Layer draw order: ground first, linework over it, labels last.
    ///
    /// Bands are fills and must go under the contours that describe the same
    /// ground, or the fills paint over the lines.
    public static let layerOrder = [
        TerrainLayer.elevationBands,
        TerrainLayer.bathymetry,
        TerrainLayer.minorContours,
        TerrainLayer.indexContours,
        TerrainLayer.summits,
    ]

    public func build(from collection: FeatureCollection) throws -> RenderScene {
        let projection = ProjectionProfile(bbox: collection.bbox, mode: .webMercator)
        let geos = GEOSContext()

        let clipRegion: Geometry? = {
            guard options.clipToArea, let bbox = collection.bbox else { return nil }
            return .polygon(Polygon.box(projection.project(bbox)))
        }()

        var layers: [RenderLayer] = []
        var clippedCount = 0
        var droppedCount = 0

        for name in Self.layerOrder {
            let features = collection.features(in: name)
            var layer = RenderLayer(name: name, style: style(for: name))

            // Summits are labels, not linework: the point carries a height, and the
            // height is the whole reason the layer exists.
            if name == TerrainLayer.summits {
                for feature in features {
                    guard case .point(let point) = feature.geometry else { continue }
                    layer.labels.append(PlaceLabel(
                        name: feature.property("name")?.stringValue ?? "",
                        position: projection.project(point),
                        placeType: "summit"
                    ))
                }
                layers.append(layer)
                continue
            }

            // One feature at a time, on purpose. The band colour lives in a feature
            // property, and processing the layer in a batch would separate the
            // colour list from the geometry list the moment clipping split a band.
            // Do not "optimise" this back into a batch.
            for feature in features {
                var geometry = projection.project(feature.geometry)

                if let clipRegion {
                    // Ask whether it needs trimming before trimming it. Most
                    // features are wholly inside, and an overlay on each of them is
                    // both wasted work and a lie in the diagnostics: GEOS normalises
                    // ring order, so comparing before and after reports untouched
                    // geometry as clipped.
                    if try geos.covers(clipRegion, geometry) {
                        // Already inside; leave it exactly as it is.
                    } else {
                        geometry = try geos.intersection(geometry, clipRegion)
                        if geometry.isEmpty {
                            droppedCount += 1
                            continue
                        }
                        clippedCount += 1
                    }
                }

                if options.simplifyTolerance > 0 {
                    let simplified = try geos.simplify(
                        geometry, tolerance: options.simplifyTolerance, preserveTopology: true
                    )
                    // A simplification that empties a feature is worse than no
                    // simplification: keep the original rather than lose the line.
                    if !simplified.isEmpty { geometry = simplified }
                }

                // Colour last, built in the same step as the geometry it belongs to.
                layer.append(geometry, weight: 1.0, fillColor: fillColor(for: feature, in: name))
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

        return RenderScene(
            layers: layers,
            bbox: collection.bbox,
            projection: projection,
            background: options.style.background,
            metadata: metadata,
            diagnostics: [
                "clipped_geometries": .int(clippedCount),
                "dropped_geometries": .int(droppedCount),
                "geos_version": .string(geos.version),
            ]
        )
    }

    // MARK: -

    private func style(for layer: String) -> LayerStyle {
        var style = LayerStyle()
        let terrain = options.style
        switch layer {
        case TerrainLayer.elevationBands:
            style.fillEnabled = true
            style.fillColor = terrain.bandLowColor
            style.fillColorHigh = terrain.bandHighColor
            style.strokeWidth = 0
            style.strokeColor = RGBAColor(0, 0, 0, 0)
        case TerrainLayer.minorContours:
            style.fillEnabled = false
            style.strokeColor = terrain.contourColor
            style.strokeWidth = terrain.contourWidth
            style.lineCap = .round
        case TerrainLayer.indexContours:
            style.fillEnabled = false
            style.strokeColor = terrain.indexContourColor
            style.strokeWidth = terrain.indexContourWidth
            style.lineCap = .round
        case TerrainLayer.bathymetry:
            style.fillEnabled = false
            style.strokeColor = terrain.bathymetryColor
            style.strokeWidth = terrain.bathymetryWidth
            style.lineCap = .round
        case TerrainLayer.summits:
            style.fillEnabled = false
            style.strokeColor = terrain.summitColor
            style.strokeWidth = 0
        default:
            break
        }
        return style
    }

    /// A band's place in the sequence becomes its place on the colour ramp.
    private func fillColor(for feature: Feature, in layer: String) -> RGBAColor? {
        guard layer == TerrainLayer.elevationBands,
              let index = feature.property("band_index")?.doubleValue,
              let count = feature.property("band_count")?.doubleValue,
              count > 1
        else {
            return nil
        }
        return options.style.bandLowColor.mixed(
            towards: options.style.bandHighColor,
            amount: index / (count - 1)
        )
    }
}
