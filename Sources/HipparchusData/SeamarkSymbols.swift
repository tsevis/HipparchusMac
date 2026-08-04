import Foundation
import HipparchusGeometry

/// Chart symbols for sea marks, as geometry rather than as a sprite sheet.
///
/// The first version of this feature drew every mark as a dot. That put the
/// marks in the right places, which is the half that had to be right first, and
/// left a cardinal buoy and a wreck looking identical — which on a chart is most
/// of the information missing.
///
/// **There is no sprite sheet, and there should not be.** This application draws
/// vectors and exports SVG and PDF; an image would have nowhere to go in either,
/// and a symbol font would arrive at the printer as a font nobody has. So a
/// symbol here is real geometry, generated per mark, and it comes out of
/// Illustrator as editable paths like everything else.
///
/// **Shape carries the meaning, not colour.** A real chart uses both, and the
/// redundancy is deliberate: a can is red *and* square, a cone is green *and*
/// pointed, so a mariner can identify a mark in flat light or through
/// colour-blind eyes. Taking the shape half and leaving the colour half is
/// therefore not a compromise — it is the half that was designed to work alone.
/// It also keeps the palette rule intact: every colour on a sheet is still
/// derived from the palette's eight, and no mark smuggles in a ninth.
///
/// **Sizing follows `USGSProvider`**, which had this problem first: a symbol
/// measured in degrees is invisible across a sea and enormous across a harbour.
/// Everything below is a fraction of the frame's shorter side, and corrected by
/// `cos(latitude)` so a symbol is round on the *map* rather than round in
/// degrees — an uncorrected one flattens into an ellipse as the map moves north.
///
/// The vocabulary is deliberately smaller than INT-1's. It distinguishes the
/// classes a reader has to tell apart at a glance, and says so rather than
/// implying a completeness it does not have.
public enum SeamarkSymbols {

    /// One piece of a symbol. A mark can need several — a cardinal buoy is two
    /// topmark cones, a light is a flare and the point it shines from.
    public struct Part: Sendable, Equatable {
        /// Unit-space coordinates, centred on the mark, y up, roughly -1…1.
        public let points: [(x: Double, y: Double)]
        /// Closed shapes become polygons and take the layer's fill; open ones
        /// stay lines. Which it is says what the shape *is* — a can is a body,
        /// a saltire is two strokes.
        public let closed: Bool

        public init(_ points: [(x: Double, y: Double)], closed: Bool) {
            self.points = points
            self.closed = closed
        }

        public static func == (a: Part, b: Part) -> Bool {
            a.closed == b.closed && a.points.count == b.points.count
                && zip(a.points, b.points).allSatisfy { $0.x == $1.x && $0.y == $1.y }
        }
    }

    // MARK: - The shapes

    /// A circle of `radius` in unit space.
    static func circle(radius: Double, segments: Int = 24, centre: (x: Double, y: Double) = (0, 0)) -> Part {
        Part((0..<segments).map { step in
            let angle = 2 * Double.pi * Double(step) / Double(segments)
            return (x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }, closed: true)
    }

    /// A cone, the shape half of a lateral starboard mark and the building block
    /// of every cardinal topmark. `up` is which way the point faces.
    static func cone(up: Bool, halfWidth: Double = 0.55, bottom: Double, top: Double) -> Part {
        up
            ? Part([(-halfWidth, bottom), (halfWidth, bottom), (0, top)], closed: true)
            : Part([(-halfWidth, top), (halfWidth, top), (0, bottom)], closed: true)
    }

    /// A can — the shape half of a lateral port mark. Flat-topped on purpose:
    /// against a cone it is the one distinction that survives being small.
    static let can = Part(
        [(-0.5, -0.75), (0.5, -0.75), (0.5, 0.75), (-0.5, 0.75)], closed: true
    )

    /// Two crossing strokes. A special-purpose mark carries an X topmark, and a
    /// rock is drawn with one too.
    static let saltire: [Part] = [
        Part([(-0.7, -0.7), (0.7, 0.7)], closed: false),
        Part([(-0.7, 0.7), (0.7, -0.7)], closed: false),
    ]

    /// The cardinal topmarks, which are the whole of what a cardinal mark says.
    ///
    /// Two cones, and their arrangement names the quadrant of *safe water*:
    /// north points up, south points down, east is base to base — the egg — and
    /// west is point to point, the wine glass. Those two mnemonics are how the
    /// marks are taught, and they are exactly the shapes below.
    static func cardinal(_ quadrant: String) -> [Part] {
        switch quadrant {
        case "north":
            return [cone(up: true, bottom: 0.05, top: 0.95),
                    cone(up: true, bottom: -0.95, top: -0.05)]
        case "south":
            return [cone(up: false, bottom: 0.05, top: 0.95),
                    cone(up: false, bottom: -0.95, top: -0.05)]
        case "east":
            // Base to base: the egg.
            return [cone(up: true, bottom: 0.05, top: 0.95),
                    cone(up: false, bottom: -0.95, top: -0.05)]
        default:
            // Point to point: the wine glass. Also the fallback, because a
            // cardinal mark whose quadrant is missing is still a cardinal mark.
            return [cone(up: false, bottom: 0.05, top: 0.95),
                    cone(up: true, bottom: -0.95, top: -0.05)]
        }
    }

    /// Two spheres, stacked: an isolated danger, which marks a hazard with
    /// navigable water all round it.
    static let isolatedDanger: [Part] = [
        circle(radius: 0.32, segments: 16, centre: (0, 0.45)),
        circle(radius: 0.32, segments: 16, centre: (0, -0.45)),
    ]

    /// The light flare, which is the one symbol on a chart everybody recognises:
    /// a teardrop leaning away from the structure, and a dot at the position
    /// itself so the light is still *somewhere* exact.
    ///
    /// **Drawn larger than a buoy, and with a smaller dot than looks right on
    /// paper.** The first version read cleanly on a 1600-pixel sheet and turned
    /// into a starburst on a 900-pixel one: the flare and the position dot are a
    /// fraction of a millimetre apart at chart scale, so the dot filled the
    /// throat of the teardrop and the two merged. A chart draws the flare big
    /// for the same reason — it is the symbol you find from a distance — so the
    /// outline runs past the unit box and the dot is pulled in until the gap
    /// survives being small.
    ///
    /// Found in the Python port first, at its lower plate resolution, and
    /// brought back here so both applications draw one symbol rather than two.
    static let light: [Part] = [
        Part([
            (0, 0), (0.42, 0.78), (0.88, 1.28), (1.22, 1.45),
            (1.02, 0.97), (0.62, 0.43),
        ], closed: true),
        circle(radius: 0.10, segments: 12),
    ]

    /// A wreck, drawn the way a chart draws one: the hull as a line at the
    /// waterline with three masts standing out of it. Unmistakable at any size,
    /// which is the entire requirement for the one symbol that means "not here".
    static let wreck: [Part] = [
        Part([(-0.85, 0), (0.85, 0)], closed: false),
        Part([(-0.45, -0.35), (-0.45, 0.45)], closed: false),
        Part([(0, -0.45), (0, 0.6)], closed: false),
        Part([(0.45, -0.35), (0.45, 0.45)], closed: false),
    ]

    /// A rock: the saltire, with a dot to say there is something solid at the
    /// middle of it rather than merely a caution.
    static let rock: [Part] = saltire + [circle(radius: 0.14, segments: 10)]

    /// A beacon stands on the ground, so it keeps its topmark and gains a stem.
    /// That single stroke is the whole difference between a mark that floats and
    /// one that does not, and it is the difference a reader most needs.
    static let stem = Part([(0, -0.95), (0, -0.2)], closed: false)

    // MARK: - Choosing one

    /// The symbol for a mark, from its tags.
    ///
    /// Reads `seamark:type` for the class and `seamark:<type>:category` for the
    /// variety, which is where OSM puts the thing that actually distinguishes
    /// one buoy from another. Returns `nil` when nothing is known, and the
    /// caller falls back to a dot — a mark in the right place with no shape is
    /// better than no mark.
    public static func parts(for tags: [String: Any]) -> [Part]? {
        guard let rawType = tags[Seamarks.typeKey] else { return nil }
        let type = string(rawType).lowercased()
        guard !type.isEmpty else { return nil }

        let category = string(tags["seamark:\(type):category"]).lowercased()
        let floats = type.hasPrefix("buoy") || type == "mooring" || type == "float"
        let fixed = type.hasPrefix("beacon") || type == "daymark"
            || type == "pile" || type == "cairn" || type == "tower"

        // The classes that are a shape in themselves, whatever they are mounted on.
        if type.hasPrefix("light") || type == "landmark" { return light }
        if type == "wreck" { return wreck }
        if type == "rock" || type == "obstruction" { return rock }

        guard floats || fixed else { return nil }

        let topmark: [Part]
        switch true {
        case category.hasPrefix("north"), category.hasPrefix("south"),
             category.hasPrefix("east"), category.hasPrefix("west"):
            topmark = cardinal(quadrant(category))
        case category == "port", category == "preferred_channel_starboard":
            topmark = [can]
        case category == "starboard", category == "preferred_channel_port":
            topmark = [cone(up: true, bottom: -0.8, top: 0.9)]
        case category == "safe_water":
            topmark = [circle(radius: 0.7)]
        case category == "isolated_danger":
            topmark = isolatedDanger
        case category == "special_purpose":
            topmark = saltire
        default:
            // A mark whose category OSM does not carry — which is a great many
            // of them — still says whether it floats. A circle for a buoy and a
            // circle on a stem for a beacon is honest about knowing that much
            // and no more.
            topmark = [circle(radius: 0.5)]
        }

        return fixed ? topmark + [stem] : topmark
    }

    /// `north_cardinal`, `cardinal_north` and `north` all mean north.
    static func quadrant(_ category: String) -> String {
        for name in ["north", "south", "east", "west"] where category.contains(name) {
            return name
        }
        return "west"
    }

    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        return (value as? String) ?? "\(value)"
    }

    // MARK: - Putting one on the map

    /// How big a symbol is, as a fraction of the frame's shorter side.
    ///
    /// The same reasoning as `USGSProvider.baseRadiusFraction`: a symbol stated
    /// in degrees is a speck across a sea and a monster across a harbour. This
    /// is smaller than an earthquake's because a chart carries many more marks
    /// than a catalogue carries events, and they must not merge into each other.
    public static let sizeFraction = 0.011

    /// The shorter side of the frame, in degrees of latitude — longitude
    /// corrected for the convergence of the meridians.
    static func span(_ bbox: BoundingBox) -> Double {
        let meanLat = Swift.min(Swift.max((bbox.minLat + bbox.maxLat) / 2, -89.9), 89.9)
        let lonSpan = abs(bbox.maxLon - bbox.minLon) * cos(meanLat * .pi / 180)
        let latSpan = abs(bbox.maxLat - bbox.minLat)
        return [lonSpan, latSpan].filter { $0 > 0 }.min() ?? 1.0
    }

    /// A symbol's parts as geometry at a position, sized against the frame.
    ///
    /// Returns nothing when there is no symbol for these tags, which is the
    /// caller's cue to draw the dot it would have drawn anyway.
    public static func geometry(
        for tags: [String: Any],
        at position: Coordinate,
        in bbox: BoundingBox?
    ) -> [Geometry]? {
        guard let parts = parts(for: tags), !parts.isEmpty else { return nil }
        let size = (bbox.map(span) ?? 1.0) * sizeFraction
        guard size > 0, size.isFinite else { return nil }

        // Longitude is shorter than latitude everywhere but the equator, so an
        // uncorrected symbol leans and flattens as the map moves north.
        let cosLat = Swift.max(0.05, cos(Swift.min(Swift.max(position.lat, -89.9), 89.9) * .pi / 180))

        return parts.compactMap { part in
            let coordinates = part.points.map { point in
                Coordinate(
                    lon: position.lon + size * point.x / cosLat,
                    lat: position.lat + size * point.y
                )
            }
            guard coordinates.count >= 2 else { return nil }
            if part.closed {
                guard coordinates.count >= 3 else { return nil }
                return .polygon(Polygon(exterior: coordinates))
            }
            return .lineString(LineString(coordinates))
        }
    }
}
