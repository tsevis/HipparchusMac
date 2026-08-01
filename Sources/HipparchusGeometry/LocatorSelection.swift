/// What a click and a zoom button on the locator mean, in degrees.
///
/// Held here rather than in the view for the usual reason: the view is an
/// `MKMapView` in a floating window that nothing can click in a test, while
/// this is arithmetic with right and wrong answers. The view is left with only
/// the part that genuinely needs MapKit — turning a point in the window into a
/// latitude and longitude — and everything decided about that point is decided
/// here, where it can be checked.
public enum LocatorSelection {

    /// The area a single click stands for.
    ///
    /// A click names a place, not an extent, so it has to be given one. The
    /// same one a pasted point gets: a point copied off Google Maps and the
    /// same point clicked here describe the same place, and it would be a
    /// strange app that framed them differently.
    public static func area(around lat: Double, lon: Double) -> BoundingBox {
        CoordinateImport.padded(lat: lat, lon: lon)
    }

    // MARK: - The zoom buttons

    /// Past this the locator is showing more than there is, and MapKit will
    /// refuse anyway — the view has its own smaller limit besides, which
    /// depends on how many pixels wide it is.
    static let maxLatSpan = 170.0
    static let maxLonSpan = 360.0
    /// About a hundred metres. Not a limit anyone will meet by accident: it is
    /// far tighter than the smallest saved place, and stops a held-down zoom
    /// button from grinding the box down to a point, which is not an area and
    /// so is not something `Render map` would agree to fetch.
    static let minSpan = 0.001

    /// The area left showing after a zoom button.
    ///
    /// Greater than one zooms in, matching `ViewportState.zoomed(by:)` on the
    /// main canvas, so `1.6` and `1 / 1.6` are the pair of buttons in both
    /// places and mean the same thing in both.
    ///
    /// The centre is held still and the shape is kept: both spans are scaled by
    /// one factor, so a box twice as wide as it is tall stays twice as wide
    /// even when one of its sides is what runs into the limit.
    public static func zoomed(_ bbox: BoundingBox, by factor: Double) -> BoundingBox {
        let latSpan = abs(bbox.latSpan)
        let lonSpan = abs(bbox.lonSpan)
        // Nothing to scale, and nothing to divide by.
        guard latSpan > 0, lonSpan > 0, factor > 0 else { return bbox }

        let widest = Swift.min(maxLatSpan / latSpan, maxLonSpan / lonSpan)
        let tightest = Swift.max(minSpan / latSpan, minSpan / lonSpan)
        // `min` last, so an impossible box — one whose floor is already past
        // its ceiling — resolves to the ceiling rather than to nonsense.
        let scale = Swift.min(Swift.max(1 / factor, tightest), widest)

        return BoundingBox(
            centerLat: (bbox.minLat + bbox.maxLat) / 2,
            centerLon: (bbox.minLon + bbox.maxLon) / 2,
            latSpan: latSpan * scale,
            lonSpan: lonSpan * scale
        )
    }
}
