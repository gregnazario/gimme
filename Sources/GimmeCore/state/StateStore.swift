import Foundation

/// One tool's installed-state entry: which versions exist and which is active.
public struct InstalledEntry: Codable, Equatable {
    public var active: String?
    public var installed: [String]
    public init(active: String? = nil, installed: [String] = []) {
        self.active = active; self.installed = installed
    }
}

/// Derived fast-index of installed tools, plus the authoritative pin store.
/// The cellar receipts remain the source of truth; this is a cache that can
/// always be rebuilt via `rebuild(from:)`.
public final class StateStore {
    public let paths: GimmePaths
    /// Optional cellar reference: when set, a missing/corrupt `installed.json`
    /// triggers an automatic rebuild from cellar receipts so the index is never
    /// permanently empty after a crash. Set by `World` after both are constructed.
    public var cellar: Cellar?

    public init(paths: GimmePaths) { self.paths = paths }

    private var installedFile: URL { paths.state.appendingPathComponent("installed.json") }
    private var pinnedFile: URL { paths.state.appendingPathComponent("pinned.json") }

    // MARK: installed.json (derived)

    /// Load installed entries from disk. If the file is missing or corrupt AND a
    /// cellar is attached, rebuild it from receipts so the index self-heals.
    public func loadInstalled() -> [String: InstalledEntry] {
        if let data = try? Data(contentsOf: installedFile),
           let entries = try? JSONDecoder().decode([String: InstalledEntry].self, from: data) {
            return entries
        }
        // Corrupt or missing: rebuild from the cellar if we can.
        if let cellar = cellar {
            let rebuilt = rebuildEntries(from: cellar)
            try? saveInstalled(rebuilt)
            return rebuilt
        }
        return [:]
    }

    /// Build the entries map purely from cellar receipts (no dependency on the
    /// on-disk index). Used by `loadInstalled` self-heal and `rebuild(from:)`.
    private func rebuildEntries(from cellar: Cellar) -> [String: InstalledEntry] {
        var entries: [String: InstalledEntry] = [:]
        for (tool, version, _) in cellar.scanAll() {
            var entry = entries[tool] ?? InstalledEntry()
            if !entry.installed.contains(version) { entry.installed.append(version) }
            entries[tool] = entry
        }
        // Default active = highest installed per tool.
        for (tool, var entry) in entries {
            if entry.active == nil, let highest = entry.installed.sorted(by: {
                (Version($0) ?? Version("0")!) > (Version($1) ?? Version("0")!)
            }).first {
                entry.active = highest
                entries[tool] = entry
            }
        }
        return entries
    }

    public func saveInstalled(_ entries: [String: InstalledEntry]) throws {
        try FileManager.default.createDirectory(
            at: paths.state, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(entries)
        // Atomic write: a crash mid-write must not corrupt the index.
        try data.write(to: installedFile, options: [.atomic])
    }

    /// Mark a version installed. Does not change `active`.
    public func recordInstalled(_ tool: String, version: String) throws {
        var entries = loadInstalled()
        var entry = entries[tool] ?? InstalledEntry()
        if !entry.installed.contains(version) {
            entry.installed.append(version)
            entry.installed.sort { (Version($0) ?? Version("0")!) > (Version($1) ?? Version("0")!) }
        }
        entries[tool] = entry
        try saveInstalled(entries)
    }

    /// Set the active version for a tool (must already be in `installed`).
    public func setActive(_ tool: String, version: String) throws {
        var entries = loadInstalled()
        var entry = entries[tool] ?? InstalledEntry()
        entry.active = version
        entries[tool] = entry
        try saveInstalled(entries)
    }

    /// Remove a version from a tool's entry; if it was active, clear `active`.
    public func removeInstalled(_ tool: String, version: String) throws {
        var entries = loadInstalled()
        guard var entry = entries[tool] else { return }
        entry.installed.removeAll { $0 == version }
        if entry.active == version { entry.active = nil }
        if entry.installed.isEmpty {
            entries.removeValue(forKey: tool)
        } else {
            entries[tool] = entry
        }
        try saveInstalled(entries)
    }

    /// Full rebuild from cellar receipts. Used when the index is missing/corrupt,
    /// or explicitly via `gimme` internals. Persists the rebuilt index.
    public func rebuild(from cellar: Cellar) throws {
        let entries = rebuildEntries(from: cellar)
        try saveInstalled(entries)
    }

    // MARK: pinned.json (authoritative — user intent)

    public func loadPinned() -> [String: String] {
        guard let data = try? Data(contentsOf: pinnedFile),
              let pins = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return pins
    }

    public func pin(_ tool: String, version: String) throws {
        try FileManager.default.createDirectory(
            at: paths.state, withIntermediateDirectories: true)
        var pins = loadPinned()
        pins[tool] = version
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic write: pinned.json is authoritative user intent; a corrupt
        // file silently discards every pin via loadPinned's [:] fallback.
        try enc.encode(pins).write(to: pinnedFile, options: [.atomic])
    }

    public func unpin(_ tool: String) throws {
        var pins = loadPinned()
        pins.removeValue(forKey: tool)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(pins).write(to: pinnedFile, options: [.atomic])
    }
}
