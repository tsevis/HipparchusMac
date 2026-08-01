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
/// that function, in Swift, at runtime. The four packs stay as they are —
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
        fillsSea: Bool = true
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
