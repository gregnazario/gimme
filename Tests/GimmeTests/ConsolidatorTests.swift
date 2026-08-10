import XCTest
@testable import GimmeCore

final class ConsolidatorTests: XCTestCase {
    private func pkg(_ name: String, _ manager: ManagerID) -> InstalledPackage {
        InstalledPackage(name: name, version: "1.0", manager: manager, installedAt: nil)
    }

    // MARK: - EcosystemPreferences

    func testPreferencesDefaultToFirstManagerInEcosystem() {
        let prefs = EcosystemPreferences()
        XCTAssertEqual(prefs.recommended(for: .js), Ecosystem.js.managers.first)       // bun
        XCTAssertEqual(prefs.recommended(for: .python), Ecosystem.python.managers.first) // uv
    }

    func testPreferencesHonoredWhenSet() {
        var prefs = EcosystemPreferences()
        prefs.preferences[.js] = .pnpm
        XCTAssertEqual(prefs.recommended(for: .js), .pnpm)
    }

    // MARK: - Duplicate detection

    func testSameNameSameEcosystemIsDuplicate() {
        let installed = [pkg("esbuild", .bun), pkg("esbuild", .npm)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        XCTAssertEqual(report.duplicates.count, 1)
        XCTAssertEqual(report.duplicates.first?.name, "esbuild")
        XCTAssertEqual(Set(report.duplicates.first!.installed.map { $0.manager }), [.bun, .npm])
    }

    func testSameNameDifferentEcosystemsNotDuplicate() {
        // ripgrep in homebrew (System) and cargo (Rust) — different ecosystems.
        let installed = [pkg("ripgrep", .homebrew), pkg("ripgrep", .cargo)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        XCTAssertEqual(report.duplicates.count, 0)
        XCTAssertTrue(report.cleanEcosystems.contains(.system))
        XCTAssertTrue(report.cleanEcosystems.contains(.rust))
    }

    func testThreeManagersOneDuplicate() {
        let installed = [pkg("prettier", .bun), pkg("prettier", .npm), pkg("prettier", .pnpm)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        XCTAssertEqual(report.duplicates.count, 1)
        XCTAssertEqual(report.duplicates.first?.installed.count, 3)
    }

    func testNoDuplicatesCleanReport() {
        let installed = [pkg("esbuild", .bun), pkg("black", .uv)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        XCTAssertTrue(report.duplicates.isEmpty)
        XCTAssertTrue(report.hasDuplicates == false)
    }

    // MARK: - Recommendation + migration steps

    func testRecommendedManagerFromPreferences() {
        var prefs = EcosystemPreferences()
        prefs.preferences[.js] = .npm
        let installed = [pkg("esbuild", .bun), pkg("esbuild", .npm)]
        let report = Consolidator(preferences: prefs).report(for: installed)
        XCTAssertEqual(report.duplicates.first?.recommendedManager, .npm)
    }

    func testInstallCommandOmittedWhenRecommendedAlreadyHasIt() {
        // Recommended = npm (from prefs), npm already has it → only uninstall bun.
        var prefs = EcosystemPreferences()
        prefs.preferences[.js] = .npm
        let installed = [pkg("esbuild", .bun), pkg("esbuild", .npm)]
        let report = Consolidator(preferences: prefs).report(for: installed)
        let step = report.steps.first!
        XCTAssertNil(step.installCommand, "should not install when recommended already has it")
        XCTAssertEqual(step.uninstallCommands, ["gimme uninstall esbuild --from bun"])
    }

    func testInstallCommandEmittedWhenRecommendedDoesNotHaveIt() {
        // Recommended = bun (default first JS manager), but bun doesn't have it;
        // npm and pnpm do → install into bun, uninstall from the others.
        let installed = [pkg("prettier", .npm), pkg("prettier", .pnpm)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        let step = report.steps.first!
        XCTAssertEqual(step.installCommand, "gimme install prettier --from bun")
        XCTAssertEqual(Set(step.uninstallCommands), ["gimme uninstall prettier --from npm", "gimme uninstall prettier --from pnpm"])
    }

    func testDuplicatesSortedByEcosystemThenName() {
        let installed = [
            pkg("zebra", .bun), pkg("zebra", .npm),
            pkg("apple", .uv), pkg("apple", .pipx),
            pkg("mango", .bun), pkg("mango", .npm)
        ]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        // Sort is (ecosystem.rawValue, name): js < python alphabetically,
        // so JS dups (mango, zebra) come before Python (apple); within an
        // ecosystem, by name.
        XCTAssertEqual(report.duplicates.map { $0.name }, ["mango", "zebra", "apple"])
        XCTAssertEqual(report.duplicates.map { $0.ecosystem }, [.js, .js, .python])
    }

    func testCleanEcosystemsListedEvenWhenOthersHaveDuplicates() {
        let installed = [pkg("esbuild", .bun), pkg("esbuild", .npm), pkg("black", .uv)]
        let report = Consolidator(preferences: EcosystemPreferences()).report(for: installed)
        XCTAssertEqual(report.duplicates.count, 1)
        // Python has packages but no duplicates → still "clean" (no dups).
        XCTAssertTrue(report.cleanEcosystems.contains(.python))
        XCTAssertFalse(report.cleanEcosystems.contains(.js))
    }
}
