import Foundation

/// Colour as an axis of its own, separate from the preset.
///
/// **No Python counterpart, and the reason it is worth having.** A preset here
/// is a whole sheet: thirty-seven layer styles, hand-chosen, colour and weight
/// and opacity together. That makes "the same map in different colours" a thing
/// you cannot ask for — you can only pick a different sheet, and the geometry
/// and the emphasis come with it whether you wanted them or not.
///
/// `Scripts/build-style-packs.py` already solved this, at build time: its
/// `sheet()` derives all thirty-seven styles from eight named colours, which is
/// exactly a palette engine, run once by a script and frozen into JSON. This is
/// that function, in Swift, at runtime. The style packs stay as they are —
/// generated, editable, and free to disagree with this — but any palette can now
/// be applied to any preset without a build step and without a combinatorial
/// explosion of shipped presets.
///
/// The derivation is deliberately the same one, mix for mix. If a pack and a
/// palette of the same colours disagreed, one of them would be wrong, and there
/// would be no way to tell which.

/// The eight colours a whole map can be derived from.
public struct Palette: Sendable, Equatable, Identifiable {
    public let name: String
    /// The paper. Everything else is mixed towards or away from it.
    public let ground: RGBAColor
    /// The darkest thing on a pale sheet, the lightest on a dark one.
    public let ink: RGBAColor
    public let water: RGBAColor
    public let land: RGBAColor
    public let road: RGBAColor
    public let roadCasing: RGBAColor
    public let vegetation: RGBAColor
    public let contour: RGBAColor
    /// Roads at a chart's weight rather than a street map's.
    public let roadScale: Double
    public let contourWeight: Double
    /// A chart fills its sea; a land map often leaves it as paper.
    public let fillsSea: Bool

    /// Explicit hypsometric ramps, for a palette that colours the ground by
    /// height and depth rather than leaving it a flat fill. Both stops of a ramp
    /// must be set for it to apply; left nil the layer keeps its *derived*
    /// colour, so every palette written before these existed is untouched.
    /// `elevationLow` is the plain and `elevationHigh` the summit; `depthShallow`
    /// the coast and `depthDeep` the abyss.
    public let elevationLow: RGBAColor?
    public let elevationHigh: RGBAColor?
    public let depthShallow: RGBAColor?
    public let depthDeep: RGBAColor?

    /// The sub-sea depth contours' own colour, so a black sea can still carry
    /// its oceanography as bright linework — the ocean's twin of the land's
    /// glowing terrain contours. Nil keeps the derived, dim bathymetry every
    /// other palette draws.
    public let seaContour: RGBAColor?

    public var id: String { name }

    public init(
        name: String,
        ground: RGBAColor,
        ink: RGBAColor,
        water: RGBAColor,
        land: RGBAColor,
        road: RGBAColor,
        roadCasing: RGBAColor,
        vegetation: RGBAColor,
        contour: RGBAColor,
        roadScale: Double = 1.0,
        contourWeight: Double = 1.0,
        fillsSea: Bool = true,
        elevationLow: RGBAColor? = nil,
        elevationHigh: RGBAColor? = nil,
        depthShallow: RGBAColor? = nil,
        depthDeep: RGBAColor? = nil,
        seaContour: RGBAColor? = nil
    ) {
        self.name = name
        self.ground = ground
        self.ink = ink
        self.water = water
        self.land = land
        self.road = road
        self.roadCasing = roadCasing
        self.vegetation = vegetation
        self.contour = contour
        self.roadScale = roadScale
        self.contourWeight = contourWeight
        self.fillsSea = fillsSea
        self.elevationLow = elevationLow
        self.elevationHigh = elevationHigh
        self.depthShallow = depthShallow
        self.depthDeep = depthDeep
        self.seaContour = seaContour
    }
}

extension Palette {
    /// The name that means "leave the preset's own colours alone".
    public static let presetOwnName = "Preset's own"

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBAColor { RGBAColor(r, g, b) }

    /// The two brand colours the style packs are built from, kept here so a
    /// palette and its pack cannot drift apart.
    static let turquoise = rgb(26, 175, 165)
    static let blue = rgb(55, 97, 160)
    static let white = rgb(255, 255, 255)
    static let deepInk = rgb(17, 34, 51)

    /// The palettes offered. Each is a set of colours and nothing else — no
    /// geometry, no weights beyond the two scale factors a chart needs — so any
    /// of them can be laid over any preset.
    public static let all: [Palette] = [
        Palette(
            name: "Tsevis Daylight",
            ground: mix(white, blue, 0.04),
            ink: mix(blue, deepInk, 0.55),
            water: turquoise,
            land: blue,
            road: white,
            roadCasing: mix(blue, white, 0.62),
            vegetation: mix(turquoise, mix(white, deepInk, 0.25), 0.55),
            contour: mix(blue, white, 0.55)
        ),
        Palette(
            name: "Tsevis Nocturne",
            ground: mix(deepInk, blue, 0.30),
            ink: mix(white, turquoise, 0.30),
            water: mix(turquoise, deepInk, 0.50),
            land: mix(blue, deepInk, 0.40),
            road: mix(turquoise, white, 0.50),
            roadCasing: mix(deepInk, blue, 0.20),
            vegetation: mix(turquoise, deepInk, 0.62),
            contour: mix(blue, turquoise, 0.4)
        ),
        Palette(
            name: "Admiralty",
            ground: rgb(247, 241, 224),
            ink: rgb(26, 58, 82),
            water: rgb(176, 214, 224),
            land:mix(rgb(247, 241, 224), rgb(198, 186, 150), 0.55),
            road:mix(rgb(247, 241, 224), rgb(26, 58, 82), 0.35),
            roadCasing: rgb(247, 241, 224),
            vegetation:mix(rgb(247, 241, 224), rgb(170, 180, 140), 0.35),
            contour:mix(rgb(247, 241, 224), rgb(26, 58, 82), 0.30),
            roadScale: 0.55,
            contourWeight: 1.6
        ),
        duotone(name: "Riso Teal & Coral", first: rgb(0, 160, 152),
                second: rgb(255, 102, 94), paper: rgb(250, 246, 238)),
        duotone(name: "Riso Blue & Ochre", first: blue,
                second: rgb(219, 158, 47), paper: rgb(248, 244, 235)),
        Palette(
            name: "Sepia",
            ground: rgb(246, 238, 222),
            ink: rgb(64, 46, 32),
            water: rgb(190, 190, 172),
            land: rgb(196, 168, 132),
            road: rgb(252, 248, 238),
            roadCasing: rgb(160, 132, 100),
            vegetation: rgb(150, 152, 108),
            contour: rgb(150, 122, 88)
        ),
        Palette(
            name: "Botanical",
            ground: rgb(247, 245, 236),
            ink: rgb(38, 54, 40),
            water: rgb(158, 194, 196),
            land: rgb(214, 206, 186),
            road: rgb(252, 251, 246),
            roadCasing: rgb(176, 178, 156),
            vegetation: rgb(96, 132, 84),
            contour: rgb(140, 158, 128)
        ),
        Palette(
            name: "Slate",
            ground: rgb(30, 34, 38),
            ink: rgb(226, 232, 236),
            water: rgb(52, 76, 92),
            land: rgb(58, 64, 70),
            road: rgb(188, 196, 202),
            roadCasing: rgb(24, 28, 32),
            vegetation: rgb(58, 78, 62),
            contour: rgb(96, 108, 118)
        ),
        // MARK: Named for people who drew the world, or went and looked at it
        //
        // Eight colours each, anchored on swatch sets rather than invented at
        // the keyboard: `Scripts/ase-to-hex.swift` reads the `.ase` files these
        // came from, so the provenance of any one of them is a command away.
        // Where a set had no colour for a role — a three-ink palette has no
        // sea — the missing one is *mixed* from the ones it does have rather
        // than picked, which is the same rule the whole engine runs on.

        /// Claudius Ptolemy, Alexandria, second century: the Geographia gave
        /// the world its first grid of latitude and longitude. Cream vellum,
        /// violet contours, a turquoise Mediterranean.
        Palette(
            name: "Ptolemy",
            ground: rgb(244, 239, 233),
            ink: rgb(11, 4, 11),
            water: rgb(98, 164, 231),
            land: rgb(252, 187, 159),
            road: white,
            roadCasing: rgb(192, 183, 246),
            vegetation: rgb(188, 227, 232),
            contour: rgb(102, 46, 145)
        ),

        /// Pytheas of Massalia sailed north until the sea froze and reported a
        /// place where the sun did not set, which nobody believed for
        /// centuries. A sheet for the dark.
        Palette(
            name: "Pytheas",
            ground: rgb(2, 0, 11),
            ink: rgb(247, 244, 229),
            water: rgb(44, 18, 178),
            land: rgb(89, 28, 67),
            road: rgb(197, 237, 237),
            roadCasing: rgb(57, 20, 39),
            vegetation: rgb(89, 184, 127),
            contour: rgb(88, 124, 191)
        ),

        /// Vincenzo Coronelli, Venice: globes four metres across for the king
        /// of France, and a cosmographer's taste for colour that a modern
        /// atlas would call excessive.
        Palette(
            name: "Coronelli",
            ground: mix(white, rgb(234, 170, 163), 0.18),
            // The swatch set's ink, taken down towards the deep ink. Straight,
            // at rgb(22, 67, 177), it was within a few units of this palette's
            // own water — every derivation that mixes a line "towards ink" for
            // something sitting on the sea (the coastline, the bathymetry
            // contours, the deep end of the depth ramp, a hazard's stroke)
            // barely moved, and the water drew as one flat wash with no
            // coastline in it at all. Judged on a terrain-only sheet, where the
            // sea is a third of the drawing rather than a border round a city,
            // this was the weakest of the seventeen.
            //
            // Halfway to the deep ink keeps the hue — it is still recognisably
            // Coronelli's blue, not a neutral grey — while separating its luma
            // and saturation from the water enough that a line mixed towards
            // it actually reads as a line.
            ink: mix(rgb(22, 67, 177), deepInk, 0.5),
            water: rgb(28, 94, 178),
            land: rgb(203, 119, 6),
            road: white,
            roadCasing: rgb(241, 128, 101),
            vegetation: mix(rgb(42, 172, 9), white, 0.45),
            // The swatch set's magenta, taken down towards the deep ink.
            // Straight, at luma 96, it was the lightest contour of the
            // seventeen and the sheet read washed: pink lines over ochre
            // buildings, neither holding the other down.
            //
            // Mixing towards this palette's blue was the first attempt and it
            // was the wrong axis — it moved the hue to violet and the luma only
            // to 82, so against warm ochre it still read light. Towards the ink
            // instead takes it to 60, which is darkening rather than merely
            // cooling, and keeps enough magenta that it is still Coronelli's
            // colour rather than a neutral grey.
            contour: mix(rgb(191, 35, 161), deepInk, 0.55)
        ),

        /// Paolo dal Pozzo Toscanelli, Florence, who put Asia close enough to
        /// the west of Europe that sailing there sounded reasonable. Columbus
        /// carried a copy of his letter.
        Palette(
            name: "Toscanelli",
            ground: mix(white, rgb(220, 143, 90), 0.12),
            ink: rgb(41, 25, 28),
            water: rgb(116, 219, 174),
            land: rgb(176, 90, 58),
            road: white,
            roadCasing: rgb(220, 143, 90),
            vegetation: mix(rgb(116, 219, 174), rgb(41, 25, 28), 0.45),
            contour: mix(rgb(176, 90, 58), white, 0.35)
        ),

        /// Amerigo Vespucci, Florence, who worked out that the land in the way
        /// was not Asia but somewhere else entirely — and had two continents
        /// named after him for saying so.
        Palette(
            name: "Vespucci",
            ground: rgb(41, 25, 28),
            ink: rgb(220, 143, 90),
            water: rgb(61, 120, 172),
            land: rgb(109, 56, 45),
            road: rgb(220, 143, 90),
            roadCasing: rgb(33, 55, 96),
            vegetation: rgb(68, 150, 81),
            contour: rgb(116, 219, 174)
        ),

        /// John Wesley Powell ran the Colorado through the Grand Canyon in
        /// 1869 with one arm and no maps, and came back with the maps. Canyon
        /// strata: sienna, ochre, and a green river.
        Palette(
            name: "Powell",
            ground: rgb(205, 227, 202),
            ink: rgb(29, 21, 22),
            water: rgb(54, 139, 154),
            land: rgb(165, 93, 51),
            road: mix(white, rgb(205, 227, 202), 0.35),
            roadCasing: rgb(133, 67, 41),
            vegetation: rgb(29, 92, 83),
            contour: rgb(205, 117, 62)
        ),

        /// John C. Frémont surveyed the American West five times and was
        /// called the Pathfinder for it. Clay, khaki and slate — three inks,
        /// which is all a field survey ever carried.
        Palette(
            name: "Frémont",
            ground: mix(white, rgb(182, 165, 114), 0.22),
            ink: rgb(46, 42, 61),
            // No sea in a three-ink set, so the water is the slate let down
            // toward the paper rather than a fourth colour smuggled in.
            water: mix(rgb(46, 42, 61), white, 0.42),
            land: rgb(144, 91, 75),
            road: white,
            roadCasing: rgb(182, 165, 114),
            vegetation: mix(rgb(182, 165, 114), rgb(46, 42, 61), 0.35),
            contour: mix(rgb(144, 91, 75), white, 0.30)
        ),

        Palette(
            name: "High Contrast Light",
            ground: white, ink: rgb(0, 0, 0),
            water: mix(white, rgb(0, 0, 0), 0.28),
            land: white, road: rgb(0, 0, 0), roadCasing: white, vegetation: white,
            contour: mix(white, rgb(0, 0, 0), 0.35),
            roadScale: 1.8
        ),
        Palette(
            name: "High Contrast Dark",
            ground: rgb(0, 0, 0), ink: white,
            water:mix(rgb(0, 0, 0), white, 0.28),
            land: rgb(0, 0, 0), road: white, roadCasing: rgb(0, 0, 0), vegetation: rgb(0, 0, 0),
            contour:mix(rgb(0, 0, 0), white, 0.35),
            roadScale: 1.8
        ),

        // Limassol Towel — a dark bathymetric HUD. Land and sea are black; all
        // the colour is in the lines. Warm contours trace the relief, cool ones
        // trace the sea floor, and the two meet at a hard-lit coast. The sea is
        // not an empty void but its own instrument: a black surface carrying its
        // depth as bright sub-sea contours, the ocean's answer to the land's.
        // Pure black grounds, for the most contrast the sheet can hold. Three
        // variations, one idea, differing in the colour of the light.

        // The sea is greyscale — depth read as many greys, light on the shelves
        // to black in the trenches, the way a bathymetric chart states it — with
        // its sub-sea contours a shade brighter again. Warm relief over the land,
        // neutral depth over the water, and the coast where near-black land meets
        // light-grey shelf is the hardest edge on the sheet.

        // 1. Gold land, grey sea — a nautical plotter.
        Palette(
            name: "Limassol Towel",
            ground: rgb(0, 0, 0),
            ink: rgb(255, 193, 46),
            water: rgb(0, 0, 0),
            land: rgb(255, 193, 46),
            road: rgb(255, 193, 46),
            roadCasing: rgb(0, 0, 0),
            vegetation: rgb(26, 28, 32),
            contour: rgb(255, 193, 46),
            roadScale: 0.7,
            contourWeight: 1.3,
            elevationLow: rgb(30, 26, 12),   // land: near-black amber
            elevationHigh: rgb(0, 0, 0),
            depthShallow: rgb(137, 137, 137),  // shelf: light grey
            depthDeep: rgb(0, 0, 0),          // trench: black
            seaContour: rgb(205, 205, 205)   // sub-sea contours: brighter grey
        ),

        // 2. Noir — a cold monochrome screen. White relief, grey sea, one warm
        // accent left in the roads.
        Palette(
            name: "Limassol Towel Noir",
            ground: rgb(0, 0, 0),
            ink: rgb(255, 255, 255),
            water: rgb(0, 0, 0),
            land: rgb(30, 32, 36),
            road: rgb(255, 193, 46),
            roadCasing: rgb(0, 0, 0),
            vegetation: rgb(22, 24, 28),
            contour: rgb(230, 234, 240),
            roadScale: 0.7,
            contourWeight: 1.2,
            elevationLow: rgb(14, 15, 18),
            elevationHigh: rgb(0, 0, 0),
            depthShallow: rgb(137, 137, 137),
            depthDeep: rgb(0, 0, 0),
            seaContour: rgb(215, 215, 215)
        ),

        // 3. Neon — the most wired. Gold relief under white index lines, grey
        // sea, thickest linework, deepest black.
        Palette(
            name: "Limassol Towel Neon",
            ground: rgb(0, 0, 0),
            ink: rgb(255, 255, 255),
            water: rgb(0, 0, 0),
            land: rgb(38, 32, 16),
            road: rgb(255, 193, 46),
            roadCasing: rgb(0, 0, 0),
            vegetation: rgb(26, 24, 14),
            contour: rgb(255, 193, 46),
            roadScale: 0.65,
            contourWeight: 1.5,
            elevationLow: rgb(34, 28, 12),
            elevationHigh: rgb(0, 0, 0),
            depthShallow: rgb(150, 150, 150),
            depthDeep: rgb(0, 0, 0),
            seaContour: rgb(220, 220, 220)
        ),
    ]

    public static var names: [String] { [presetOwnName] + all.map(\.name) }

    public static func named(_ name: String) -> Palette? {
        all.first { $0.name == name }
    }

    /// Two inks and paper, the way a risograph prints: nothing is a shade of
    /// anything, every colour is one of the two inks or one let down toward the
    /// paper.
    private static func duotone(
        name: String, first: RGBAColor, second: RGBAColor, paper: RGBAColor
    ) -> Palette {
        Palette(
            name: name,
            ground: paper,
            ink: mix(first, deepInk, 0.25),
            water: second,
            land: first,
            road: paper,
            roadCasing: mix(first, paper, 0.35),
            vegetation: mix(second, paper, 0.45),
            contour: mix(second, paper, 0.35)
        )
    }
}
