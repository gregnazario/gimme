import XCTest
@testable import GimmeCore

final class TOMLTests: XCTestCase {
    func testScalarValues() throws {
        let t = try TOML.parse("""
        a = "hi"
        b = 1
        c = 1.5
        d = true
        e = 'raw'
        """)
        XCTAssertEqual(t.string("a"), "hi")
        XCTAssertEqual(t.integer("b"), 1)
        XCTAssertEqual(t.double("c"), 1.5)
        XCTAssertEqual(t.bool("d"), true)
        XCTAssertEqual(t.string("e"), "raw")
    }

    func testTable() throws {
        let t = try TOML.parse("""
        [package]
        name = "git"
        """)
        let pkg = try XCTUnwrap(t.table("package"))
        XCTAssertEqual(pkg.string("name"), "git")
    }

    func testArrayOfTables() throws {
        let t = try TOML.parse("""
        [[version]]
        ver = "1.0.0"

        [[version]]
        ver = "2.0.0"
        """)
        let arr = try XCTUnwrap(t.array("version"))
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0].asTable?.string("ver"), "1.0.0")
        XCTAssertEqual(arr[1].asTable?.string("ver"), "2.0.0")
    }

    func testNestedTable() throws {
        let t = try TOML.parse("""
        [install]
        strategy = "lua"
        script = "install.lua"

        [livecheck]
        strategy = "github-release"
        """)
        let ins = try XCTUnwrap(t.table("install"))
        XCTAssertEqual(ins.string("strategy"), "lua")
        XCTAssertEqual(t.table("livecheck")?.string("strategy"), "github-release")
    }

    func testComments() throws {
        let t = try TOML.parse("""
        a = 1  # comment
        # whole line
        b = 2
        """)
        XCTAssertEqual(t.integer("a"), 1)
        XCTAssertEqual(t.integer("b"), 2)
    }

    func testArray() throws {
        let t = try TOML.parse(#"items = ["a", "b", "c"]"#)
        let arr = try XCTUnwrap(t.array("items"))
        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr[1].asString, "b")
    }

    func testDottedHeader() throws {
        let t = try TOML.parse("""
        [taps.core]
        url = "https://example.com"
        enabled = true
        """)
        let core = try XCTUnwrap(t.table("taps")?.table("core"))
        XCTAssertEqual(core.string("url"), "https://example.com")
        XCTAssertEqual(core.bool("enabled"), true)
    }

    func testArrayOfTablesNestedKeys() throws {
        let t = try TOML.parse("""
        [[version]]
        ver = "2.40.0"

        [[version.asset]]
        os = "macos"
        arch = "arm64"
        url = "https://x/git.tar.gz"
        sha256 = "abc"
        """)
        let versions = try XCTUnwrap(t.array("version"))
        let first = try XCTUnwrap(versions[0].asTable)
        let assets = try XCTUnwrap(first.array("asset"))
        XCTAssertEqual(assets.count, 1)
        let asset = try XCTUnwrap(assets[0].asTable)
        XCTAssertEqual(asset.string("arch"), "arm64")
        XCTAssertEqual(asset.string("sha256"), "abc")
    }

    func testInlineTableValue() throws {
        let t = try TOML.parse(#"step = { from = "a", to = "b" }"#)
        let step = try XCTUnwrap(t.table("step"))
        XCTAssertEqual(step.string("from"), "a")
        XCTAssertEqual(step.string("to"), "b")
    }

    func testDecodeCodable() throws {
        struct S: Decodable, Equatable { let a: String; let b: Int }
        let data = """
        a = "hi"
        b = 1
        """.data(using: .utf8)!
        let s = try TOMLDecoder().decode(S.self, from: data)
        XCTAssertEqual(s, S(a: "hi", b: 1))
    }
}
