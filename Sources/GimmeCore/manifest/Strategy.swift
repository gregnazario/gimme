import Foundation

/// How a version gets from its asset to the cellar prefix.
public enum Strategy: String, Codable, Equatable {
    /// Declarative steps run by the engine directly (no code). Most binary formulae.
    case steps
    /// A sandboxed Lua `install(ctx)` function (logic required).
    case lua
    /// Build from source. Reserved — NOT implemented in the foundation.
    case source
}
