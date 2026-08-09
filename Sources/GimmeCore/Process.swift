import Foundation

/// Result of a subprocess run.
public struct ProcessResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Resolves the on-disk path of an executable by name, via `which`. Caches the
/// result so repeated calls don't shell out. Adapters use this instead of
/// hardcoded paths so they work with mise/asdf/volta/rustup home dirs.
///
/// Returns nil when the binary isn't on PATH. The `fallback` is used only when
/// `which` itself is unavailable (extremely unusual), letting callers fall
/// back to a conventional default.
public enum BinaryResolver {
    /// Cache of resolved paths. Only stores *found* binaries (a missing key
    /// means "not yet looked up"). Storing nil (not-found) would force callers
    /// to handle optionals-of-optionals; instead we re-resolve on a miss,
    /// which is cheap and avoids the class of crash a double-unwrap causes.
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Directories prepended to PATH when resolving, so GUI launches (which get
    /// a minimal PATH) can still find mise/asdf/homebrew/cargo/bun binaries.
    private static let extraPathDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.local/share/mise/bin",
        ]
    }()

    /// Resolve `name` to an absolute path, or nil if not found on PATH.
    public static func resolve(_ name: String, fallback: String? = nil) -> String? {
        lock.lock()
        if let cached = cache[name] { lock.unlock(); return cached }
        lock.unlock()

        let path = lookup(name) ?? fallback
        if let path {
            lock.lock(); cache[name] = path; lock.unlock()
        }
        return path
    }

    /// Run `which <name>` with an augmented PATH. Returns nil if not found.
    private static func lookup(_ name: String) -> String? {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        // Augment PATH so mise/asdf/homebrew/cargo/bun binaries are found even
        // when the process was launched from Finder (minimal PATH).
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let augmented = extraPathDirs.joined(separator: ":") + ":" + existingPath
        proc.environment = ["PATH": augmented]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let first = raw.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
        return (first?.isEmpty == false) ? first : nil
    }

    /// Forget cached resolutions (mainly for tests).
    public static func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}

/// Indirection so adapters can be tested with a stub instead of a real Process.
/// Production code injects a `ProcessRunner` value; tests inject a custom conformer.
public protocol ProcessRunning {
    func run(
        _ executable: String,
        args: [String],
        env: [String: String]?,
        stream: ((String) -> Void)?
    ) async throws -> ProcessResult
}

/// Thin wrapper around Foundation.Process with optional line streaming.
/// All adapters use this; never call Foundation.Process directly elsewhere.
/// Conforms to `ProcessRunning`; `ProcessRunner()` is the production default.
public struct ProcessRunner: ProcessRunning {
    public init() {}

    /// Run a command, returning when it exits. If `stream` is non-nil, each
    /// complete line of combined stdout/stderr is delivered to it as it arrives.
    ///
    /// Streaming splits each pipe's output on newlines, carrying any
    /// unterminated tail until the next chunk. When no stream is requested,
    /// both pipes are read fully after exit (cheaper).
    public func run(
        _ executable: String,
        args: [String],
        env: [String: String]? = nil,
        stream: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let proc = Foundation.Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        if let env { proc.environment = env }

        let stdoutCarry = LineCarry()
        let stderrCarry = LineCarry()

        if stream != nil {
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stdoutCarry.deliver(chunk, to: stream!)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                stderrCarry.deliver(chunk, to: stream!)
            }
        }

        try proc.run()
        proc.waitUntilExit()

        // Stop handlers before draining remainder.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutData: Data
        let stderrData: Data
        if let stream = stream {
            // Drain whatever remains after the handlers were stopped, then flush
            // any partial line still held in the carry buffers.
            let rest = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let restErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutCarry.deliver(rest, to: stream)
            stderrCarry.deliver(restErr, to: stream)
            stdoutData = Data(stdoutCarry.flushed.utf8)
            stderrData = Data(stderrCarry.flushed.utf8)
        } else {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

/// Accumulates byte chunks, splits them on newlines, delivers complete lines,
/// and holds the trailing partial line until more data arrives. Isolated
/// per-pipe via instance state (no globals).
final class LineCarry {
    /// Already-delivered (line-streamed) text, concatenated for the final result.
    fileprivate(set) var flushed: String = ""
    /// A partial line not yet terminated by a newline.
    private var pending: String = ""

    func deliver(_ data: Data, to callback: (String) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var combined = pending + text
        pending = ""
        while let nl = combined.firstIndex(of: "\n") {
            let line = String(combined[..<nl])
            combined.removeSubrange(combined.startIndex...nl)
            flushed += line + "\n"
            callback(line)
        }
        if !combined.isEmpty { pending = combined }
    }
}
