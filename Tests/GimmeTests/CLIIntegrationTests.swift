import XCTest
@testable import GimmeCore

final class CLIIntegrationTests: XCTestCase {
    // Uses stub managers wired via the test factory below.
    private func makeGimme(registry: Registry, tmp: URL) throws -> Gimme {
        let prefs = Preferences()
        let cfg = Config.defaults
        return Gimme(registry: registry, preferences: prefs, config: cfg,
                     cache: Cache(directory: tmp.appendingPathComponent("cache")),
                     preferencesFile: tmp.appendingPathComponent("preferences.toml"))
    }

    func testInstallResolvesAndInvokesManager() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: ["ripgrep"])
        let gimme = try makeGimme(registry: Registry(managers: [brew]), tmp: tmp)
        let result = try await gimme.install(name: "ripgrep", from: nil, options: InstallOptions())
        XCTAssertEqual(result.package.manager, .homebrew)
        XCTAssertEqual(result.package.name, "ripgrep")
    }

    func testInstallWithFromOverridesAndRemembers() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: ["rg"])
        let cargo = SearchableStubManager(id: .cargo, available: true, known: ["rg"])
        let gimme = try makeGimme(registry: Registry(managers: [brew, cargo]), tmp: tmp)
        _ = try await gimme.install(name: "rg", from: .cargo, options: InstallOptions())
        // After --from cargo, the preference is remembered.
        let prefs = Preferences.load(at: tmp.appendingPathComponent("preferences.toml"))
        XCTAssertEqual(prefs.remembered(for: "rg"), .cargo)
    }

    func testInstallNotFoundThrows() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let brew = SearchableStubManager(id: .homebrew, available: true, known: [])
        let gimme = try makeGimme(registry: Registry(managers: [brew]), tmp: tmp)
        do {
            _ = try await gimme.install(name: "nope", from: nil, options: InstallOptions())
            XCTFail("expected throw")
        } catch GimmeError.notFoundInManagers(let name, _) {
            XCTAssertEqual(name, "nope")
        }
    }
}
