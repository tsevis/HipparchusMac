import Foundation

/// Join way fragments into closed rings, and rings into polygons with holes.
///
/// This is what an OSM multipolygon relation needs and does not carry: a relation
/// is a *list of ways*, and the ways are fragments in arbitrary order and arbitrary
/// direction. A coastline is a hundred of them end to end. Until they are stitched
/// there is no ring, and until there is a ring there is no area to fill.
///
/// Kept here rather than in the Overpass decoder because none of it is about
/// Overpass: it is fragments in, rings out, and it is worth testing on its own.
public enum RingAssembly {

    public struct Result: Sendable, Equatable {
        public let rings: [Ring]
        /// Chains that never closed. Kept rather than dropped so a caller can say
        /// how much of a relation it could not use, instead of quietly losing it.
        public let unclosed: [[Coordinate]]

        public init(rings: [Ring], unclosed: [[Coordinate]]) {
            self.rings = rings
            self.unclosed = unclosed
        }
    }

    /// Stitch fragments into closed rings.
    ///
    /// Fragments already closed are taken as they are. The rest are walked end to
    /// end through a map from endpoint to fragment, reversing any that join the
    /// wrong way round, until the chain returns to where it started.
    ///
    /// Linear in total vertices rather than quadratic in fragments, which matters:
    /// the Aegean Sea relation in an Athens fetch has 2 055 outer ways and 1 768
    /// inner ones, and comparing every fragment with every other would be millions
    /// of comparisons for one feature.
    public static func rings(from fragments: [[Coordinate]]) -> Result {
        var rings: [Ring] = []
        var open: [[Coordinate]] = []

        for fragment in fragments {
            guard fragment.count >= 2 else { continue }
            if fragment.count >= 4, fragment.first == fragment.last {
                rings.append(Ring(fragment))
            } else {
                open.append(fragment)
            }
        }
        guard !open.isEmpty else { return Result(rings: rings, unclosed: []) }

        // Both ends of every fragment, so a chain can be extended by lookup rather
        // than by search. OSM shares nodes exactly between joined ways, so the
        // coordinates compare equal without a tolerance.
        var byEndpoint: [Coordinate: [Int]] = [:]
        for (index, fragment) in open.enumerated() {
            byEndpoint[fragment[0], default: []].append(index)
            byEndpoint[fragment[fragment.count - 1], default: []].append(index)
        }

        var used = [Bool](repeating: false, count: open.count)
        var unclosed: [[Coordinate]] = []

        for start in open.indices where !used[start] {
            used[start] = true
            var chain = open[start]

            // Walk forward. Starting part-way round a cycle still traverses all of
            // it, because a ring has no ends to miss.
            while chain[0] != chain[chain.count - 1] {
                let end = chain[chain.count - 1]
                guard let next = byEndpoint[end]?.first(where: { !used[$0] }) else { break }
                used[next] = true

                var piece = open[next]
                if piece[piece.count - 1] == end { piece.reverse() }
                guard piece[0] == end else { break }
                chain.append(contentsOf: piece.dropFirst())
            }

            if chain.count >= 4, chain[0] == chain[chain.count - 1] {
                rings.append(Ring(chain))
            } else {
                unclosed.append(chain)
            }
        }

        return Result(rings: rings, unclosed: unclosed)
    }

    /// Put each hole inside the outer ring it belongs to.
    ///
    /// The parent is the **smallest** outer ring containing the hole, not the first
    /// one found: rings nest, and an island in a lake in an island would otherwise
    /// hand its lake to the outermost coastline.
    public static func polygons(outer: [Ring], inner: [Ring]) -> [Polygon] {
        let usable = outer.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return [] }

        let holes = inner.filter { !$0.isEmpty }
        guard !holes.isEmpty else { return usable.map { Polygon(exterior: $0) } }

        // Smallest first, so the first containing ring is the immediate parent.
        // Bounds are computed once here rather than per test — with thousands of
        // rings on each side, the box check is what keeps this cheap.
        let candidates = usable.enumerated()
            .map { (index: $0.offset, ring: $0.element, area: abs($0.element.signedDoubleArea)) }
            .sorted { $0.area < $1.area }
            .map { (index: $0.index, ring: $0.ring, bounds: $0.ring.bounds) }

        var assigned: [Int: [Ring]] = [:]
        for hole in holes {
            guard let probe = hole.coordinates.first else { continue }
            for candidate in candidates {
                guard candidate.bounds?.contains(probe) == true else { continue }
                if candidate.ring.contains(probe) {
                    assigned[candidate.index, default: []].append(hole)
                    break
                }
            }
        }

        return usable.enumerated().map {
            Polygon(exterior: $0.element, holes: assigned[$0.offset] ?? [])
        }
    }
}

extension Ring {
    /// Ray casting, counting crossings of a ray heading in +x.
    ///
    /// A point exactly on an edge is not defined either way, which is fine for the
    /// one thing this is for — deciding which outer ring a hole sits in, where the
    /// hole lies strictly inside one of them.
    public func contains(_ coordinate: Coordinate) -> Bool {
        guard coordinates.count >= 4 else { return false }

        var inside = false
        var previous = coordinates.count - 2
        for current in 0..<(coordinates.count - 1) {
            let a = coordinates[current]
            let b = coordinates[previous]
            if (a.y > coordinate.y) != (b.y > coordinate.y),
               coordinate.x < (b.x - a.x) * (coordinate.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}
