import CoreGraphics
import CoreText
import Foundation

/// Which labels a sheet draws, decided once for every renderer.
///
/// Thinning when the scene is built runs a layer at a time with boxes guessed
/// from the character count, so a street name was only ever tested against
/// other street names, a shop against shops: on a city sheet the layers
/// overprinted each other. This runs at drawing time, on the canvas actually
/// being drawn — so the window re-places as it zooms — over every visible
/// layer at once. Each label is measured in the type it is set in, boxed with
/// its halo and turned with its street, and taken in order of importance; one
/// that would touch a label already placed, or run off the canvas, is not
/// drawn. Core Graphics and the SVG writer both ask here, so the files of one
/// sheet carry the same names.
public enum LabelPlacement {

    /// One label: its layer, and its place in that layer's list.
    public struct Key: Hashable, Sendable {
        public let layer: String
        public let index: Int
    }

    /// The face labels are set in on the canvas, measured here in the same face.
    static let fontName = "HelveticaNeue"

    /// Clear space kept around every label, beyond its halo, in points.
    static let gap = 1.0

    /// Side of a spatial-index cell, in points: a few labels across.
    static let cell = 64.0

    /// The labels of `layers` that fit on the canvas `transform` draws onto.
    ///
    /// `typeSize` is the size the type is set at, already scaled for the sheet;
    /// `labelScale` scales each layer's halo, as the renderers do.
    public static func accepted(
        in layers: [RenderLayer], transform: CanvasTransform, typeSize: Double, labelScale: Double
    ) -> Set<Key> {
        let font = CTFontCreateWithName(fontName as CFString, typeSize, nil)
        let canvas = CGRect(origin: .zero, size: transform.canvasSize)

        var placed: [LabelBox] = []
        var index: [Int: [Int]] = [:]
        var accepted = Set<Key>()
        for candidate in candidates(in: layers) {
            let label = candidate.label
            let size = measure(label.name, in: font)
            let pad = candidate.halo * labelScale / 2 + gap
            let box = LabelBox(
                centre: transform.worldToScreen(label.position),
                halfWidth: size.width / 2 + pad, halfHeight: size.height / 2 + pad,
                angle: label.rotation * .pi / 180
            )
            guard box.fits(in: canvas) else { continue }
            let cells = cellKeys(for: box.bounds)
            let neighbours = Set(cells.flatMap { index[$0] ?? [] })
            guard !neighbours.contains(where: { placed[$0].overlaps(box) }) else { continue }
            for key in cells { index[key, default: []].append(placed.count) }
            placed.append(box)
            accepted.insert(candidate.key)
        }
        return accepted
    }

    // MARK: - Order

    /// Every named label, most important first; ties keep the order the scene
    /// gave them, which build-time thinning already ranked within a layer.
    private static func candidates(
        in layers: [RenderLayer]
    ) -> [(key: Key, label: PlaceLabel, halo: Double)] {
        var ranked: [(rank: Int, order: Int, key: Key, label: PlaceLabel, halo: Double)] = []
        for layer in layers {
            for (index, label) in layer.labels.enumerated() where !label.name.isEmpty {
                ranked.append((
                    priority(layer: layer.name, placeType: label.placeType), ranked.count,
                    Key(layer: layer.name, index: index), label, layer.style.labelHaloWidth
                ))
            }
        }
        return ranked
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map { ($0.key, $0.label, $0.halo) }
    }

    /// The layers, most important first. Anything unlisted comes after them.
    static let layerOrder = ["places", "summits", "street_names", "amenities", "shops"]

    /// Settlements, largest first.
    static let placeOrder = ["city", "town", "village", "suburb", "quarter", "hamlet", "neighbourhood"]

    /// Lower draws first and so wins.
    static func priority(layer: String, placeType: String) -> Int {
        let layerRank = layerOrder.firstIndex(of: layer) ?? layerOrder.count
        let typeRank = layer == "places"
            ? placeOrder.firstIndex(of: placeType) ?? placeOrder.count
            : 0
        return layerRank * 100 + typeRank
    }

    // MARK: - Measure and index

    /// The typographic size of a name set in `font`: what both renderers centre
    /// on the label's position.
    static func measure(_ name: String, in font: CTFont) -> CGSize {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let text = CFAttributedStringCreate(nil, name as CFString, attributes) else { return .zero }
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), []).size
    }

    private static func cellKeys(for rect: CGRect) -> [Int] {
        let (minX, maxX) = (Int((rect.minX / cell).rounded(.down)), Int((rect.maxX / cell).rounded(.down)))
        let (minY, maxY) = (Int((rect.minY / cell).rounded(.down)), Int((rect.maxY / cell).rounded(.down)))
        var keys: [Int] = []
        for x in minX...maxX {
            for y in minY...maxY { keys.append(x &* 73_856_093 ^ y &* 19_349_663) }
        }
        return keys
    }
}
