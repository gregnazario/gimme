import Foundation
import CryptoKit

/// Self-update against gimme's tag-driven GitHub releases (spec:
/// 2026-08-22-self-update-design.md). Shared by `gimme update --self` and the
/// GUI's Check for Updates — all network/process seams are injected so the
/// whole flow is unit-testable.
public final class SelfUpdate: Sendable {
    public struct Release: Equatable, Codable {
        public let tag: String               // "v2.3.0"
        public let version: String           // "2.3.0"
        public let assets: [String: String]  // asset name → browser_download_url
        /// Release notes (the GitHub release body). Nil when absent — older
        /// releases, or a cache entry written before this field existed.
        public let notes: String?

        public init(tag: String, version: String, assets: [String: String], notes: String? = nil) {
            self.tag = tag
            self.version = version
            self.assets = assets
            self.notes = notes
        }
    }

    private let http: HTTPClient
    private let process: any ProcessRunning
    private let arch: String

    public init(http: HTTPClient = URLSessionHTTPClient(),
                process: any ProcessRunning = ProcessRunner(),
                arch: String? = nil) {
        self.http = http
        self.process = process
        self.arch = arch ?? Self.compileArch
    }

    static var compileArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public var cliAssetName: String { "gimme-darwin-\(arch).tar.gz" }
    public var appAssetName: String { "GimmeUI-darwin-\(arch).tar.gz" }

    // MARK: - Latest release

    private struct GHRelease: Decodable {
        let tag_name: String?
        let body: String?
        let assets: [Asset]?
        struct Asset: Decodable {
            let name: String?
            let browser_download_url: String?
        }
    }

    /// Latest published release, or nil on any failure (launch paths must
    /// never throw on a flaky check).
    public func latestRelease() async -> Release? {
        guard let doc: GHRelease = try? await http.getJSON(
                "https://api.github.com/repos/gregnazario/gimme/releases/latest",
                as: GHRelease.self),
              let tag = doc.tag_name else { return nil }
        var assets: [String: String] = [:]
        for asset in doc.assets ?? [] {
            if let name = asset.name, let url = asset.browser_download_url {
                assets[name] = url
            }
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(tag: tag, version: version, assets: assets, notes: doc.body)
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        DottedVersion.isOlder(current, than: candidate)
    }

    // MARK: - Checksums

    /// When the release publishes a SHA256SUMS asset (CI does since v2.3.2),
    /// downloaded data must match its entry. Releases without one (older)
    /// proceed unverified — fail-open only for those. Throws
    /// `.checksumMismatch` on mismatch, before anything is executed or
    /// replaced (audit 2026-08-24: matching a version string is not
    /// integrity).
    private func verifyChecksum(sumsURL: String?, assetName: String, data: Data) async throws {
        guard let sumsURL else { return }
        let sumsData: Data
        do { sumsData = try await http.get(sumsURL) }
        catch { throw GimmeError.install("could not fetch SHA256SUMS for verification") }
        guard let text = String(data: sumsData, encoding: .utf8) else {
            throw GimmeError.install("SHA256SUMS is not text")
        }
        // Format: "<64 hex>  <asset name>" per line (shasum output).
        let expected = text.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.hasSuffix("  \(assetName)") else { return nil }
                let hex = line.prefix(64)
                return hex.count == 64 ? String(hex) : nil
            }
            .first
        guard let expected else {
            throw GimmeError.install("SHA256SUMS has no entry for \(assetName)")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else {
            throw GimmeError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: - CLI update

    /// Download the CLI tarball for `release`, verify the extracted binary
    /// reports the release version, then atomically replace the binary at
    /// `executable`. Returns the new version. Any failure leaves the current
    /// binary untouched.
    public func updateCLI(at executable: URL, to release: Release,
                          progress: ((String) -> Void)? = nil) async throws -> String {
        let assetName = cliAssetName
        guard let assetURL = release.assets[assetName] else {
            throw GimmeError.install("release \(release.tag) has no \(assetName) asset — re-run the install script")
        }
        let dir = executable.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: dir.path) else {
            throw GimmeError.permission(
                "\(dir.path) is not writable — re-run: curl -fsSL https://raw.githubusercontent.com/gregnazario/gimme/main/install.sh | sh")
        }

        progress?("downloading \(assetName)…")
        let data = try await http.get(assetURL)
        try await verifyChecksum(sumsURL: release.assets["SHA256SUMS"], assetName: assetName, data: data)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("gimme-selfupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let tarPath = work.appendingPathComponent(assetName)
        try data.write(to: tarPath)
        progress?("verifying…")
        let extract = try await process.run("/usr/bin/tar",
            args: ["-xzf", tarPath.path, "-C", work.path], env: nil, stream: nil)
        guard extract.exitCode == 0 else {
            throw GimmeError.install("could not extract \(assetName): \(extract.stderr)")
        }
        let newBinary = work.appendingPathComponent("gimme")
        guard FileManager.default.fileExists(atPath: newBinary.path) else {
            throw GimmeError.install("\(assetName) contained no `gimme` binary")
        }
        let versionCheck = try await process.run(newBinary.path, args: ["--version"], env: nil, stream: nil)
        guard versionCheck.exitCode == 0,
              versionCheck.stdout.contains(release.version) else {
            throw GimmeError.install(
                "downloaded binary failed verification (expected \(release.version), got \"\(versionCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\")")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newBinary.path)
        progress?("replacing \(executable.path)…")
        do {
            _ = try FileManager.default.replaceItemAt(executable, withItemAt: newBinary)
        } catch {
            // replaceItemAt can fail across filesystems; remove+move is the
            // fallback (still leaves the old binary on failure paths).
            try? FileManager.default.removeItem(at: executable)
            try FileManager.default.moveItem(at: newBinary, to: executable)
        }
        return release.version
    }

    // MARK: - App download

    /// Download the GimmeUI tarball, extract it into `dir`, and verify the
    /// bundled app reports `expectVersion`. Returns the extracted .app URL.
    /// `sumsURL` (the release's SHA256SUMS asset, when published) is verified
    /// against the downloaded bytes.
    public func downloadApp(to dir: URL, expectVersion: String,
                            assetURL: String, sumsURL: String? = nil) async throws -> URL {
        let assetName = appAssetName
        let data = try await http.get(assetURL)
        try await verifyChecksum(sumsURL: sumsURL, assetName: assetName, data: data)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tarPath = dir.appendingPathComponent(assetName)
        try data.write(to: tarPath)
        let extract = try await process.run("/usr/bin/tar",
            args: ["-xzf", tarPath.path, "-C", dir.path], env: nil, stream: nil)
        guard extract.exitCode == 0 else {
            throw GimmeError.install("could not extract \(assetName): \(extract.stderr)")
        }
        let app = dir.appendingPathComponent("Gimme.app")
        guard let plistData = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let dict = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String,
              version == expectVersion else {
            throw GimmeError.install("downloaded app failed version verification (expected \(expectVersion))")
        }
        return app
    }
}
