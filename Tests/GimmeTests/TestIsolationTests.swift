import XCTest
@testable import GimmeCore

/// Enforces the suite's isolation contract (AGENTS.md: "in-process — no real
/// network, no real installs"). Born of a 2026-08-22 incident: a live-verify
/// against a stale binary accidentally ran a REAL `update all` on the dev
/// machine. These rules keep the *suite* structurally incapable of that:
///
/// 1. `defaultRegistry` must never appear in tests — it wires the real
///    adapters with real network and real package-manager binaries.
/// 2. `URLSessionHTTPClient` must never make requests in tests — all network
///    goes through stubs. (HTTPClientTests constructs one purely as a type
///    check, the single allowlisted file.)
/// 3. Real adapters must never be constructed with default arguments — a
///    zero-arg `XManager()` means URLSession + the machine's real binaries.
///    Tests always inject `http:`/`process:` stubs.
final class TestIsolationTests: XCTestCase {
    /// The single allowlist: file name → patterns it may contain.
    private static let allowlist: [String: Set<String>] = [
        "HTTPClientTests.swift": ["URLSessionHTTPClient"],
    ]

    private static let forbiddenPatterns: [(pattern: String, reason: String)] = [
        ("defaultRegistry", "constructs the real adapter registry (real network + real binaries)"),
        ("URLSessionHTTPClient", "real network client — inject a stub HTTPClient instead"),
    ]

    /// Zero-arg constructions of real adapters (default = URLSession + real binaries).
    private static let adapterTypes = [
        "HomebrewManager", "GoManager", "UvManager", "CargoManager", "BunManager",
        "NpmManager", "PnpmManager", "YarnManager", "GemManager", "ComposerManager",
        "DenoManager", "PipxManager", "AquaManager", "UbiManager", "AppStoreManager",
        "SelfUpdate",
    ]

    func testSuiteNeverUsesRealNetworkOrRealRegistries() throws {
        let testsDir = URL(fileURLWithPath: #filePath)  // .../Tests/GimmeTests/TestIsolationTests.swift
            .deletingLastPathComponent()
        let fm = FileManager.default
        var violations: [String] = []
        var checked = 0

        if let enumerator = fm.enumerator(at: testsDir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let name = url.lastPathComponent
                if name == "TestIsolationTests.swift" { continue }  // this file's own docs mention the patterns
                let allowed = Self.allowlist[name] ?? []
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                for line in source.components(separatedBy: "\n").enumerated() {
                    for rule in Self.forbiddenPatterns where line.element.contains(rule.pattern) {
                        if allowed.contains(rule.pattern) { continue }
                        violations.append("\(name):\(line.offset + 1): `\(rule.pattern)` — \(rule.reason)")
                    }
                    for adapter in Self.adapterTypes
                    where line.element.contains("\(adapter)()") && !allowed.contains(adapter) {
                        violations.append("\(name):\(line.offset + 1): `\(adapter)()` — default init uses the real network and real binaries; inject http:/process: stubs")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "could not scan test sources — is the checkout intact?")
        XCTAssertTrue(violations.isEmpty,
            "test-isolation violations (see AGENTS.md):\n" + violations.joined(separator: "\n"))
    }
}
