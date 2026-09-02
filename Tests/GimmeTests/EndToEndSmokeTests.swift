import XCTest
@testable import GimmeCore

final class EndToEndSmokeTests: XCTestCase {
    /// Exercises Resolver → HomebrewManager(stubbed) → Cache invalidation,
    /// proving the orchestration loop compiles and runs together.
    func testResolveAndInstallAndInvalidate() async throws {
        final class FakeHTTP: HTTPClient, @unchecked Sendable {
            func data(for url: URL) async throws -> Data {
                if url.absoluteString.contains("formula.json") {
                    return Data(#"[{"name":"ripgrep","desc":"rg","versions":{"stable":"14.1.0"}}]"#.utf8)
                }
                return Data()
            }
        }
        final class FakeProcess: ProcessRunning, @unchecked Sendable {
            var installed: [String: String] = [:]
            func run(_ executable: String, args: [String], env: [String: String]?, stream: (@Sendable (String) -> Void)?) async throws -> ProcessResult {
                if executable.contains("brew") {
                    if args.first == "install" {
                        installed[args[1]] = "14.1.0"
                        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
                    }
                    if args.first == "search" {
                        // `brew search ripgrep` → names only.
                        return ProcessResult(exitCode: 0, stdout: "ripgrep\n", stderr: "")
                    }
                    if args.first == "list" {
                        let items = installed.map { #"{"name":"\#($0.key)","versions":["\#($0.value)"]}"# }.joined(separator: ",")
                        return ProcessResult(exitCode: 0, stdout: "{\"formulae\":[\(items)],\"casks\":[]}", stderr: "")
                    }
                }
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = Cache(directory: dir.appendingPathComponent("cache"))
        let brew = HomebrewManager(http: FakeHTTP(), process: FakeProcess(), brewBinary: "/opt/homebrew/bin/brew")
        let registry = Registry(managers: [brew])
        let resolver = Resolver(registry: registry, preferences: Preferences(), config: .defaults)

        // Resolve
        let resolved = await resolver.resolve("ripgrep", hint: nil)
        guard case .chosen(let manager) = resolved else { return XCTFail("expected chosen") }

        // Install
        let result = try await manager.install(PackageRef(name: "ripgrep"), options: InstallOptions())
        XCTAssertEqual(result.package.version, "14.1.0")

        // List reflects install (cache miss → live)
        let list = try await manager.listInstalled()
        XCTAssertTrue(list.contains { $0.name == "ripgrep" })

        // Invalidate + cache round-trip
        cache.set("homebrew:list", value: list)
        XCTAssertEqual(cache.get("homebrew:list", ttlSeconds: 60, as: [InstalledPackage].self)?.count, 1)
        cache.invalidate("homebrew:list")
        XCTAssertNil(cache.get("homebrew:list", ttlSeconds: 60, as: [InstalledPackage].self))
    }
}
