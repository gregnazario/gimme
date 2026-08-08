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
