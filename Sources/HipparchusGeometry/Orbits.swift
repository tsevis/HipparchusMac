import Foundation

/// Orbit propagation for satellite ground tracks.
///
/// Ported from `geometry/orbits.py`.
///
/// A Keplerian propagator with J2 secular drift, working directly from TLE mean
/// elements. It is **approximate** on purpose: it carries the two effects that
/// dominate the shape of a ground track over a few orbits — the orbit itself, and
/// the nodal regression that walks it westward — and drops the short-period terms,
/// drag and resonances that full SGP4 models. Positions are good to roughly a few
/// kilometres for a low orbit over a few hours, which is far below the width of a
/// drawn line on any map this app produces, and degrades over days rather than
/// staying valid.
///
/// It is written out rather than taken from a library so ground tracks need no
/// dependency at all. Anything needing true ephemeris accuracy — conjunction work,
/// pointing, re-entry — should use SGP4 proper, not this. That is why every feature
/// this produces declares itself `approximate`.

public enum Orbits {
    /// WGS-84 / EGM constants.
    public static let earthRadiusKm = 6378.137
    public static let earthMu = 398_600.4418  // km³/s²
    public static let earthJ2 = 1.08262668e-3
    public static let secondsPerDay = 86400.0
}

public struct TLEParseError: Error, CustomStringConvertible {
    public let reason: String
    public var description: String { "could not read the element set: \(reason)" }
}

/// Mean orbital elements at an epoch, as carried by a TLE.
public struct TwoLineElements: Sendable, Equatable {
    public let name: String
    public let catalogNumber: String
    public let epoch: Date
    public let inclinationDegrees: Double
    public let raanDegrees: Double
    public let eccentricity: Double
    public let argPerigeeDegrees: Double
    public let meanAnomalyDegrees: Double
    public let meanMotionRevPerDay: Double

    public var periodMinutes: Double {
        meanMotionRevPerDay > 0 ? 1440.0 / meanMotionRevPerDay : 0
    }

    public var semiMajorAxisKm: Double {
        let meanMotion = meanMotionRevPerDay * 2 * .pi / Orbits.secondsPerDay
        guard meanMotion > 0 else { return 0 }
        return pow(Orbits.earthMu / (meanMotion * meanMotion), 1.0 / 3.0)
    }
}

/// Where a satellite is, projected onto the ground.
public struct SubPoint: Sendable, Equatable {
    public let when: Date
    public let longitude: Double
    public let latitude: Double
    public let altitudeKm: Double

    public var coordinate: Coordinate { Coordinate(lon: longitude, lat: latitude) }
}

// MARK: - Parsing

extension TwoLineElements {

    /// Read a Celestrak-style TLE listing, with or without name lines.
    ///
    /// One malformed set must not lose the rest of the listing — Celestrak returns
    /// hundreds at a time and a single bad record is not a reason to draw nothing.
    public static func parseListing(_ text: String) -> [TwoLineElements] {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var elements: [TwoLineElements] = []
        var index = 0
        while index < lines.count {
            var name = ""
            if !lines[index].hasPrefix("1 "), index + 2 < lines.count {
                name = lines[index]
                index += 1
            }
            guard index + 1 < lines.count else { break }
            let first = lines[index]
            let second = lines[index + 1]
            index += 2
            guard first.hasPrefix("1 "), second.hasPrefix("2 ") else { continue }
            if let parsed = try? TwoLineElements(name: name, line1: first, line2: second) {
                elements.append(parsed)
            }
        }
        return elements
    }

    /// TLE fields are fixed-column, not delimited. A satellite whose name contains a
    /// space would break any split-on-whitespace reading of them.
    public init(name: String, line1: String, line2: String) throws {
        func field(_ line: String, _ range: Range<Int>) -> String {
            let characters = Array(line)
            guard range.lowerBound < characters.count else { return "" }
            let upper = Swift.min(range.upperBound, characters.count)
            return String(characters[range.lowerBound..<upper]).trimmingCharacters(in: .whitespaces)
        }

        func number(_ line: String, _ range: Range<Int>, _ what: String) throws -> Double {
            guard let value = Double(field(line, range)) else {
                throw TLEParseError(reason: "\(what) is not a number")
            }
            return value
        }

        let catalog = field(line1, 2..<7)
        guard let epoch = Self.epoch(from: field(line1, 18..<32)) else {
            throw TLEParseError(reason: "epoch")
        }

        let meanMotion = try number(line2, 52..<63, "mean motion")
        guard meanMotion > 0 else { throw TLEParseError(reason: "mean motion must be positive") }

        // The eccentricity field carries an implied leading decimal point.
        guard let eccentricity = Double("0." + field(line2, 26..<33)) else {
            throw TLEParseError(reason: "eccentricity")
        }

        self.init(
            name: name.isEmpty ? "NORAD \(catalog)" : name,
            catalogNumber: catalog,
            epoch: epoch,
            inclinationDegrees: try number(line2, 8..<16, "inclination"),
            raanDegrees: try number(line2, 17..<25, "right ascension"),
            eccentricity: eccentricity,
            argPerigeeDegrees: try number(line2, 34..<42, "argument of perigee"),
            meanAnomalyDegrees: try number(line2, 43..<51, "mean anomaly"),
            meanMotionRevPerDay: meanMotion
        )
    }

    /// Decode a `YYDDD.DDDDDDDD` epoch. Years 57–99 mean 1957–1999.
    static func epoch(from field: String) -> Date? {
        let raw = field.trimmingCharacters(in: .whitespaces)
        guard raw.count >= 3, let year = Int(raw.prefix(2)), let dayOfYear = Double(raw.dropFirst(2)) else {
            return nil
        }
        let fullYear = year >= 57 ? 1900 + year : 2000 + year

        var components = DateComponents()
        components.year = fullYear
        components.month = 1
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let start = calendar.date(from: components) else { return nil }
        return start.addingTimeInterval((dayOfYear - 1.0) * Orbits.secondsPerDay)
    }
}

// MARK: - Propagation

extension Orbits {

    /// Propagate to `when` and project onto the ground.
    public static func subpoint(of elements: TwoLineElements, at when: Date) -> SubPoint {
        let seconds = when.timeIntervalSince(elements.epoch)
        let meanMotion = elements.meanMotionRevPerDay * 2 * .pi / secondsPerDay
        let axis = elements.semiMajorAxisKm
        let eccentricity = elements.eccentricity
        let inclination = elements.inclinationDegrees * .pi / 180

        // J2 secular drift. The nodal regression is what walks a ground track
        // westward from one orbit to the next — about −23.5° per orbit for the
        // ISS — so it cannot be dropped without the track being visibly wrong.
        let semiLatus = Swift.max(1e-6, axis * (1 - eccentricity * eccentricity))
        let factor = 1.5 * earthJ2 * pow(earthRadiusKm / semiLatus, 2) * meanMotion
        let raan = elements.raanDegrees * .pi / 180 - factor * cos(inclination) * seconds
        let argPerigee = elements.argPerigeeDegrees * .pi / 180
            + factor * (2.0 - 2.5 * pow(sin(inclination), 2)) * seconds
        let meanAnomaly = elements.meanAnomalyDegrees * .pi / 180 + meanMotion * seconds

        let eccentricAnomaly = solveKepler(meanAnomaly: meanAnomaly, eccentricity: eccentricity)
        let trueAnomaly = 2 * atan2(
            (1 + eccentricity).squareRoot() * sin(eccentricAnomaly / 2),
            (1 - eccentricity).squareRoot() * cos(eccentricAnomaly / 2)
        )
        let radius = axis * (1 - eccentricity * cos(eccentricAnomaly))

        // Perifocal position, rotated into the equatorial inertial frame.
        let argument = argPerigee + trueAnomaly
        let x = radius * (cos(raan) * cos(argument) - sin(raan) * sin(argument) * cos(inclination))
        let y = radius * (sin(raan) * cos(argument) + cos(raan) * sin(argument) * cos(inclination))
        let z = radius * (sin(argument) * sin(inclination))

        // Inertial to Earth-fixed is a single rotation by sidereal time.
        let longitude = (atan2(y, x) - greenwichSiderealAngle(when)) * 180 / .pi
        let latitude = asin(Swift.min(Swift.max(z / radius, -1), 1)) * 180 / .pi

        return SubPoint(
            when: when,
            longitude: wrappedLongitude(longitude),
            latitude: latitude,
            altitudeKm: radius - earthRadiusKm
        )
    }

    /// Sub-satellite points over a window, split at the antimeridian.
    ///
    /// Returned as separate runs rather than one polyline: a track crossing ±180°
    /// would otherwise draw a spurious line straight back across the whole map.
    public static func groundTrack(
        of elements: TwoLineElements,
        start: Date,
        minutes: Double,
        stepSeconds: Double = 30
    ) -> [[SubPoint]] {
        guard minutes > 0, stepSeconds > 0 else { return [] }

        var runs: [[SubPoint]] = []
        var current: [SubPoint] = []
        var previous: SubPoint?
        let steps = Int(minutes * 60 / stepSeconds) + 1

        for step in 0..<steps {
            let point = subpoint(of: elements, at: start.addingTimeInterval(Double(step) * stepSeconds))
            if let previous, abs(point.longitude - previous.longitude) > 180 {
                if current.count >= 2 { runs.append(current) }
                current = []
            }
            current.append(point)
            previous = point
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// Angular radius of the circle from which the satellite is above the horizon.
    public static func horizonRadiusDegrees(altitudeKm: Double) -> Double {
        let radius = earthRadiusKm + Swift.max(1, altitudeKm)
        return acos(Swift.min(Swift.max(earthRadiusKm / radius, -1), 1)) * 180 / .pi
    }

    /// Greenwich mean sidereal time, as an angle in radians.
    public static func greenwichSiderealAngle(_ when: Date) -> Double {
        let centuries = (julianDate(when) - 2_451_545.0) / 36525.0
        let seconds = 67310.54841
            + (876_600.0 * 3600.0 + 8_640_184.812866) * centuries
            + 0.093104 * centuries * centuries
            - 6.2e-6 * centuries * centuries * centuries
        let degrees = seconds.truncatingRemainder(dividingBy: secondsPerDay) / 240.0
        return (degrees.truncatingRemainder(dividingBy: 360.0)) * .pi / 180
    }

    public static func julianDate(_ when: Date) -> Double {
        // Unix epoch 1970-01-01T00:00:00Z is JD 2440587.5.
        2_440_587.5 + when.timeIntervalSince1970 / secondsPerDay
    }

    /// Newton–Raphson on Kepler's equation.
    static func solveKepler(meanAnomaly: Double, eccentricity: Double, iterations: Int = 24) -> Double {
        var eccentric = eccentricity < 0.8 ? meanAnomaly : Double.pi
        for _ in 0..<iterations {
            let delta = (eccentric - eccentricity * sin(eccentric) - meanAnomaly)
                / (1 - eccentricity * cos(eccentric))
            eccentric -= delta
            if abs(delta) < 1e-12 { break }
        }
        return eccentric
    }

    public static func wrappedLongitude(_ longitude: Double) -> Double {
        var wrapped = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        return wrapped - 180
    }

    // MARK: - The date line

    /// Divide a ring that runs past ±180° into the pieces the sheet holds.
    ///
    /// Ported from `_split_at_antimeridian`. The ring must arrive **unwrapped** —
    /// longitudes running continuously past the date line rather than jumping
    /// from +179° to −179°. Wrapping each vertex on its own is worse than not
    /// wrapping at all: it turns a footprint over the Pacific into a band drawn
    /// straight across the map.
    ///
    /// The ring is shifted by −360°, 0° and +360°, and each shift is trimmed to
    /// the world; whatever survives is a piece. A ring already inside the world
    /// comes back untouched, which is the overwhelmingly common case.
    public static func splitAtAntimeridian(_ ring: [Coordinate]) -> [[Coordinate]] {
        let longitudes = ring.map(\.lon)
        guard let west = longitudes.min(), let east = longitudes.max() else { return [] }
        guard west < -180 || east > 180 else { return [ring] }

        return [-360.0, 0.0, 360.0].compactMap { shift in
            let shifted = ring.map { Coordinate(lon: $0.lon + shift, lat: $0.lat) }
            let piece = clippedToWorld(shifted)
            return piece.count >= 3 ? piece : nil
        }
    }

    /// Sutherland–Hodgman against the two meridians that bound the map.
    ///
    /// Exact for the rings this is asked about: a footprint is an ellipse in
    /// unwrapped coordinates, and clipping a convex ring by a half-plane leaves
    /// a convex ring. It avoids a general overlay — and so a GEOS dependency —
    /// in the one module that is pure arithmetic.
    private static func clippedToWorld(_ ring: [Coordinate]) -> [Coordinate] {
        var result = ring
        // Trim the eastern overhang, then the western one.
        for (limit, keepBelow) in [(180.0, true), (-180.0, false)] {
            guard !result.isEmpty else { return [] }
            var clipped: [Coordinate] = []
            for index in result.indices {
                let current = result[index]
                let previous = result[(index + result.count - 1) % result.count]
                let currentInside = keepBelow ? current.lon <= limit : current.lon >= limit
                let previousInside = keepBelow ? previous.lon <= limit : previous.lon >= limit

                if currentInside != previousInside {
                    // Where the edge crosses the meridian, in latitude.
                    let span = current.lon - previous.lon
                    let t = span == 0 ? 0 : (limit - previous.lon) / span
                    clipped.append(Coordinate(
                        lon: limit, lat: previous.lat + t * (current.lat - previous.lat)
                    ))
                }
                if currentInside { clipped.append(current) }
            }
            result = clipped
        }
        return result
    }
}
