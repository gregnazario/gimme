import XCTest
@testable import GimmeCore

final class ProcessTests: XCTestCase {
    private let runner = ProcessRunner()
    private let nilStream: ((String) -> Void)? = nil

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
        var lines: [String] = []
        _ = try await runner.run("/bin/sh", args: ["-c", "echo a; echo b"], env: nil) { line in
            lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(lines, ["a", "b"])
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
