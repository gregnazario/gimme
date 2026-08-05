import XCTest
@testable import GimmeCore

final class HomebrewLoaderTests: XCTestCase {
    // A representative Homebrew formula (simplified, not a real tool).
    private let sampleFormula = """
    class HelloTool < Formula
      desc "A demonstration tool that says hello"
      homepage "https://example.com/hello"
      license "MIT"

      stable do
        url "https://example.com/hello-2.3.4.tar.gz"
        sha256 "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"

        depends_on "autoconf" => :build
        depends_on "pkg-config" => :build
      end

      def install
        system "./configure", "--prefix=#{prefix}"
        system "make", "install"
        bin.install "hello"
        bin.install "hello-config"
      end
    end
    """

    func testParseBasicFormula() throws {
        let f = try XCTUnwrap(HomebrewLoader.parse(sampleFormula))
        XCTAssertEqual(f.name, "hello_tool")
        XCTAssertEqual(f.package.desc, "A demonstration tool that says hello")
        XCTAssertEqual(f.package.homepage, "https://example.com/hello")
        XCTAssertEqual(f.package.license, "MIT")
    }

    func testParseUrlAndSha256() throws {
        let f = try XCTUnwrap(HomebrewLoader.parse(sampleFormula))
        let asset = try XCTUnwrap(f.versions.first?.assets.first)
        XCTAssertEqual(asset.url, "https://example.com/hello-2.3.4.tar.gz")
        XCTAssertEqual(asset.sha256, "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")
        XCTAssertEqual(asset.os, "macos")
    }

    func testParseVersionDerivedFromUrl() throws {
        let f = try XCTUnwrap(HomebrewLoader.parse(sampleFormula))
        XCTAssertEqual(f.versions.first?.ver, "2.3.4")
    }

    func testParseExplicitVersion() throws {
        let ruby = """
        class Foo < Formula
          desc "test"
          url "https://example.com/foo.tar.gz"
          sha256 "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
          version "9.9.9"
        end
        """
        let f = try XCTUnwrap(HomebrewLoader.parse(ruby))
        XCTAssertEqual(f.versions.first?.ver, "9.9.9")
    }

    func testParseDependencies() throws {
        let f = try XCTUnwrap(HomebrewLoader.parse(sampleFormula))
        let depNames = f.deps.map(\.name)
        XCTAssertTrue(depNames.contains("autoconf"))
        XCTAssertTrue(depNames.contains("pkg-config"))
    }

    func testParseBinInstalls() throws {
        let f = try XCTUnwrap(HomebrewLoader.parse(sampleFormula))
        XCTAssertTrue(f.provides.bin.contains("hello"))
        XCTAssertTrue(f.provides.bin.contains("hello-config"))
    }

    func testSnakeCaseConversion() throws {
        let ruby = """
        class CamelCaseTool < Formula
          desc "test"
          url "https://example.com/x.tar.gz"
          sha256 "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
        end
        """
        let f = try XCTUnwrap(HomebrewLoader.parse(ruby))
        XCTAssertEqual(f.name, "camel_case_tool")
    }

    func testReturnsNilForInvalidRuby() {
        XCTAssertNil(HomebrewLoader.parse("not a formula"))
        XCTAssertNil(HomebrewLoader.parse(""))
    }

    func testReturnsNilForMissingSha256() {
        let ruby = """
        class Foo < Formula
          url "https://example.com/foo.tar.gz"
        end
        """
        XCTAssertNil(HomebrewLoader.parse(ruby))
    }

    func testLoadTapDirectory() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Write two formula files.
        try sampleFormula.write(to: tmp.appendingPathComponent("hello_tool.rb"), atomically: true, encoding: .utf8)
        let formula2 = """
        class BarBaz < Formula
          desc "another tool"
          url "https://example.com/bar-1.0.tar.gz"
          sha256 "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        end
        """
        try formula2.write(to: tmp.appendingPathComponent("bar_baz.rb"), atomically: true, encoding: .utf8)

        let formulae = HomebrewLoader.loadTap(at: tmp)
        XCTAssertEqual(formulae.count, 2)
        let names = Set(formulae.map(\.name))
        XCTAssertTrue(names.contains("hello_tool"))
        XCTAssertTrue(names.contains("bar_baz"))
    }

    func testParseRealWorldRipgrepFormula() throws {
        // A simplified version of the real homebrew ripgrep formula.
        let ruby = """
        class Ripgrep < Formula
          desc "Search tool like grep and The Silver Searcher"
          homepage "https://github.com/BurntSushi/ripgrep"
          license "MIT OR Unlicense"

          stable do
            url "https://github.com/BurntSushi/ripgrep/archive/refs/tags/14.1.1.tar.gz"
            sha256 "8c3c1c92f5e4ded8e67f95d67948b4d5068c9232478e2e1c4b396735d1f506e1"
          end

          depends_on "rust" => :build

          def install
            system "cargo", "install", *std_cargo_args
            bin.install "rg"
          end
        end
        """
        let f = try XCTUnwrap(HomebrewLoader.parse(ruby))
        XCTAssertEqual(f.name, "ripgrep")
        XCTAssertEqual(f.package.desc, "Search tool like grep and The Silver Searcher")
        XCTAssertEqual(f.package.homepage, "https://github.com/BurntSushi/ripgrep")
        let asset = try XCTUnwrap(f.versions.first?.assets.first)
        XCTAssertTrue(asset.url.contains("ripgrep"))
        XCTAssertEqual(f.versions.first?.ver, "14.1.1")
        XCTAssertTrue(f.deps.contains(where: { $0.name == "rust" }))
        XCTAssertTrue(f.provides.bin.contains("rg"))
    }
}
