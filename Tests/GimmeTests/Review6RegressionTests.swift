import XCTest
@testable import GimmeCore

/// Regression tests for the sixth-pass review: mise prefix:<major> semantics,
/// the --tap flag, and unknown-flag handling.
final class Review6RegressionTests: XCTestCase {

    // MARK: S24 — mise prefix:<major> resolves to any major.x

    func testPrefixMajorResolvesToAnyMajorX() throws {
        // mise's prefix:3 means "any 3.x.x", NOT "any 3.0.x".
        let s = MiseVersionSpec.parse("prefix:3")
        XCTAssertEqual(s.kind, .prefixMajor(3))
        // The query is a bare major ("go@3"), which gimme's resolver parses as
        // fuzzyMajor(3) -> matches any 3.x.x.
        let query = try XCTUnwrap(s.toGimmeQuery(tool: "go"))
        XCTAssertEqual(query, "go@3")
        let constraint = try VersionConstraint.parse(String(query.dropFirst("go".count + 1)))
        XCTAssertTrue(constraint.matches(Version("3.0.0")!))
        XCTAssertTrue(constraint.matches(Version("3.19.0")!))
        XCTAssertTrue(constraint.matches(Version("3.99.9")!))
        XCTAssertFalse(constraint.matches(Version("4.0.0")!))
    }

    func testPrefixMajorMinorStillScopedToMinor() throws {
        // prefix:1.19 still means any 1.19.x (unchanged).
        let s = MiseVersionSpec.parse("prefix:1.19")
        XCTAssertEqual(s.kind, .prefix(1, 19))
        let query = try XCTUnwrap(s.toGimmeQuery(tool: "go"))
        XCTAssertEqual(query, "go@1.19")
        let constraint = try VersionConstraint.parse("1.19")
        XCTAssertTrue(constraint.matches(Version("1.19.0")!))
        XCTAssertTrue(constraint.matches(Version("1.19.5")!))
        XCTAssertFalse(constraint.matches(Version("1.20.0")!))
        XCTAssertFalse(constraint.matches(Version("1.18.9")!))
    }

    func testPrefixMajorEndToEndThroughResolver() throws {
        // End-to-end: a query built from prefix:2 should pick the highest 2.x.x,
        // not fail or pick only 2.0.x.
        struct Provider: FormulaProvider {
            let f: Formula
            func find(_ name: String) throws -> Formula { f }
        }
        let f = Formula(
            package: .init(name: "tool"),
            versions: [
                .init(ver: "2.0.0", assets: [Asset(arch: "arm64", os: "macos", url: "u1", sha256: "a")]),
                .init(ver: "2.5.0", assets: [Asset(arch: "arm64", os: "macos", url: "u2", sha256: "b")]),
                .init(ver: "3.0.0", assets: [Asset(arch: "arm64", os: "macos", url: "u3", sha256: "c")]),
            ]
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        let cellar = Cellar(paths: paths)
        let state = StateStore(paths: paths)
        state.cellar = cellar
        let host = Host(os: "macos", arch: "arm64", macosVersion: "14.0")
        let resolver = Resolver(provider: Provider(f: f), cellar: cellar, state: state, host: host)

        let spec = MiseVersionSpec.parse("prefix:2")
        let query = spec.toGimmeQuery(tool: "tool")!
        let res = try resolver.resolve(query: query)
        // Highest 2.x.x is 2.5.0, NOT 2.0.0 (the old buggy behavior).
        XCTAssertEqual(res.version, "2.5.0")
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: S25 — --tap fails loud (subprocess)

    func testTapFlagFailsLoud() throws {
        // --tap is documented but unimplemented; it must fail nonzero rather
        // than silently ignore the flag.
        let repoRoot = FixturePaths.repoRoot
        let binary = repoRoot.appendingPathComponent(".build/debug/gimme")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }

        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["--prefix", prefix.path, "list", "--tap", "mytap", "--json"]
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 1, "--tap should fail loud (not yet implemented)")
    }

    // MARK: S26 — unknown flags exit nonzero (subprocess)

    func testUnknownFlagExitsNonzero() throws {
        let repoRoot = FixturePaths.repoRoot
        let binary = repoRoot.appendingPathComponent(".build/debug/gimme")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }

        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["--prefix", prefix.path, "install", "foo", "--typo-flag"]
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 1, "unknown flag should exit nonzero")
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("unknown flag"), "stderr should mention unknown flag: \(stderr)")
    }

    func testKnownFlagStillWorks() throws {
        // A known flag does not trigger the unknown-flag exit.
        let repoRoot = FixturePaths.repoRoot
        let binary = repoRoot.appendingPathComponent(".build/debug/gimme")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }

        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }

        let task = Process()
        task.executableURL = binary
        task.arguments = ["--prefix", prefix.path, "list", "--json"]
        try task.run(); task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "known flag should not error")
    }
}
