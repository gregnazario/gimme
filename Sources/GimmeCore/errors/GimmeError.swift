import Foundation

/// Error categories map 1:1 to exit codes (see design spec section 6).
public enum ErrorCategory: String, Codable {
    case USAGE
    case NOT_FOUND
    case INSTALL
    case NETWORK
    case CHECKSUM
    case PERMISSION
    case CONFLICT
    case LOCK
    case UNKNOWN

    public var exitCode: Int32 {
        switch self {
        case .USAGE, .NOT_FOUND: return 1
        case .INSTALL, .NETWORK, .CHECKSUM, .PERMISSION: return 2
        case .CONFLICT: return 3
        case .LOCK: return 4
        case .UNKNOWN: return 70
        }
    }

    /// Stable wire code used in JSON `error.code`.
    public var codeString: String { rawValue }
}

/// Every failure in the engine is a typed GimmeError, never a bare string.
/// The CLI layer translates to JSON + exit code.
public enum GimmeError: Error, Equatable {
    case usage(String)
    case notFound(String)
    case install(String)
    case network(String)
    case checksumMismatch(expected: String, actual: String)
    case permission(String)
    case conflict(String)
    case lock(String)
    case unknown(String)
    // v2 orchestration cases.
    case managerUnavailable(ManagerID)
    case notFoundInManagers(name: String, searched: [ManagerID])
    case bootstrapFailed(ManagerID, underlying: String)
    case operationFailed(manager: ManagerID, op: String, underlying: String)

    public var category: ErrorCategory {
        switch self {
        case .usage, .managerUnavailable:                  return .USAGE
        case .notFound, .notFoundInManagers:               return .NOT_FOUND
        case .install, .bootstrapFailed, .operationFailed: return .INSTALL
        case .network:                                     return .NETWORK
        case .checksumMismatch:                            return .CHECKSUM
        case .permission:                                  return .PERMISSION
        case .conflict:                                    return .CONFLICT
        case .lock:                                        return .LOCK
        case .unknown:                                     return .UNKNOWN
        }
    }

    public var message: String {
        switch self {
        case .usage(let s), .notFound(let s), .install(let s), .network(let s),
             .permission(let s), .conflict(let s), .lock(let s), .unknown(let s):
            return s
        case .checksumMismatch(let e, let a):
            return "checksum mismatch: expected \(e), got \(a)"
        case .managerUnavailable(let m):
            return "\(m.rawValue) is not installed"
        case .notFoundInManagers(let name, let searched):
            let list = searched.map { $0.rawValue }.joined(separator: ", ")
            return "no manager has '\(name)'; searched: \(list)"
        case .bootstrapFailed(let m, let underlying):
            return "failed to bootstrap \(m.rawValue): \(underlying)"
        case .operationFailed(let m, let op, let underlying):
            return "\(m.rawValue) \(op) failed: \(underlying)"
        }
    }

    public var recoverable: Bool {
        switch self {
        case .network, .lock: return true
        default:              return false
        }
    }

    public var suggested: String? {
        switch self {
        case .checksumMismatch:
            return "gimme uninstall <tool> && gimme install <tool>"
        case .network:
            return "retry the command"
        case .lock:
            return "wait for the other gimme process to finish or remove the stale lock"
        default:
            return nil
        }
    }

    /// JSON shape consumed by the AI-agent contract (design section 7).
    public func toJSON() -> [String: Any] {
        var details: [String: String] = [:]
        if case .checksumMismatch(let e, let a) = self {
            details = ["expected": e, "actual": a]
        }
        let err: [String: Any] = [
            "code":        category.codeString,
            "message":     message,
            "details":     details,
            "recoverable": recoverable,
            "suggested":   suggested as Any
        ]
        return ["ok": false, "error": err]
    }
}
