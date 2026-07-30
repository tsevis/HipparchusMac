import CGEOS
import HipparchusGeometry

public enum GEOSError: Error, CustomStringConvertible {
    /// GEOS reported a message through its error handler.
    case operation(String)
    /// GEOS returned null or an out-of-band status with nothing to say.
    case failed(String)
    /// A geometry came back in a shape the reader does not know.
    case unsupportedType(Int32)

    public var description: String {
        switch self {
        case .operation(let message): return "GEOS: \(message)"
        case .failed(let what): return "GEOS: \(what) failed"
        case .unsupportedType(let id): return "GEOS: unsupported geometry type id \(id)"
        }
    }
}

/// Owns a GEOS reentrant context and is the only place in the app that touches
/// the C API.
///
/// Deliberately **not** `Sendable`. A GEOS context handle carries mutable error
/// state and its own allocator, and using one from two threads at once corrupts
/// both. Making the type non-sendable means Swift refuses to let it cross a
/// concurrency boundary instead of letting it crash at runtime: code that needs
/// GEOS on another task creates its own context, which is cheap.
public final class GEOSContext {
    let handle: GEOSContextHandle_t
    /// The last message GEOS produced, captured so a thrown error can say what
    /// actually went wrong rather than just naming the operation.
    private var lastMessage: String?

    public init() {
        handle = GEOS_init_r()
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        GEOSContext_setErrorMessageHandler_r(handle, { message, userdata in
            guard let message, let userdata else { return }
            let context = Unmanaged<GEOSContext>.fromOpaque(userdata).takeUnretainedValue()
            context.lastMessage = String(cString: message)
        }, userdata)
        // Notices are things like "self-intersection repaired". They are not
        // errors and drowning the log in them hides the ones that matter.
        GEOSContext_setNoticeMessageHandler_r(handle, { _, _ in }, nil)
    }

    deinit {
        GEOS_finish_r(handle)
    }

    public var version: String {
        guard let raw = GEOSversion() else { return "unknown" }
        return String(cString: raw)
    }

    /// Turn a null return into a Swift error, attaching whatever GEOS said.
    func require(_ pointer: OpaquePointer?, _ what: String) throws -> OpaquePointer {
        guard let pointer else {
            throw takeError(what)
        }
        return pointer
    }

    func takeError(_ what: String) -> GEOSError {
        defer { lastMessage = nil }
        if let message = lastMessage, !message.isEmpty {
            return .operation("\(what): \(message)")
        }
        return .failed(what)
    }

    /// GEOS predicates return `char`: 1 true, 0 false, 2 exception.
    func predicate(_ result: CChar, _ what: String) throws -> Bool {
        switch result {
        case 1: return true
        case 0: return false
        default: throw takeError(what)
        }
    }
}

/// A GEOS geometry with a Swift lifetime.
///
/// GEOS constructors take ownership of their arguments, so `release()` exists to
/// hand a pointer over without double-freeing it. Everything else is freed on
/// `deinit`, which is what keeps the conversion code free of `defer` ladders.
///
/// **The pointer is only reachable through `withPointer`, and that is deliberate.**
/// An earlier version exposed it as a plain property, which read fine and passed
/// every test in a debug build. In release the optimiser is entitled to drop the
/// last reference as soon as the pointer has been extracted — so for the GEOS
/// calls that *borrow* their inputs rather than consuming them, notably
/// `GEOSPolygonize`, the geometry was freed before the call read it. It
/// segfaulted only with optimisation on. A scoped accessor makes the mistake
/// unwritable instead of relying on anyone remembering `withExtendedLifetime`.
final class ManagedGeometry {
    private let context: GEOSContext
    private var pointer: OpaquePointer?

    init(taking pointer: OpaquePointer, in context: GEOSContext) {
        self.pointer = pointer
        self.context = context
    }

    /// Use the pointer with the geometry guaranteed alive for the whole call.
    func withPointer<R>(_ body: (OpaquePointer) throws -> R) rethrows -> R {
        guard let pointer else {
            preconditionFailure("ManagedGeometry used after release")
        }
        return try withExtendedLifetime(self) { try body(pointer) }
    }

    /// Give up ownership for a GEOS call that will free it itself.
    func release() -> OpaquePointer {
        guard let pointer else {
            preconditionFailure("ManagedGeometry released twice")
        }
        self.pointer = nil
        return pointer
    }

    deinit {
        if let pointer {
            GEOSGeom_destroy_r(context.handle, pointer)
        }
    }
}

extension GEOSContext {
    /// Build a geometry, hand its pointer to `body`, and free it afterwards.
    func withGeometry<R>(_ geometry: Geometry, _ body: (OpaquePointer) throws -> R) throws -> R {
        try make(geometry).withPointer(body)
    }

    /// The two-argument form, for the overlay operations.
    func withGeometries<R>(
        _ lhs: Geometry,
        _ rhs: Geometry,
        _ body: (OpaquePointer, OpaquePointer) throws -> R
    ) throws -> R {
        let a = try make(lhs)
        let b = try make(rhs)
        return try a.withPointer { first in
            try b.withPointer { second in
                try body(first, second)
            }
        }
    }
}
