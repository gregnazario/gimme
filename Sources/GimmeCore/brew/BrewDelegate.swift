import Foundation

/// Delegates installs to Homebrew (`brew install`) when gimme can't do a
/// binary install itself (source-only formulae, casks with DMGs, etc.).
/// This makes gimme a native Swift frontend for Homebrew — you get the
/// nice UI + agent contract, and Homebrew handles the actual compilation
/// or DMG extraction under the hood.
///
/// Flow: gimme tries its own binary download first. On failure (404, checksum
/// mismatch for a non-rewritten URL, source-only formula), if `brew` is on
/// PATH, it falls back to `brew install <tool>` and records the result.
public final class BrewDelegate {
    public let paths: GimmePaths

    public init(paths: GimmePaths) { self.paths = paths }

    /// True if Homebrew is installed and on PATH.
    public static var isAvailable: Bool {
        findBrew() != nil
    }

    /// Find the brew binary path.
    private static func findBrew() -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Run `brew install <tool>` (formula or cask). Returns the output.
    public func install(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed. Install from https://brew.sh")
        }
        return try runBrew([brew, "install", tool])
    }

    /// Run `brew install --cask <app>` for GUI apps.
    public func installCask(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed. Install from https://brew.sh")
        }
        return try runBrew([brew, "install", "--cask", tool])
    }

    /// Run `brew uninstall <tool>`.
    public func uninstall(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "uninstall", tool])
    }

    /// Run `brew upgrade <tool>` to update a single tool.
    public func upgrade(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "upgrade", tool])
    }

    /// Run `brew upgrade` (all tools).
    public func upgradeAll() throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "upgrade"])
    }

    /// Run `brew reinstall <tool>`.
    public func reinstall(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "reinstall", tool])
    }

    /// Run `brew outdated --json=v2` — returns the JSON output.
    public func outdated() throws -> [String: Any] {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        let result = try runBrew([brew, "outdated", "--json=v2"])
        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return ["raw": result.stdout]
    }

    /// Run `brew pin <tool>` / `brew unpin <tool>`.
    public func pin(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "pin", tool])
    }

    public func unpin(tool: String) throws -> BrewResult {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        return try runBrew([brew, "unpin", tool])
    }

    /// Find where a tool's binary lives on disk (which/whereis equivalent).
    public static func findBinary(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        let pipe = Pipe(); task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run(); task.waitUntilExit()
            if task.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        } catch {}
        return nil
    }

    /// Run `brew info --json=v2 <tool>` to get info about a formula/cask.
    public func info(tool: String) throws -> [String: Any] {
        guard let brew = BrewDelegate.findBrew() else {
            throw GimmeError.notFound("Homebrew is not installed")
        }
        let result = try runBrew([brew, "info", "--json=v2", tool])
        if let data = result.stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return ["raw": result.stdout]
    }

    private func runBrew(_ arguments: [String]) throws -> BrewResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: arguments[0])
        task.arguments = Array(arguments.dropFirst())
        // Set up the environment so brew can find its dependencies.
        var env = ProcessInfo.processInfo.environment
        if !env.keys.contains("HOMEBREW_PREFIX") {
            if arguments[0].contains("/opt/homebrew") { env["HOMEBREW_PREFIX"] = "/opt/homebrew" }
            else if arguments[0].contains("/usr/local") { env["HOMEBREW_PREFIX"] = "/usr/local" }
        }
        task.environment = env

        let outPipe = Pipe(); task.standardOutput = outPipe
        let errPipe = Pipe(); task.standardError = errPipe

        try task.run()
        task.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return BrewResult(
            exitCode: task.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

public struct BrewResult: Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var success: Bool { exitCode == 0 }

    /// Parse the output for the installed version string (best-effort).
    public var installedVersion: String? {
        // brew install output often contains "=> Pouring foo--1.2.3..." or
        // "foo 1.2.3 is already installed".
        let patterns = [
            #"(?:Pouring|Installing)\s+\S+?--?(\d+\.\d+\.\d+)"#,
            #"already installed.*?(\d+\.\d+\.\d+)"#,
            #"\b(\d+\.\d+\.\d+)\b"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: stdout, range: NSRange(stdout.startIndex..., in: stdout)),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: stdout) {
                return String(stdout[r])
            }
        }
        return nil
    }
}
