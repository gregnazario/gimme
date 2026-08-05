import Foundation

/// A semantic version: major.minor.patch with optional pre-release tag and
/// build metadata. Ordering follows SemVer 2.0.0:
///   - Pre-release has lower precedence than the corresponding release.
///   - Pre-release identifiers are compared dot-by-dot: numeric identifiers
///     compare as integers (and have lower precedence than alphanumeric);
///     alphanumeric identifiers compare lexically; a larger set of fields
///     has higher precedence when all preceding fields equal.
///   - Build metadata (`+...`) is ignored for precedence.
public struct Version: Comparable, Hashable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let pre: String?       // without leading "-"
    public let build: String?     // without leading "+"

    public init(major: Int, minor: Int, patch: Int, pre: String? = nil, build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.pre = pre
        self.build = build
    }

    public init?(_ s: String) {
        var core = s
        var pre: String? = nil
        var build: String? = nil
        // Build metadata: `+...` (valid SemVer). Strip before anything else.
        if let plus = s.firstIndex(of: "+") {
            build = String(s[s.index(after: plus)...])
            core = String(s[..<plus])
        }
        // Pre-release: `-...` (after build stripped).
        if let dash = core.firstIndex(of: "-") {
            pre = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        let parts = core.split(separator: ".").map { String($0) }
        let ints = parts.compactMap { Int($0) }
        guard ints.count >= 1, ints.count <= 3, ints.count == parts.count else { return nil }
        self.major = ints[0]
        self.minor = ints.count > 1 ? ints[1] : 0
        self.patch = ints.count > 2 ? ints[2] : 0
        self.pre = pre
        self.build = build
    }

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if let pre { s += "-\(pre)" }
        if let build { s += "+\(build)" }
        return s
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        // Build metadata does NOT affect precedence (SemVer 10).
        return Version.preLess(lhs.pre, rhs.pre)
    }

    /// SemVer 11: pre-release precedence.
    private static func preLess(_ l: String?, _ r: String?) -> Bool {
        switch (l, r) {
        case (nil, nil):
            return false
        case (nil, _):
            return false   // release > pre-release
        case (_, nil):
            return true    // pre-release < release
        case (let l?, let r?):
            return comparePre(l, r) < 0
        }
    }

    /// Compare two pre-release strings per SemVer 11. Returns -1/0/1.
    private static func comparePre(_ l: String, _ r: String) -> Int {
        let lIds = l.split(separator: ".").map(String.init)
        let rIds = r.split(separator: ".").map(String.init)
        for i in 0..<min(lIds.count, rIds.count) {
            let li = lIds[i], ri = rIds[i]
            let lNum = Int(li), rNum = Int(ri)
            if let ln = lNum, let rn = rNum {
                if ln != rn { return ln < rn ? -1 : 1 }
            } else if lNum != nil {
                // Numeric identifiers has LOWER precedence than alphanumeric.
                return -1
            } else if rNum != nil {
                return 1
            } else {
                if li != ri { return li < ri ? -1 : 1 }
            }
        }
        // All shared-position identifiers equal: more fields wins.
        if lIds.count != rIds.count {
            return lIds.count < rIds.count ? -1 : 1
        }
        return 0
    }
}

/// A version requirement expressed by a query or dependency.
public indirect enum VersionConstraint: Equatable, CustomStringConvertible {
    case any
    case exact(Version)
    case major(Int)                            // "3"     -> any 3.x.x (fuzzy major)
    case majorMinor(major: Int, minor: Int)   // "2.40"  -> any 2.40.x
    case caret(Version)                        // ^2.40.0 -> >=2.40.0, <3.0.0
    case tilde(Version)                        // ~2.40.0 -> >=2.40.0, <2.41.0
    case range(min: Version, minOp: Cmp, max: Version?, maxOp: Cmp)

    public enum Cmp: String, Equatable { case gte = ">=", gt = ">", lte = "<=", lt = "<" }

    public var description: String {
        switch self {
        case .any:            return "*"
        case .exact(let v):   return String(describing: v)
        case .major(let m): return "\(m)"
        case .majorMinor(let m, let mi): return "\(m).\(mi)"
        case .caret(let v):   return "^\(v)"
        case .tilde(let v):   return "~\(v)"
        case .range(let lo, let loOp, let hi, let hiOp):
            var s = "\(loOp.rawValue)\(lo)"
            if let hi { s += ",\(hiOp.rawValue)\(hi)" }
            return s
        }
    }

    /// Parse query/constraint strings: "*", "2.40", "2.40.0", "^2.40", "~2.40.0",
    /// ">=2.40,<3", ">=2.40", "<3", "<=3.0.0".
    public static func parse(_ s: String) throws -> VersionConstraint {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "*" { return .any }

        if trimmed.contains(",") {
            let parts = trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            var lo: Version? = nil, loOp: Cmp = .gte
            var hi: Version? = nil, hiOp: Cmp = .lt
            for p in parts {
                if let (op, v) = try? parseCmp(p) {
                    switch op {
                    case .gte, .gt: lo = v; loOp = op
                    case .lte, .lt: hi = v; hiOp = op
                    }
                } else {
                    throw GimmeError.usage("invalid version constraint part: \(p)")
                }
            }
            return .range(min: lo ?? Version("0.0.0")!, minOp: loOp, max: hi, maxOp: hiOp)
        }

        if let (op, v) = try? parseCmp(trimmed) {
            switch op {
            case .gte: return .range(min: v, minOp: .gte, max: nil, maxOp: .lt)
            case .gt:  return .range(min: v, minOp: .gt,  max: nil, maxOp: .lt)
            case .lt:  return .range(min: Version("0.0.0")!, minOp: .gte, max: v, maxOp: .lt)
            case .lte: return .range(min: Version("0.0.0")!, minOp: .gte, max: v, maxOp: .lte)
            }
        }

        if trimmed.hasPrefix("^"), let v = Version(String(trimmed.dropFirst())) { return .caret(v) }
        if trimmed.hasPrefix("~"), let v = Version(String(trimmed.dropFirst())) { return .tilde(v) }

        // Bare versions, distinguished by component count:
        //   "3"      -> fuzzyMajor(3)     any 3.x.x  (matches mise/asdf/npm convention)
        //   "2.40"   -> majorMinor(2,40)  any 2.40.x
        //   "2.40.0" / "2.40.1-rc1" -> exact
        let dotParts = trimmed.split(separator: ".").map { String($0) }
        if dotParts.count == 1 {
            guard let m = Int(dotParts[0]) else { throw GimmeError.usage("invalid version: \(trimmed)") }
            return .major(m)
        }
        if dotParts.count == 2 {
            guard let m = Int(dotParts[0]),
                  let mi = Int(dotParts[1]) else { throw GimmeError.usage("invalid version: \(trimmed)") }
            return .majorMinor(major: m, minor: mi)
        }
        guard let v = Version(trimmed) else { throw GimmeError.usage("invalid version: \(trimmed)") }
        return .exact(v)
    }

    private static func parseCmp(_ s: String) throws -> (Cmp, Version) {
        for (raw, op) in [(">=", Cmp.gte), ("<=", Cmp.lte), (">", Cmp.gt), ("<", Cmp.lt)] {
            if s.hasPrefix(raw), let v = Version(String(s.dropFirst(raw.count))) {
                return (op, v)
            }
        }
        throw GimmeError.usage("not a comparison: \(s)")
    }

    public func matches(_ v: Version) -> Bool {
        switch self {
        case .any:
            return true
        case .exact(let target):
            return v == target
        case .major(let m):
            return v.major == m
        case .majorMinor(let m, let mi):
            return v.major == m && v.minor == mi
        case .caret(let target):
            if v < target { return false }
            if target.major == 0 {
                return v.major == 0 && v.minor == target.minor
            }
            return v.major == target.major
        case .tilde(let target):
            if v < target { return false }
            return v.major == target.major && v.minor == target.minor
        case .range(let lo, let loOp, let hi, let hiOp):
            let lowerOK = compare(v, lo, loOp)
            let upperOK = hi.map { compare(v, $0, hiOp) } ?? true
            return lowerOK && upperOK
        }
    }

    private func compare(_ v: Version, _ bound: Version, _ op: Cmp) -> Bool {
        switch op {
        case .gte: return v >= bound
        case .gt:  return v >  bound
        case .lte: return v <= bound
        case .lt:  return v <  bound
        }
    }
}
