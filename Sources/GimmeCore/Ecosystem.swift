import Foundation

/// A fixed bucket classifying package managers by language/tool ecosystem
/// (spec §3). Used for consolidation: two installed packages are "duplicates"
/// only if they share a name *within the same ecosystem*.
public enum Ecosystem: String, Hashable, Codable, CaseIterable {
    case js, python, rust, go, ruby, php, system, other

    public var displayName: String {
        switch self {
        case .js:     return "JavaScript"
        case .python: return "Python"
        case .rust:   return "Rust"
        case .go:     return "Go"
        case .ruby:   return "Ruby"
        case .php:    return "PHP"
        case .system: return "System / native"
        case .other:  return "Other"
        }
    }

    /// Which managers belong to this ecosystem. Inverse of `ManagerID.ecosystem`.
    public var managers: [ManagerID] { ManagerID.allCases.filter { $0.ecosystem == self } }
}

public extension ManagerID {
    /// The ecosystem this manager belongs to (fixed classification). Metadata,
    /// not a PackageManager protocol requirement. Adding a manager here is the
    /// only change needed to slot it into an ecosystem.
    var ecosystem: Ecosystem {
        switch self {
        case .bun, .npm, .pnpm, .yarn, .deno: return .js
        case .uv, .pipx:                      return .python
        case .cargo:                          return .rust
        case .go:                             return .go
        case .gem:                            return .ruby
        case .composer:                       return .php
        case .homebrew, .aqua, .ubi:          return .system
        }
    }
}
