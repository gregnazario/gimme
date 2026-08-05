import XCTest
@testable import GimmeCore

/// Subprocess tests: invoke the actual `gimme` binary against a temp prefix
/// to verify the real CLI (argv parsing, exit codes, --json output) works,
/// not just the in-process Gimme.run. These protect the agent contract from
/// drift in the wrapper layer.
final class CLISnapshotTests: XCTestCase {
    var tmp: URL!
    var binaryPath: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // Locate the built binary in the standard .build/<arch>-apple-darwin/debug dir.
        let repoRoot = FixturePaths.repoRoot
        let candidates = [
            repoRoot.appendingPathComponent(".build/debug/gimme"),
            repoRoot.appendingPathComponent(".build").appendingPathComponent("debug").appendingPathComponent("gimme"),
        ]
        binaryPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func runCLI(_ args: [String]) -> (stdout: String, exitCode: Int32) {
        guard let binary = binaryPath else {
            // Skip subprocess tests if the binary isn't built (CI may not pre-build).
            return ("", -1)
        }
        let task = Process()
        task.executableURL = binary
        var fullArgs = ["--prefix", tmp.path]
        fullArgs.append(contentsOf: args)
        task.arguments = fullArgs
        let outPipe = Pipe(); task.standardOutput = outPipe
        let errPipe = Pipe(); task.standardError = errPipe
        do { try task.run() } catch { return ("", -1) }
        task.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "", task.terminationStatus)
    }

    func testVersion() throws {
        let (out, code) = runCLI(["--version"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("gimme "))
    }

    func testHelp() throws {
        let (out, code) = runCLI(["--help"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("install"))
        XCTAssertTrue(out.contains("introspect"))
    }

    func testListEmptyJSON() throws {
        guard binaryPath != nil else { return }
        let (out, code) = runCLI(["list", "--json"])
        XCTAssertEqual(code, 0)
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(json["cmd"] as? String, "list")
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["schema_version"] as? Int, 1)
    }

    func testIntrospectJSONShape() throws {
        guard binaryPath != nil else { return }
        let (out, code) = runCLI(["introspect", "--json"])
        XCTAssertEqual(code, 0)
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil(json["commands"])
    }

    func testDoctorJSON() throws {
        guard binaryPath != nil else { return }
        let (out, code) = runCLI(["doctor", "--json"])
        XCTAssertEqual(code, 0)
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(json["cmd"] as? String, "doctor")
        XCTAssertNotNil(json["checks"])
    }

    func testUnknownToolExitCode() throws {
        guard binaryPath != nil else { return }
        let (out, code) = runCLI(["install", "definitely-missing", "--json"])
        XCTAssertEqual(code, 1)
        let json = try XCTUnwrap(try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, false)
        let err = json["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? String, "NOT_FOUND")
    }
}
