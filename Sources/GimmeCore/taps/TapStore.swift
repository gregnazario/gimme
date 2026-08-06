import Foundation

/// Manages formula sources ("taps"): the core tap + user-added ones.
/// A tap is a directory under `~/.gimme/taps/<name>/` whose `Formula/`
/// (or root) contains per-tool subdirectories with `formula.toml`.
public struct TapStore: FormulaProvider {
    public let paths: GimmePaths
    public var config: Config

    public init(paths: GimmePaths, config: Config) {
        self.paths = paths; self.config = config
    }

    /// The on-disk directory for a named tap.
    public func tapDir(_ name: String) -> URL {
        paths.taps.appendingPathComponent(name)
    }

    /// All enabled taps' directories (in config-declaration order).
    public func enabledTapDirs() -> [URL] {
        let names = config.taps
            .filter { $0.value.enabled }
            .sorted(by: { $0.key < $1.key })
            .map { $0.key }
        // Always include on-disk taps even if not in config (e.g. local test taps).
        var seen = Set<String>()
        var dirs: [URL] = []
        for n in names {
            let d = tapDir(n)
            if FileManager.default.isDirectory(d) {
                dirs.append(d); seen.insert(n)
            }
        }
        if let onDisk = try? FileManager.default.contentsOfDirectory(atPath: paths.taps.path) {
            for n in onDisk.sorted() where !seen.contains(n) {
                let d = tapDir(n)
                if FileManager.default.isDirectory(d) { dirs.append(d) }
            }
        }
        return dirs
    }

    // MARK: FormulaProvider

    /// Find a formula by name across all enabled taps (first match wins).
    /// Supports both gimme-format taps (formula.toml dirs) and Homebrew-format
    /// taps (.rb files) — the latter are translated on-the-fly via HomebrewLoader.
    public func find(_ name: String) throws -> Formula {
        for dir in enabledTapDirs() {
            // 1. Try gimme format: <tap>/<name>/formula.toml or <tap>/Formula/<name>/formula.toml
            let formulaDir = formulaDir(in: dir, for: name)
            if FileManager.default.isDirectory(formulaDir) {
                let formula = try ManifestLoader.load(directory: formulaDir)
                try ManifestLoader.validate(formula)
                return formula
            }
            // 2. Try Homebrew format: <tap>/Formula/<name>.rb or <tap>/<name>.rb
            if let f = findHomebrewFormula(in: dir, name: name) {
                return f
            }
        }
        throw GimmeError.notFound("no formula named '\(name)' in any tap")
    }

    /// All formulae across all taps (gimme + Homebrew format).
    public func allFormulae() -> [Formula] {
        var out: [Formula] = []
        for dir in enabledTapDirs() {
            // gimme format
            for f in formulaDirs(in: dir) {
                if let fml = try? ManifestLoader.load(directory: f) {
                    out.append(fml)
                }
            }
            // Homebrew format
            out.append(contentsOf: loadHomebrewFormulae(in: dir))
        }
        return out
    }

    // MARK: Homebrew-format support

    /// Look for a Homebrew `.rb` formula file matching `name` in the tap dir.
    /// Checks both `<tap>/Formula/<name>.rb` and `<tap>/<name>.rb`.
    private func findHomebrewFormula(in tapDir: URL, name: String) -> Formula? {
        let candidates = [
            tapDir.appendingPathComponent("Formula").appendingPathComponent("\(name).rb"),
            tapDir.appendingPathComponent("\(name).rb"),
        ]
        for path in candidates {
            guard FileManager.default.fileExists(atPath: path.path),
                  let source = try? String(contentsOf: path, encoding: .utf8),
                  let formula = HomebrewLoader.parse(source) else { continue }
            return formula
        }
        return nil
    }

    /// Load ALL Homebrew `.rb` formulae from a tap directory. Checks `Formula/`
    /// subdir (standard homebrew-core layout) and the tap root.
    private func loadHomebrewFormulae(in tapDir: URL) -> [Formula] {
        var out: [Formula] = []
        let dirs = [
            tapDir.appendingPathComponent("Formula"),  // homebrew-core standard
            tapDir,                                      // flat layout
        ]
        for dir in dirs {
            guard FileManager.default.isDirectory(dir) else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for entry in entries where entry.hasSuffix(".rb") {
                let path = dir.appendingPathComponent(entry)
                guard let source = try? String(contentsOf: path, encoding: .utf8),
                      let formula = HomebrewLoader.parse(source) else { continue }
                out.append(formula)
            }
        }
        return out
    }

    // MARK: tap management

    /// Add a tap by cloning its git URL. For `file://` URLs (tests), clone locally.
    public func add(name: String, url: String) throws {
        // SECURITY: reject tap names that could break filesystem layout or TOML
        // structure, and reject empty URLs.
        try TapStore.validateTapName(name)
        guard !url.isEmpty else {
            throw GimmeError.usage("tap url must not be empty")
        }
        try FileManager.default.createDirectory(at: paths.taps, withIntermediateDirectories: true)
        let dest = tapDir(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw GimmeError.usage("tap '\(name)' already exists at \(dest.path)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["clone", "--depth", "1", url, dest.path]
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GimmeError.network("git clone failed: \(err)")
        }
        // Persist the new tap into config so its URL is recorded across runs.
        var cfg = config
        cfg.taps[name] = TapConfig(url: url, enabled: true)
        try? cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    public func remove(name: String) throws {
        // SECURITY: same charset check as `add` — `remove` builds a path from
        // the name, so an unchecked `../../.ssh` would delete an arbitrary dir.
        try TapStore.validateTapName(name)
        let dest = tapDir(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        var cfg = config
        cfg.taps.removeValue(forKey: name)
        try? cfg.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    /// Reject tap names that could break filesystem layout or TOML structure.
    /// Shared by `add` and `remove` so neither can be abused for path traversal.
    public static func validateTapName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.isEmpty,
              name != ".", name != "..",
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw GimmeError.usage("invalid tap name '\(name)': only letters, digits, '.', '-', '_' allowed")
        }
    }

    public func list() -> [String] {
        return enabledTapDirs().map { $0.lastPathComponent }
    }

    /// Update a tap by running `git pull`. No-op if the dir isn't a git repo.
    public func update(name: String) throws {
        let dest = tapDir(name)
        guard FileManager.default.isDirectory(dest.appendingPathComponent(".git")) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", dest.path, "pull", "--ff-only"]
        try task.run()
        task.waitUntilExit()
    }

    // MARK: layout helpers

    /// The directory holding a tool's formula in a tap. Supports two layouts:
    /// `<tap>/Formula/<name>/` (Homebrew-style) or `<tap>/<name>/` (flat).
    private func formulaDir(in tapDir: URL, for name: String) -> URL {
        let styled = tapDir.appendingPathComponent("Formula").appendingPathComponent(name)
        if FileManager.default.isDirectory(styled) { return styled }
        return tapDir.appendingPathComponent(name)
    }

    private func formulaDirs(in tapDir: URL) -> [URL] {
        let styled = tapDir.appendingPathComponent("Formula")
        let root = FileManager.default.isDirectory(styled) ? styled : tapDir
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return entries
            .filter { FileManager.default.isDirectory(root.appendingPathComponent($0)) }
            .map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(ManifestLoader.filename).path) }
    }
}
