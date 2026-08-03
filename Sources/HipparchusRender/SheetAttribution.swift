import Foundation
import HipparchusData

/// Which sources actually drew this sheet, and therefore what it owes.
///
/// `AttributionRegistry` knows what each source is owed; this knows what a
/// particular scene used. The split is deliberate — the registry is a fact about
/// the application and belongs beside the providers, and this is a fact about
/// one drawing.
///
/// **A sheet credits what it used and nothing else.** A map of Everest does not
/// owe EMODnet a line, and padding a credit list with sources that did not draw
/// anything is its own kind of dishonesty — it makes the true entries harder to
/// trust.
public enum SheetAttribution {

    /// The sources behind a scene, in the order they were recorded.
    ///
    /// **Two keys, because there are two ways to fetch.** The merge writes
    /// `sources` as a comma-separated list; a single provider fetched directly
    /// never goes through the merge and writes only `source`, which is the bare
    /// provider ID — or, from the merge, the same list joined with `+`. Reading
    /// only the plural credited nothing at all on a plain terrain sheet, which is
    /// the commonest export this application makes, and it was invisible until a
    /// real render was inspected: the sheet still carried EMODnet's line, so the
    /// attribute was present and merely incomplete.
    public static func sources(in scene: RenderScene) -> [String] {
        let listed = scene.metadata["sources"]?.stringValue
            ?? scene.metadata["source"]?.stringValue
            ?? ""
        var found = listed
            .split(whereSeparator: { $0 == "," || $0 == "+" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "unknown" && $0 != "none" }

        // **EMODnet has no provider of its own.** It is blended into the
        // elevation grid inside `TerrainTileProvider`, so a sheet standing on it
        // reports `terrain_tiles` and would otherwise credit nobody for the one
        // source here whose licence explicitly asks for a line. What the sheet
        // does record is which grid the depths came from, so that is what is
        // read.
        //
        // Both key forms are checked: the merge namespaces a provider's metadata
        // by source, and a single-provider fetch does not go through the merge
        // at all.
        let usedEMODnet = scene.metadata.contains { key, value in
            (key == "bathymetry_source" || key.hasSuffix(".bathymetry_source"))
                && (value.stringValue?.contains("emodnet") ?? false)
        }
        if usedEMODnet, !found.contains(emodnetBathymetrySourceID) {
            found.append(emodnetBathymetrySourceID)
        }
        return found
    }

    /// What the exported file says it owes. Empty when it owes nothing.
    public static func statement(for scene: RenderScene) -> String {
        AttributionRegistry.statement(forSources: sources(in: scene))
    }

    public static func attributions(for scene: RenderScene) -> [Attribution] {
        AttributionRegistry.attributions(forSources: sources(in: scene))
    }
}
