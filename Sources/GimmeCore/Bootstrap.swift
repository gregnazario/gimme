import Foundation

/// Runs the auto-bootstrap flow for a missing manager (spec §6.6).
public enum Bootstrap {
    /// If `manager` is available, returns immediately. Otherwise asks `confirm`
    /// whether to install the backend; if yes, runs `bootstrap()` and re-checks.
    /// Throws `managerUnavailable` if the user declines or bootstrap leaves the
    /// manager still unavailable.
    public static func run(
        _ manager: any PackageManager,
        confirm: @Sendable (ManagerID) -> Bool
    ) async throws {
        if manager.isAvailable() { return }
        guard confirm(manager.id) else {
            throw GimmeError.managerUnavailable(manager.id)
        }
        try await manager.bootstrap()
        // The resolver caches not-found lookups; clear before re-checking so a
        // just-installed backend is actually detected.
        BinaryResolver.clearCache()
        guard manager.isAvailable() else {
            throw GimmeError.bootstrapFailed(manager.id, underlying: "still unavailable after bootstrap")
        }
    }
}
