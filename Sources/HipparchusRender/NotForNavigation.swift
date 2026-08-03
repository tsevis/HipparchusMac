import Foundation
import HipparchusData

/// Whether a sheet is drawing the sea, and what it therefore has to say.
///
/// **This is the one piece of furniture that is on by default**, and the
/// inversion is the whole statement. Everything else in `Composition` is off
/// until asked for, because the map is the product. This is not decoration: the
/// application now draws buoys as chart symbols, wrecks with their masts, and a
/// sea floor in filled depth bands, and the better all that gets the more it
/// looks like something it is not.
///
/// What it is not:
///
/// - **OpenStreetMap's seamarks are community-maintained and unvalidated.**
///   Coverage is dense in Northern Europe and thin in the Eastern Mediterranean,
///   and a mark that has been moved, retired or never surveyed looks exactly
///   like one that has not.
/// - **The depths are a survey compilation in European waters and a
///   kilometre-scale global grid everywhere else**, and the sheet says which in
///   `sea_floor_surveyed_share` — but neither has been reduced to a chart datum,
///   so a depth here is not a charted sounding.
/// - **Nothing here is updated by Notices to Mariners**, which is what makes a
///   chart a chart rather than a picture of one.
///
/// A person is free to remove the notice — this is a drawing tool, and a poster
/// of the Aegean does not want a warning stamped across it. What they cannot
/// remove is the machine-readable claim: `data-hipparchus-not-for-navigation`
/// goes on the SVG root, and `not_for_navigation` into the diagnostics beside
/// every export, whether the words were drawn or not.
public enum NotForNavigation {

    /// The layers whose presence means the sheet is making a claim about the sea
    /// that a reader might act on.
    ///
    /// Deliberately not `water` or `coastline`: a river and a shoreline are
    /// geography, and a street map of Amsterdam is not pretending to be a chart.
    /// It is the marks and the depths that do that.
    public static let marineLayers: Set<String> =
        Set(Seamarks.allLayers)
        + [TerrainLayer.bathymetry, TerrainLayer.depthBands]

    /// The words. Short enough to sit in a margin, specific enough to mean
    /// something — "not for navigation" alone reads as boilerplate, and the
    /// second clause is what stops it.
    public static let notice = "NOT FOR NAVIGATION · not a charted survey, and not corrected by Notices to Mariners"

    /// Whether this scene is drawing the sea.
    ///
    /// Layers that exist but hold nothing do not count. An empty `bathymetry`
    /// layer is on every terrain sheet ever drawn — it is how the panel says
    /// "none here" — and stamping a warning on a map of Everest because of it
    /// would teach a reader to ignore the warning.
    public static func applies(to scene: RenderScene) -> Bool {
        scene.layers.contains { layer in
            marineLayers.contains(layer.name)
                && (!layer.geometries.isEmpty || !layer.labels.isEmpty)
        }
    }
}

private func + (lhs: Set<String>, rhs: [String]) -> Set<String> {
    lhs.union(rhs)
}
