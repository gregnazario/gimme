import XCTest
@testable import GimmeCore

final class MiseConfigTests: XCTestCase {
    var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: .tool-versions

    func testParseToolVersionsBasic() {
        let r = MiseConfig.parseToolVersions("""
        node 20.0.0       # comment
        ruby 3
        shellcheck latest
        """)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r[0].tool, "node")
        XCTAssertEqual(r[0].spec.kind, .exact(Version("20.0.0")!))
        XCTAssertEqual(r[1].tool, "ruby")
        XCTAssertEqual(r[1].spec.kind, .fuzzyMajor(3))
        XCTAssertEqual(r[2].spec.kind, .latest)
    }

    func testParseToolVersionsDropsMalformed() {
        let r = MiseConfig.parseToolVersions("""
        nodeonly
        valid 1.0.0
        """)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].tool, "valid")
    }

    func testParseToolVersionsIgnoresBlankAndComment() {
        let r = MiseConfig.parseToolVersions("""

        # full line comment
        go 1.21
        """)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].tool, "go")
    }

    func testParseToolVersionsScopedSpecs() {
        let r = MiseConfig.parseToolVersions("erlang ref:master")
        XCTAssertEqual(r.count, 1)
        if case .unsupported = r[0].spec.kind {} else { XCTFail() }
    }

    // MARK: mise.toml

    func testParseMiseTomlStringValues() throws {
        let data = """
        [tools]
        node = "20"
        python = "3.12"
        """.data(using: .utf8)!
        let r = try MiseConfig.parseMiseToml(data)
        XCTAssertEqual(r.count, 2)
        let node = r.first { $0.tool == "node" }
        XCTAssertEqual(node?.spec.kind, .fuzzyMajor(20))
    }

    func testParseMiseTomlInlineTable() throws {
        let data = """
        [tools]
        node = { version = "22", postinstall = "corepack enable" }
        """.data(using: .utf8)!
        let r = try MiseConfig.parseMiseToml(data)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].spec.kind, .fuzzyMajor(22))
    }

    func testParseMiseTomlIgnoresOtherSections() throws {
        let data = """
        [env]
        FOO = "bar"

        [tools]
        ripgrep = "latest"
        """.data(using: .utf8)!
        let r = try MiseConfig.parseMiseToml(data)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].tool, "ripgrep")
    }

    func testParseMiseTomlNoToolsSection() throws {
        let data = "[env]\nFOO=\"bar\"".data(using: .utf8)!
        let r = try MiseConfig.parseMiseToml(data)
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: discover (walk + merge)

    func testDiscoverEmptyWhenNoConfig() {
        let (reqs, source) = MiseConfig.discover(startingAt: tmp)
        XCTAssertTrue(reqs.isEmpty)
        XCTAssertNil(source)
    }

    func testDiscoverToolVersionsInCwd() throws {
        try "node 20\n".write(to: tmp.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let (reqs, source) = MiseConfig.discover(startingAt: tmp)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].tool, "node")
        XCTAssertEqual(source, ".tool-versions")
    }

    func testDiscoverMiseTomlInCwd() throws {
        try "[tools]\nnode = \"20\"\n".write(to: tmp.appendingPathComponent("mise.toml"), atomically: true, encoding: .utf8)
        let (reqs, source) = MiseConfig.discover(startingAt: tmp)
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(source, "mise.toml")
    }

    func testDiscoverStopsAtGitRoot() throws {
        // Project dir has .git + node config; parent has different node config.
        let parent: URL = tmp
        try "node 18\n".write(to: parent.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        let proj = parent.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try "node 20\ngo 1.21\n".write(to: proj.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: proj.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let (reqs, _) = MiseConfig.discover(startingAt: proj)
        // Walk stops at .git -> only proj's config is seen.
        let tools = reqs.map { $0.tool }
        XCTAssertEqual(tools, ["node", "go"])
        XCTAssertEqual(reqs.first { $0.tool == "node" }?.spec.kind, .fuzzyMajor(20))
    }

    func testDiscoverMergeCloserWins() throws {
        // Two-layer tree bounded by a .git at parent so the walk is contained.
        let parent: URL = tmp
        try "node 18\nruby 3\n".write(to: parent.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let child = parent.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "node 20\n".write(to: child.appendingPathComponent(".tool-versions"), atomically: true, encoding: .utf8)

        let (reqs, _) = MiseConfig.discover(startingAt: child)
        let byTool = Dictionary(uniqueKeysWithValues: reqs.map { ($0.tool, $0) })
        // child's node=20 overrides parent's node=18; ruby accumulates.
        if case .fuzzyMajor(let m) = byTool["node"]?.spec.kind { XCTAssertEqual(m, 20) }
        else { XCTFail("node missing or wrong") }
        XCTAssertEqual(byTool["ruby"]?.spec.kind, .fuzzyMajor(3))
    }
}
