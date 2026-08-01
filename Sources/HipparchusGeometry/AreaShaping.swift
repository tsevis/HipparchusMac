import Foundation

/// An area shaped like the window that will draw it.
///
/// The canvas fits a map by the tighter of its two dimensions, so an area
/// whose proportions differ from the window's is drawn small and centred with
/// dead space along the other axis — a square request in a wide window fills
/// barely half of it. Nothing is wrong with the fit; the request is simply the
/// wrong shape. Widening it to the window's own proportions is what makes the
/// drawn map fill the window.
///
/// Everything here works in *projected* space, not degrees. Mercator stretches
/// latitude by roughly `1/cos(latitude)`, so at Athens a degree of latitude is
/// about 1.27 times the height a degree of longitude is wide — an area that is
/// square in degrees is distinctly tall on screen, and shaping it by degrees
/// alone would leave the letterbox it was meant to remove.
public enum AreaShaping {

    /// How wide the area is relative to its height, as drawn.
    ///
    /// `WebMercator.pixel` at a fixed zoom is only a convenient way to reach
    /// the projection's `y`: the zoom cancels in the ratio, so the number is
    /// the shape of the area on any screen at any scale.
    public static func projectedAspect(of bbox: BoundingBox) -> Double {
        let height = projectedHeight(of: bbox)
        guard height > 0 else { return .nan }
        return bbox.lonSpan / height
    }

    /// The same area, widened or heightened to match a window of this shape.
    ///
    /// `aspect` is the window's width divided by its height, in points.
    ///
    /// Only ever grown, never cropped: pressing Render map must not quietly
    /// drop part of the area that was asked for. Growing the deficient axis
    /// alone also makes this idempotent — an area already the right shape
    /// comes back untouched, so pressing the button twice does not walk the
    /// map outwards a little each time.
    public static func shaped(_ bbox: BoundingBox, toAspect aspect: Double) -> BoundingBox {
        let lonSpan = bbox.lonSpan
        let projectedHeight = projectedHeight(of: bbox)
        guard aspect.isFinite, aspect > 0, lonSpan > 0, projectedHeight > 0 else { return bbox }

        let current = lonSpan / projectedHeight
        let centreLat = (bbox.minLat + bbox.maxLat) / 2
        let centreLon = (bbox.minLon + bbox.maxLon) / 2

        if abs(current - aspect) < 1e-12 { return bbox }

        if current < aspect {
            // Too tall for the window: widen it.
            let wanted = projectedHeight * aspect
            return clamped(
                centreLat: centreLat, centreLon: centreLon,
                latSpan: bbox.latSpan, lonSpan: wanted
            )
        }

        // Too wide for the window: heighten it. The new height is asked for in
        // projected units and has to be turned back into degrees, which is not
        // a multiplication — the stretch differs at the top and the bottom of
        // a tall box — so the latitudes come from the projection's own inverse.
        let wantedHeight = lonSpan / aspect
        let centreY = mercatorY(centreLat)
        let half = wantedHeight / 2
        let north = latitude(forMercatorY: centreY + half)
        let south = latitude(forMercatorY: centreY - half)
        return clamped(
            centreLat: (north + south) / 2, centreLon: centreLon,
            latSpan: north - south, lonSpan: lonSpan
        )
    }

    // MARK: - The projection, reduced to the one thing this needs

    /// Height of the area in projected units, in the same units `lonSpan` is
    /// measured in — degrees of longitude at the equator, which is what the
    /// Mercator `y` below is scaled to.
    static func projectedHeight(of bbox: BoundingBox) -> Double {
        mercatorY(bbox.maxLat) - mercatorY(bbox.minLat)
    }

    /// Mercator `y`, in degrees-of-longitude units so it can be compared
    /// directly against a longitude span.
    static func mercatorY(_ latitude: Double) -> Double {
        let clamped = Swift.min(Swift.max(latitude, -WebMercator.maxLatitude), WebMercator.maxLatitude)
        let radians = clamped * .pi / 180
        return log(tan(.pi / 4 + radians / 2)) * 180 / .pi
    }

    static func latitude(forMercatorY y: Double) -> Double {
        let radians = y * .pi / 180
        return (2 * atan(exp(radians)) - .pi / 2) * 180 / .pi
    }

    /// Kept inside the real world, and kept a real area. `BoundingBox`'s own
    /// centre-and-span initialiser already clamps to the world's edges; this
    /// only guards the degenerate result that clamping can leave behind.
    private static func clamped(
        centreLat: Double, centreLon: Double, latSpan: Double, lonSpan: Double
    ) -> BoundingBox {
        let box = BoundingBox(
            centerLat: centreLat, centerLon: centreLon,
            latSpan: latSpan, lonSpan: lonSpan
        )
        guard box.lonSpan > 0, box.latSpan > 0 else {
            return BoundingBox(
                centerLat: centreLat, centerLon: centreLon,
                latSpan: Swift.max(latSpan, 1e-6), lonSpan: Swift.max(lonSpan, 1e-6)
            )
        }
        return box
    }
}
