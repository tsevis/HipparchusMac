import Foundation
import HipparchusGeometry

/// Quality profiles for preview rendering and export.
///
/// Ported from `src/hipparchus/application/quality.py`.
///
/// A preset says what the map should look like; a quality profile says how much
/// work to spend getting there. They multiply rather than override: a preset's
/// smoothing and simplification are scaled by the profile, so switching from Fast
/// Preview to Print Export changes the fidelity without changing the design.
public struct QualityProfile: Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    /// Which projection the geometry is built in. Export uses a local projection so
    /// a printed sheet has no visible Mercator stretch across it.
    public let projectionMode: ProjectionMode
    /// Multiplies the preset's smoothing iterations. 0 switches smoothing off
    /// entirely, which is what makes a fast preview fast.
    public let smoothingScale: Double
    /// Multiplies the preset's simplify tolerance. Smaller means more fidelity, so
    /// export scales *down*.
    public let simplifyScale: Double
    /// Multiplies the preset's per-layer feature cap.
    public let geometryCapScale: Double
    /// Decimal places in exported SVG coordinates.
    public let svgPrecision: Int
    /// Export profiles refuse to write a file whose diagnostics look wrong.
    public let strictDiagnostics: Bool

    public var id: String { key }

    public var isExport: Bool { key.hasPrefix("export") }
}

public enum Quality {
    /// In menu order.
    public static let profiles: [QualityProfile] = [
        QualityProfile(
            key: "preview_fast",
            label: "Fast Preview",
            projectionMode: .webMercator,
            smoothingScale: 0.0,
            simplifyScale: 1.0,
            geometryCapScale: 0.55,
            svgPrecision: 3,
            strictDiagnostics: false
        ),
        QualityProfile(
            key: "preview_high",
            label: "High Preview",
            projectionMode: .webMercator,
            smoothingScale: 1.0,
            simplifyScale: 0.5,
            geometryCapScale: 1.0,
            svgPrecision: 3,
            strictDiagnostics: false
        ),
        QualityProfile(
            key: "export_clean",
            label: "Clean Export",
            projectionMode: .localAzimuthal,
            smoothingScale: 2.0,
            simplifyScale: 0.35,
            geometryCapScale: 1.0,
            svgPrecision: 4,
            strictDiagnostics: false
        ),
        QualityProfile(
            key: "export_print",
            label: "Print Export",
            projectionMode: .localAzimuthal,
            smoothingScale: 2.0,
            simplifyScale: 0.0,
            geometryCapScale: 1.0,
            svgPrecision: 6,
            strictDiagnostics: true
        ),
    ]

    public static let `default` = profiles[0]

    public static var keys: [String] { profiles.map(\.key) }
    public static var labels: [String] { profiles.map(\.label) }

    /// Resolve a key, a user-facing label, or one of the two legacy names.
    ///
    /// Anything unrecognised gives the fast preview rather than failing: this is fed
    /// from a saved setting and from an environment variable, and a stale value
    /// should not stop the app opening.
    public static func profile(_ value: String?) -> QualityProfile {
        let raw = (value ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return `default` }

        if let byLabel = profiles.first(where: { $0.label == raw }) { return byLabel }

        // The two names that predate the four profiles.
        let key = switch raw {
        case "preview": "preview_fast"
        case "export": "export_clean"
        default: raw
        }
        return profiles.first { $0.key == key } ?? `default`
    }
}
