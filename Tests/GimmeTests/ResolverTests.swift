import XCTest
@testable import GimmeCore

/// An in-memory FormulaProvider for Resolver tests.
struct MockProvider: FormulaProvider {
    let formulae: [String: Formula]
    func find(_ name: String) throws -> Formula {
        if let f = formulae[name] { return f }
        throw GimmeError.notFound("no formula '\(name)'")
    }
}

final class ResolverTests: XCTestCase {
    var paths: GimmePaths!
    var cellar: Cellar!
    var state: StateStore!
    let host = Host(os: "macos", arch: "arm64", macosVersion: "14.0")

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        cellar = Cellar(paths: paths)
        state = StateStore(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    private func asset(_ sha: String = "abc") -> Asset {
        Asset(arch: "arm64", os: "macos", url: "u", sha256: sha)
    }

    func testResolveLatest() throws {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "1.0.0", assets: [asset()]),
            .init(ver: "2.0.0", assets: [asset()]),
        ])
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x")
        XCTAssertEqual(res.version, "2.0.0")
    }

    func testResolveExact() throws {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "1.0.0", assets: [asset()]),
            .init(ver: "2.0.0", assets: [asset()]),
        ])
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x@1.0.0")
        XCTAssertEqual(res.version, "1.0.0")
    }

    func testResolveMajorMinor() throws {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "2.39.0", assets: [asset()]),
            .init(ver: "2.40.0", assets: [asset()]),
            .init(ver: "2.40.1", assets: [asset()]),
            .init(ver: "2.41.0", assets: [asset()]),
        ])
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x@2.40")
        XCTAssertEqual(res.version, "2.40.1")
    }

    func testResolvePinnedVersion() throws {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "1.0.0", assets: [asset()]),
            .init(ver: "2.0.0", assets: [asset()]),
        ])
        try state.pin("x", version: "1.0.0")
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x")
        XCTAssertEqual(res.version, "1.0.0")
    }

    func testResolveReusesInstalledActive() throws {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "1.0.0", assets: [asset()]),
            .init(ver: "2.0.0", assets: [asset()]),
        ])
        try state.recordInstalled("x", version: "1.0.0")
        try state.setActive("x", version: "1.0.0")
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        // Bare `x` should reuse active 1.0.0 even though 2.0.0 exists.
        let res = try r.resolve(query: "x")
        XCTAssertEqual(res.version, "1.0.0")
    }

    func testResolveNoHostAsset() {
        let f = Formula(package: .init(name: "x"), versions: [
            .init(ver: "1.0.0", assets: [Asset(arch: "x86_64", os: "macos", url: "u", sha256: "s")]),
        ])
        let r = Resolver(provider: MockProvider(formulae: ["x": f]),
                         cellar: cellar, state: state, host: host)
        XCTAssertThrowsError(try r.resolve(query: "x")) { error in
            guard case GimmeError.notFound = error else { XCTFail("expected notFound, got \(error)"); return }
        }
    }

    func testResolveDependencyReuse() throws {
        let dep = Formula(package: .init(name: "gettext"), versions: [
            .init(ver: "0.21.1", assets: [asset()]),
        ])
        let x = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0", assets: [asset()])],
            deps: [.init(name: "gettext", ver: ">=0.21")]
        )
        try state.recordInstalled("gettext", version: "0.21.1")
        try state.setActive("gettext", version: "0.21.1")
        let r = Resolver(provider: MockProvider(formulae: ["x": x, "gettext": dep]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x")
        XCTAssertEqual(res.deps.count, 1)
        XCTAssertEqual(res.deps[0].version, "0.21.1")  // reused
    }

    func testResolveDependencyNotFoundSkipsGracefully() throws {
        // Soft-fail: deps not in any tap are skipped (not aborted). This lets
        // gimme install Homebrew formulae with build-only deps it doesn't need.
        let x = Formula(
            package: .init(name: "x"),
            versions: [.init(ver: "1.0.0", assets: [asset()])],
            deps: [.init(name: "missing", ver: nil)]
        )
        let r = Resolver(provider: MockProvider(formulae: ["x": x]),
                         cellar: cellar, state: state, host: host)
        let res = try r.resolve(query: "x")
        XCTAssertEqual(res.version, "1.0.0")
        XCTAssertTrue(res.deps.isEmpty, "unresolvable deps should be skipped, not abort")
    }

    func testParseQueryNoAt() throws {
        let r = Resolver(provider: MockProvider(formulae: [:]),
                         cellar: cellar, state: state, host: host)
        let (name, c) = try r.parseQuery("git")
        XCTAssertEqual(name, "git")
        if case .any = c {} else { XCTFail("expected any") }
    }

    func testParseQueryWithConstraint() throws {
        let r = Resolver(provider: MockProvider(formulae: [:]),
                         cellar: cellar, state: state, host: host)
        let (name, _) = try r.parseQuery("git@2.40")
        XCTAssertEqual(name, "git")
    }
}
