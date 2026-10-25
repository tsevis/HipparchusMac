import Foundation

/// The road classes, drawn as one network.
///
/// Each class is a layer of its own, and a layer lays its casing down across all
/// of its features before it draws a single line, which is why two residential
/// streets meet as one junction. Across classes that was never true: each layer
/// drew casing-then-line in turn, so whichever class came later cut the earlier
/// one at every crossing, and a city's orange roads came out beaded.
///
/// So for a run of road layers next to each other in the draw order, every
/// casing in the run goes down first, and then every line, in the run's own
/// order: minor to major, so the major road is the last ink at its junctions
/// and a minor street's line still reaches the major road's edge.
///
/// Both renderers walk these turns, so the PNG, the PDF and the SVG agree.
public enum RoadNetwork {

    /// The layers that make up the network: the classes and the generic layer
    /// the classes are split from.
    static let layers: Set<String> = Set(SceneBuilder.roadHierarchy + ["roads"])

    public enum Part: Sendable, Equatable {
        /// Casing, fill and line, as a layer outside the network draws.
        case whole
        /// A road layer's casing, lifted ahead of the lines of its run.
        case casing
        /// Everything of a road layer but its casing, and its labels.
        case body
    }

    public struct Turn {
        public let layer: RenderLayer
        public let part: Part
    }

    /// `layers` in the order they are drawn, as turns.
    ///
    /// Every layer of a run keeps a body turn, even with no casing and no
    /// geometry, because that turn is where the SVG writes its group and labels.
    public static func turns(of layers: [RenderLayer]) -> [Turn] {
        var turns: [Turn] = []
        var run: [RenderLayer] = []

        func flush() {
            for layer in run where layer.style.casingWidth > 0 && !layer.geometries.isEmpty {
                turns.append(Turn(layer: layer, part: .casing))
            }
            for layer in run { turns.append(Turn(layer: layer, part: .body)) }
            run = []
        }

        for layer in layers {
            if Self.layers.contains(layer.name) {
                run.append(layer)
            } else {
                flush()
                turns.append(Turn(layer: layer, part: .whole))
            }
        }
        flush()
        return turns
    }
}
