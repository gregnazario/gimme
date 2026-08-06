import XCTest
@testable import GimmeCore

/// Integration tests: TapStore loads Homebrew-format .rb formulae and translates
/// them into gimme Formula structs via HomebrewLoader.
final class HomebrewTapIntegrationTests: XCTestCase {
    var paths: GimmePaths!
    var config: Config!
    var store: TapStore!

    override func setUp() {
        super.setUp()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = GimmePaths(prefix: tmp)
        try? paths.ensureDirectories()
        config = Config()
        store = TapStore(paths: paths, config: config)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.prefix)
        super.tearDown()
    }

    /// Create a fake Homebrew-format tap with .rb files in Formula/ dir.
    private func linkHomebrewTap() throws {
        let tapDir = paths.taps.appendingPathComponent("homebrew")
        let formulaDir = tapDir.appendingPathComponent("Formula")
        try FileManager.default.createDirectory(at: formulaDir, withIntermediateDirectories: true)

        // Write a simple formula that gimme can parse (has url + sha256).
        let ripgrep = """
        class Ripgrep < Formula
          desc "Search tool like grep"
          homepage "https://github.com/BurntSushi/ripgrep"
          url "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-aarch64-apple-darwin.tar.gz"
          sha256 "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"
          version "15.1.0"

          def install
            bin.install "rg"
          end
        end
        """
        try ripgrep.write(to: formulaDir.appendingPathComponent("ripgrep.rb"), atomically: true, encoding: .utf8)

        let fd = """
        class Fd < Formula
          desc "Simple, fast alternative to find"
          homepage "https://github.com/sharkdp/fd"
          url "https://github.com/sharkdp/fd/releases/download/v10.2.0/fd-v10.2.0-aarch64-apple-darwin.tar.gz"
          sha256 "623dc0afc81b92e4d4606b380d7bc91916ba7b97814263e554d50923a39e480a"

          def install
            bin.install "fd"
          end
        end
        """
        try fd.write(to: formulaDir.appendingPathComponent("fd.rb"), atomically: true, encoding: .utf8)
    }

    func testFindHomebrewFormula() throws {
        try linkHomebrewTap()
        let formula = try store.find("ripgrep")
        XCTAssertEqual(formula.name, "ripgrep")
        XCTAssertEqual(formula.package.desc, "Search tool like grep")
        XCTAssertEqual(formula.versions.first?.ver, "15.1.0")
        XCTAssertEqual(formula.versions.first?.assets.first?.url,
                       "https://github.com/BurntSushi/ripgrep/releases/download/15.1.0/ripgrep-15.1.0-aarch64-apple-darwin.tar.gz")
    }

    func testAllFormulaeIncludesHomebrew() throws {
        try linkHomebrewTap()
        let all = store.allFormulae()
        let names = Set(all.map(\.name))
        XCTAssertTrue(names.contains("ripgrep"))
        XCTAssertTrue(names.contains("fd"))
    }

    func testSearchFindsHomebrewFormulae() throws {
        try linkHomebrewTap()
        let results = store.allFormulae()
            .filter { $0.name.contains("fd") || ($0.package.desc?.lowercased().contains("search") ?? false) }
        XCTAssertGreaterThanOrEqual(results.count, 2, "should find both ripgrep (desc has 'search') and fd (name has 'fd')")
    }

    func testMixedGimmeAndHomebrewTaps() throws {
        // gimme-format tap (our starter tap)
        let gimmeTap = paths.taps.appendingPathComponent("core").appendingPathComponent("bat")
        try FileManager.default.createDirectory(at: gimmeTap, withIntermediateDirectories: true)
        try """
        [package]
        name = "bat"
        desc = "A cat clone"
        [[version]]
        ver = "0.26.1"
        [[version.asset]]
        url = "https://example.com/bat.tar.gz"
        sha256 = "abc"
        [install]
        strategy = "steps"
        [[install.step]]
        extract = "${asset}"
        [[provides]]
        bin = ["bat"]
        """.write(to: gimmeTap.appendingPathComponent("formula.toml"), atomically: true, encoding: .utf8)

        // Homebrew-format tap
        try linkHomebrewTap()

        let all = store.allFormulae()
        let names = Set(all.map(\.name))
        XCTAssertTrue(names.contains("bat"))       // from gimme tap
        XCTAssertTrue(names.contains("ripgrep"))   // from homebrew tap
        XCTAssertTrue(names.contains("fd"))        // from homebrew tap
    }
}
