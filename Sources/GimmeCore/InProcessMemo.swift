import Foundation

/// A short-lived in-process memo. The engine runs `list` and `outdated`
/// concurrently (the GUI loads both at once); without this, each adapter's
/// `outdated()` re-runs the `listInstalled()` subprocess that the concurrent
/// `list` just ran — e.g. brew's ~0.6 s `brew list` spawns twice. A few
/// seconds of memoization collapses the two spawns into one.
///
/// Adapters clear it in their mutating operations (install/uninstall/upgrade)
/// so the post-action read reflects the new state.
final class InProcessMemo<T> {
    private let lock = NSLock()
    private var entry: (at: Date, value: T)?
    private let ttl: TimeInterval

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    func get() -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let entry, Date().timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.value
    }

    func set(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        entry = (Date(), value)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        entry = nil
    }
}
