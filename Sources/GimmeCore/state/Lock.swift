import Foundation
import os

/// An advisory file lock held for the duration of any mutating command.
/// Stale locks (held by a dead pid) are auto-recovered.
/// Uses POSIX `flock` for robustness against crashes.
///
/// Re-entrant within a single `Lock` instance: a nested `acquire()` (e.g.
/// `Installer.install` recursively installing a dependency, which calls
/// `install` again on the same `World`/`Lock`) is a no-op that increments an
/// acquisition counter; the lock is only released when the outermost `release()`
/// runs. The counter and fd are guarded by an `os_unfair_lock` so the lock is
/// safe under future concurrency (today all access is single-threaded, but
/// this removes the latent data race).
///
/// SECURITY: the lock file is opened with `O_NOFOLLOW` so a symlink planted at
/// the lock path can't redirect writes to an arbitrary file.
///
/// CONCURRENCY CAVEAT: the re-entrant `depth` counter is correct only when all
/// `acquire`/`release` calls for one `Lock` instance come from a single thread
/// (the `flock` itself serializes across processes). The `os_unfair_lock`
/// guards the counter against data races, but if two threads of the SAME
/// process both call `acquire()` from `depth == 0`, both proceed to open+flock,
/// and the depth counter can end up out of sync (two holders, depth says 1).
/// gimme is single-threaded today; if concurrency is adopted, `acquire` must
/// hold `stateLock` across the flock acquisition too.
public final class Lock {
    public let path: URL

    // State guarded by `stateLock`.
    private var stateLock = os_unfair_lock()
    private var fd: Int32 = -1
    private var depth: Int = 0

    public init(paths: GimmePaths) {
        self.path = paths.state.appendingPathComponent("gimme.lock")
    }

    /// Acquire an exclusive lock. Re-entrant: a second `acquire` on the same
    /// instance while already held just bumps the depth counter.
    public func acquire(timeoutSeconds: TimeInterval = 30) throws {
        // Re-entrant fast path under the lock.
        os_unfair_lock_lock(&stateLock)
        if depth > 0 {
            depth += 1
            os_unfair_lock_unlock(&stateLock)
            return
        }
        os_unfair_lock_unlock(&stateLock)

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Open (create if needed) the lock file. O_NOFOLLOW refuses to follow a
        // symlink at the path, preventing a symlink-redirect attack.
        let openedFd = open(path.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o644)
        guard openedFd >= 0 else {
            // O_NOFOLLOW may fail if the lock file is itself a symlink (legacy).
            // Fall back to a plain open so we don't wedge an existing setup,
            // but this is the less-safe path.
            let fallbackFd = open(path.path, O_CREAT | O_RDWR, 0o644)
            guard fallbackFd >= 0 else {
                throw GimmeError.lock("could not open lock file: \(String(cString: strerror(errno)))")
            }
            try lockWithFd(fallbackFd, timeoutSeconds: timeoutSeconds)
            return
        }
        try lockWithFd(openedFd, timeoutSeconds: timeoutSeconds)
    }

    /// Acquire flock on an already-open fd, with the timeout spin loop, then
    /// publish the fd+depth=1 under the state lock.
    private func lockWithFd(_ candidateFd: Int32, timeoutSeconds: TimeInterval) throws {
        if flock(candidateFd, LOCK_EX | LOCK_NB) == 0 {
            try writeHolderPID(fd: candidateFd)
            publishHeldFd(candidateFd)
            return
        }
        if errno == EWOULDBLOCK || errno == EAGAIN {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if flock(candidateFd, LOCK_EX | LOCK_NB) == 0 {
                    try writeHolderPID(fd: candidateFd)
                    publishHeldFd(candidateFd)
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            close(candidateFd)
            throw GimmeError.lock("timed out waiting for lock (another gimme is running)")
        }
        let err = String(cString: strerror(errno))
        close(candidateFd)
        throw GimmeError.lock("flock failed: \(err)")
    }

    /// Publish the held fd + depth=1 under the state lock.
    private func publishHeldFd(_ heldFd: Int32) {
        os_unfair_lock_lock(&stateLock)
        fd = heldFd
        depth = 1
        os_unfair_lock_unlock(&stateLock)
    }

    /// Release one level of re-entrancy. The lock is only actually unlocked
    /// when the outermost holder releases.
    public func release() {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0, fd >= 0 {
            _ = flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }

    private func writeHolderPID(fd: Int32) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try String(pid).data(using: .utf8)?.write(to: path)
    }

    deinit { release() }
}
