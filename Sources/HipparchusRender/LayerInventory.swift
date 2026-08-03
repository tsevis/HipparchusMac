import Foundation

/// What a rendered map actually contains.
///
/// Ported from `application/layer_inventory.py`.
///
/// The old layer panel was a fixed checklist written before half the layers existed:
/// it never mentioned contours, summits, bathymetry or earthquakes, and it claimed
/// the same twenty-three entries whether they held anything or not. An empty map
/// could not explain itself.
///
/// This derives the panel from the scene that was actually built, so a layer with
/// nothing in it says "none here" rather than sitting there ticked and blank.
public enum LayerInventory {

    /// Display names for layers whose id is not presentable.
    public static let labels: [String: String] = [
        "admin_boundaries": "Admin boundaries",
        "elevation_bands": "Elevation bands",
        "depth_bands": "Depth bands",
        "terrain_contours": "Contours",
        "terrain_index_contours": "Index contours",
        "terrain_hillshade": "Hillshade",
        "bathymetry": "Bathymetry",
        "summits": "Summit heights",
        "night_lights": "Night lights",
        "earthquakes_shallow": "Earthquakes, shallow",
        "earthquakes_intermediate": "Earthquakes, intermediate",
        "earthquakes_deep": "Earthquakes, deep",
        "satellite_tracks": "Satellite tracks",
        "satellite_footprints": "Satellite footprints",
        "street_names": "Street names",
        "places": "Place names",
        "amenities": "Amenities",
        "shops": "Shops",
        "landuse": "Land use",
        "coastline": "Coastline / sea",
        "ferry_routes": "Ferry routes",
        "sst_contours": "Sea temperature",
        "sst_bands": "Sea temperature bands",
        "seamark_lights": "Lights",
        "seamark_buoys": "Buoys",
        "seamark_beacons": "Beacons",
        "seamark_hazards": "Wrecks & hazards",
        "seamark_harbours": "Harbours & anchorages",
        "seamark_areas": "Restricted & traffic areas",
        "roads": "Roads",
        "roads_motorway": "Motorways",
        "roads_trunk": "Trunk roads",
        "roads_primary": "Primary roads",
        "roads_secondary": "Secondary roads",
        "roads_tertiary": "Tertiary roads",
        "roads_residential": "Residential roads",
        "roads_service": "Service roads",
        "roads_other": "Other roads",
        "voronoi_cells": "Voronoi cells",
        "delaunay_mesh": "Delaunay mesh",
        "hex_grid": "Hex grid",
        "circle_packing": "Circle packing",
    ]

    /// The order the panel reads in: terrain under the built environment, labels last.
    ///
    /// Sea marks are a group of their own rather than six rows inside
    /// "Water & land". They are a different kind of thing from a coastline — a
    /// coastline is the shape of the ground, a buoy is a statement about
    /// navigation — and on a sheet that carries both, a reader turning marks off
    /// wants one place to do it.
    public static let groupOrder = [
        "Terrain", "Water & land", "Sea marks", "Ocean", "Built", "Movement", "Labels", "Derived",
    ]

    static let groups: [String: String] = [
        "elevation_bands": "Terrain",
        "depth_bands": "Terrain",
        "terrain_contours": "Terrain",
        "terrain_index_contours": "Terrain",
        "terrain_hillshade": "Terrain",
        "bathymetry": "Terrain",
        "summits": "Terrain",
        "night_lights": "Terrain",
        "coastline": "Water & land",
        // A border partitions land; it is measured geography, not invented
        // geometry, and must not fall into the "Derived" fallback.
        "admin_boundaries": "Water & land",
        "water": "Water & land",
        "parks": "Water & land",
        "forests": "Water & land",
        "fields": "Water & land",
        "natural": "Water & land",
        "landuse": "Water & land",
        "seamark_lights": "Sea marks",
        "seamark_buoys": "Sea marks",
        "seamark_beacons": "Sea marks",
        "seamark_hazards": "Sea marks",
        "seamark_harbours": "Sea marks",
        "seamark_areas": "Sea marks",
        "sst_contours": "Ocean",
        "sst_bands": "Ocean",
        "buildings": "Built",
        "barriers": "Built",
        "power": "Built",
        "railways": "Movement",
        // A ferry route is transport, not water, and reads beside the railways.
        "ferry_routes": "Movement",
        "satellite_tracks": "Movement",
        "satellite_footprints": "Movement",
        "earthquakes_shallow": "Movement",
        "earthquakes_intermediate": "Movement",
        "earthquakes_deep": "Movement",
        "places": "Labels",
        "street_names": "Labels",
        "amenities": "Labels",
        "shops": "Labels",
        "voronoi_cells": "Derived",
        "delaunay_mesh": "Derived",
        "hex_grid": "Derived",
        "circle_packing": "Derived",
    ]

    /// One row of the layer panel.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let layerID: String
        public let label: String
        public let group: String
        public let count: Int
        public let visible: Bool
        /// A layer whose content is text rather than linework, so the count means
        /// labels. Summits are the obvious case.
        public let isLabels: Bool

        public var id: String { layerID }
        public var hasData: Bool { count > 0 }

        /// What the row shows on the right.
        public var countText: String {
            hasData ? spacedThousands(count) : "none here"
        }
    }

    public static func label(for layerID: String) -> String {
        if let known = labels[layerID] { return known }
        let words = layerID.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    public static func group(for layerID: String) -> String {
        // The road hierarchy is eight layers to the renderer and one idea to a
        // reader, so the whole family lands in one group.
        if layerID.hasPrefix("roads") { return "Movement" }
        return groups[layerID] ?? "Derived"
    }

    /// Rows for every layer the scene carries, grouped and ordered.
    public static func entries(for scene: RenderScene) -> [Entry] {
        var entries: [Entry] = []
        for layer in scene.layers {
            var count = layer.geometries.count
            let isLabels = count == 0 && !layer.labels.isEmpty
            if isLabels { count = layer.labels.count }

            entries.append(Entry(
                layerID: layer.name,
                label: label(for: layer.name),
                group: group(for: layer.name),
                count: count,
                visible: layer.style.visible,
                isLabels: isLabels
            ))
        }

        let order = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
        // Populated layers first inside a group: an empty row is information, but it
        // should not push the map's actual contents down the panel.
        entries.sort { first, second in
            let firstKey = (order[first.group] ?? 99, first.hasData ? 0 : 1, first.label)
            let secondKey = (order[second.group] ?? 99, second.hasData ? 0 : 1, second.label)
            return firstKey < secondKey
        }
        return entries
    }

    /// The layers a show-all or hide-all applies to: the ones with something in
    /// them. Ported from `LayersPanel.set_all`, which skips the rest — an empty
    /// layer has nothing to show, which is why its row is disabled.
    public static func toggleableLayerIDs(in scene: RenderScene) -> [String] {
        entries(for: scene).filter(\.hasData).map(\.layerID)
    }

    /// What `hiddenLayers` becomes when the user asks for all or none.
    ///
    /// Layers holding nothing keep whatever state they had: a layer hidden by
    /// hand and later emptied by a re-fetch should still be hidden when it fills
    /// again, and a bulk control is no reason to forget that.
    public static func hiddenLayers(
        in scene: RenderScene,
        settingAllVisible visible: Bool,
        from current: Set<String>
    ) -> Set<String> {
        let toggleable = Set(toggleableLayerIDs(in: scene))
        return visible ? current.subtracting(toggleable) : current.union(toggleable)
    }

    /// The inventory as `(group, rows)`, skipping groups with no layers.
    public static func grouped(for scene: RenderScene) -> [(group: String, rows: [Entry])] {
        let rows = entries(for: scene)
        var byGroup: [String: [Entry]] = [:]
        for row in rows { byGroup[row.group, default: []].append(row) }
        return groupOrder.compactMap { name in
            byGroup[name].map { (group: name, rows: $0) }
        }
    }

    /// One line: how much is on the map.
    public static func summary(for scene: RenderScene) -> String {
        let populated = entries(for: scene).filter(\.hasData)
        guard !populated.isEmpty else { return "Nothing to draw" }
        let total = populated.reduce(0) { $0 + $1.count }
        return "\(populated.count) layer\(populated.count == 1 ? "" : "s") · \(spacedThousands(total)) features"
    }
}
