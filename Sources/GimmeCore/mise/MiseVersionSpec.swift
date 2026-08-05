import Foundation

/// A parsed mise/asdf version spec (the right-hand side of a `.tool-versions`
/// line or a `mise.toml` `[tools]` value). mise specs are fuzzy, not SemVer;
/// this type maps each onto either a gimme query or an "unsupported" marker.
public struct MiseVersionSpec: Equatable {
    public let raw: String
    public let kind: Kind

    public enum Kind: Equatable {
        case exact(Version)          // "20.0.0" -> install exactly this
        case fuzzyMajor(Int)         // "20"     -> any 20.x
        case latest                  // "latest" -> newest available
        case alias(String)           // "lts" or other non-numeric, non-scoped
        case prefix(Int, Int)        // "prefix:1.19" -> any 1.19.x (major.minor)
        case prefixMajor(Int)        // "prefix:1"    -> any 1.x.x   (major only)
        case unsupported(String)     // "ref:", "path:", "sub-" -> reason carried
    }

    public init(raw: String, kind: Kind) {
        self.raw = raw; self.kind = kind
    }

    /// Parse a mise version spec string into its Kind.
    public static func parse(_ s: String) -> MiseVersionSpec {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        if lower == "latest" {
            return MiseVersionSpec(raw: trimmed, kind: .latest)
        }

        // Scoped specs: "prefix:", "ref:", "path:", "sub-".
        if let colon = trimmed.firstIndex(of: ":") {
            let scope = String(trimmed[..<colon]).lowercased()
            let rest = String(trimmed[trimmed.index(after: colon)...])
            switch scope {
            case "prefix":
                // prefix:1.19 -> major.minor (any 1.19.x); prefix:1 -> major only (any 1.x.x).
                // The two are semantically distinct in mise, so keep separate cases.
                let parts = rest.split(separator: ".").compactMap { Int($0) }
                if parts.count >= 2 { return MiseVersionSpec(raw: trimmed, kind: .prefix(parts[0], parts[1])) }
                if parts.count == 1 { return MiseVersionSpec(raw: trimmed, kind: .prefixMajor(parts[0])) }
                return MiseVersionSpec(raw: trimmed, kind: .unsupported("invalid prefix: spec"))
            case "ref":
                return MiseVersionSpec(raw: trimmed, kind: .unsupported("ref: VCS-ref builds not supported"))
            case "path":
                return MiseVersionSpec(raw: trimmed, kind: .unsupported("path: local-dir runtimes not supported"))
            default:
                return MiseVersionSpec(raw: trimmed, kind: .unsupported("unknown scope '\(scope):'"))
            }
        }

        // "sub-<x>:<y>" arithmetic — unsupported in the foundation.
        if lower.hasPrefix("sub-") {
            return MiseVersionSpec(raw: trimmed, kind: .unsupported("sub- version arithmetic not supported"))
        }

        // Plain version-ish strings: exact (X.Y.Z), fuzzy major (X or X.Y), or alias.
        let dotParts = trimmed.split(separator: ".").map { String($0) }
        let allNumeric = !dotParts.isEmpty && dotParts.allSatisfy { Int($0) != nil }

        if allNumeric {
            if dotParts.count == 1, let major = Int(dotParts[0]) {
                return MiseVersionSpec(raw: trimmed, kind: .fuzzyMajor(major))
            }
            // "20.3" or "20.3.1" — treat both as exact (gimme's Version fills patch=0).
            if let v = Version(trimmed) {
                return MiseVersionSpec(raw: trimmed, kind: .exact(v))
            }
        }

        // Anything else (e.g. "lts", "stable", named channels) is an alias.
        return MiseVersionSpec(raw: trimmed, kind: .alias(trimmed))
    }

    /// Translate to a gimme query string ("tool@<constraint>"), or nil if the
    /// spec is unsupported and cannot be installed by gimme.
    public func toGimmeQuery(tool: String) -> String? {
        switch kind {
        case .exact(let v):
            return "\(tool)@\(v)"
        case .fuzzyMajor(let m):
            return "\(tool)@\(m)"
        case .latest:
            return tool
        case .alias:
            // Aliases (e.g. "lts") resolve to "newest available" — best-effort.
            return tool
        case .prefix(let major, let minor):
            // prefix:1.19 -> any 1.19.x. gimme's resolver parses "1.19" as
            // majorMinor(1, 19), matching any 1.19.x. Correct.
            return "\(tool)@\(major).\(minor)"
        case .prefixMajor(let major):
            // prefix:1 -> any 1.x.x. A bare-major query ("tool@1") parses as
            // fuzzyMajor(1), matching any 1.x.x — the intended mise semantic.
            return "\(tool)@\(major)"
        case .unsupported:
            return nil
        }
    }
}
