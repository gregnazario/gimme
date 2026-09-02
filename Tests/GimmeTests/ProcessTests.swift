import XCTest
@testable import GimmeCore

final class ProcessTests: XCTestCase {
    /// Stream callbacks fire on the pipe-handler thread; a lock-guarded box
    /// makes the capture @Sendable-safe.
    final class LineRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        var values: [String] { lock.withLock { lines } }
        func append(_ line: String) { lock.withLock { lines.append(line) } }
    }

    private let runner = ProcessRunner()
    private let nilStream: (@Sendable (String) -> Void)? = nil

    func testRunEcho() async throws {
        let result = try await runner.run("/bin/echo", args: ["hello"], env: nil, stream: nilStream)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testRunExitCode() async throws {
        let result = try await runner.run("/bin/sh", args: ["-c", "exit 3"], env: nil, stream: nilStream)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testRunStderr() async throws {
        let result = try await runner.run("/bin/sh", args: ["-c", "echo oops >&2"], env: nil, stream: nilStream)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
    }

    func testStreamCallback() async throws {
        let lines = LineRecorder()
        _ = try await runner.run("/bin/sh", args: ["-c", "echo a; echo b"], env: nil) { line in
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(lines.values, ["a", "b"])
    }

    func testRunMissingExecutableThrows() async throws {
        do {
            _ = try await runner.run("/nonexistent/binary", args: [], env: nil, stream: nilStream)
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(true)
        }
    }
}
