import Foundation

/// Installs Homebrew Cask apps (.app bundles from .dmg or .zip archives).
/// Unlike CLI formulae, cask installs go to `/Applications` (or a configurable
/// `GIMME_APPLICATIONS_DIR`) rather than the cellar — but gimme tracks them
/// via receipts + shims so `gimme list`/`gimme uninstall` still work.
public final class CaskInstaller {
    public let paths: GimmePaths
    public let downloader: Downloader
    public let state: StateStore
    public let lock: Lock

    /// Where to install .app bundles. Default: /Applications.
    public var applicationsDir: URL {
        if let env = ProcessInfo.processInfo.environment["GIMME_APPLICATIONS_DIR"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: "/Applications")
    }

    public init(paths: GimmePaths, downloader: Downloader, state: StateStore, lock: Lock) {
        self.paths = paths; self.downloader = downloader; self.state = state; self.lock = lock
    }

    /// Install a cask: download → verify → extract .app → copy to /Applications.
    public func install(cask: CaskInfo, insecure: Bool = false) throws -> CaskInstallResult {
        try lock.acquire(timeoutSeconds: 30)
        defer { lock.release() }

        // 1. Download + verify (reuse the content-addressed cache).
        let asset = Asset(arch: Host.current.arch, os: "macos", url: cask.url, sha256: cask.sha256)
        let assetPath = try downloader.fetch(asset: asset, insecure: insecure)

        // 2. Extract the .app bundle.
        let staging = paths.staging.appendingPathComponent("cask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let isDMG = cask.url.hasSuffix(".dmg")
        let isZIP = cask.url.hasSuffix(".zip")

        let appBundleName: String
        if isDMG {
            appBundleName = try extractAppFromDMG(at: assetPath, staging: staging, expectedApp: cask.appName)
        } else if isZIP {
            appBundleName = try extractAppFromZIP(at: assetPath, staging: staging, expectedApp: cask.appName)
        } else {
            // Raw binary or unknown format — try unzip as a fallback.
            appBundleName = try extractAppFromZIP(at: assetPath, staging: staging, expectedApp: cask.appName)
        }

        let appSource = staging.appendingPathComponent(appBundleName)
        guard FileManager.default.fileExists(atPath: appSource.path) else {
            try? FileManager.default.removeItem(at: staging)
            throw GimmeError.install("cask \(cask.name): \(appBundleName) not found after extraction")
        }

        // 3. Copy to /Applications (or GIMME_APPLICATIONS_DIR).
        let appDest = applicationsDir.appendingPathComponent(appBundleName)
        if FileManager.default.fileExists(atPath: appDest.path) {
            try FileManager.default.removeItem(at: appDest)
        }
        try FileManager.default.copyItem(at: appSource, to: appDest)
        try? FileManager.default.removeItem(at: staging)

        // 4. Record in the cellar + state (so gimme list/uninstall knows about it).
        let cellarPrefix = paths.cellar.appendingPathComponent(cask.name).appendingPathComponent(cask.version)
        try FileManager.default.createDirectory(at: cellarPrefix, withIntermediateDirectories: true)
        let receipt = Receipt(
            formula: cask.name, tap: "homebrew-cask", version: cask.version,
            installedAt: isoNow(), asset: .init(url: cask.url, sha256: cask.sha256,
                                                arch: Host.current.arch, os: "macos"),
            source: "cask")
        try receipt.write(into: cellarPrefix)
        try state.recordInstalled(cask.name, version: cask.version)
        try state.setActive(cask.name, version: cask.version)

        return CaskInstallResult(name: cask.name, version: cask.version, appPath: appDest.path)
    }

    /// Uninstall a cask app: remove from /Applications + cellar.
    public func uninstall(name: String, version: String? = nil) throws {
        try lock.acquire(timeoutSeconds: 30)
        defer { lock.release() }

        let installed = state.loadInstalled()
        guard let entry = installed[name] else {
            throw GimmeError.notFound("\(name) is not installed")
        }
        let removing = version ?? entry.active ?? entry.installed.first ?? ""
        guard !removing.isEmpty else {
            throw GimmeError.notFound("\(name) has no installed version")
        }

        // Find the receipt to get the .app name.
        let receipt = Cellar(paths: paths).receipt(for: name, version: removing)
        // Remove from /Applications.
        if let receipt = receipt {
            // The .app name isn't stored in the receipt directly; we infer from
            // the cask name. In practice the cask installer should store it.
            // For now, try common patterns: TitleCase, exact name.
            for candidate in candidateAppNames(name, receipt: receipt) {
                let appPath = applicationsDir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: appPath.path) {
                    try FileManager.default.removeItem(at: appPath)
                    break
                }
            }
        }

        // Remove from cellar + state.
        try Cellar(paths: paths).remove(tool: name, version: removing)
        try state.removeInstalled(name, version: removing)
    }

    // MARK: - DMG extraction

    /// Mount a DMG, copy the .app, unmount.
    private func extractAppFromDMG(at dmgPath: URL, staging: URL, expectedApp: String?) throws -> String {
        let mountTask = Process()
        mountTask.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        mountTask.arguments = ["attach", "-nobrowse", "-plist", dmgPath.path]
        let mountOut = Pipe(); mountTask.standardOutput = mountOut
        let mountErr = Pipe(); mountTask.standardError = mountErr
        try mountTask.run(); mountTask.waitUntilExit()
        guard mountTask.terminationStatus == 0 else {
            let err = String(data: mountErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GimmeError.install("DMG mount failed: \(err)")
        }

        // Parse the mount-point from the plist output.
        let plistData = mountOut.fileHandleForReading.readDataToEndOfFile()
        let mountPoint = parseMountPoint(from: plistData) ?? "/Volumes"
        let volumes = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
            .filter { $0.hasSuffix(".app") }

        guard let appName = expectedApp ?? volumes.first else {
            // Unmount before failing.
            unmount(point: mountPoint)
            throw GimmeError.install("no .app found in DMG")
        }

        // Copy the .app to staging.
        let appSrc = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)
        let appDest = staging.appendingPathComponent(appName)
        try FileManager.default.copyItem(at: appSrc, to: appDest)

        // Unmount.
        unmount(point: mountPoint)
        return appName
    }

    /// Extract a .app from a .zip archive.
    private func extractAppFromZIP(at zipPath: URL, staging: URL, expectedApp: String?) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-o", zipPath.path, "-d", staging.path]
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()
        if task.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GimmeError.install("unzip failed: \(err)")
        }

        // Find the .app inside staging.
        let entries = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        let app = entries.first { $0.hasSuffix(".app") }
        guard let appName = expectedApp ?? app else {
            throw GimmeError.install("no .app found in zip")
        }
        return appName
    }

    // MARK: - helpers

    private func parseMountPoint(from plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [[String: Any]],
              let last = plist.last,
              let path = last["mount-point"] as? String else { return nil }
        return path
    }

    private func unmount(point: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", point, "-force"]
        try? task.run(); task.waitUntilExit()
    }

    private func candidateAppNames(_ caskName: String, receipt: Receipt) -> [String] {
        // Convert cask-name to Title Case App Name.app
        let titleCase = caskName.split(separator: "-").map { word -> String in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
        return ["\(titleCase).app", "\(caskName).app"]
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

public struct CaskInstallResult: Equatable {
    public let name: String
    public let version: String
    public let appPath: String
}
