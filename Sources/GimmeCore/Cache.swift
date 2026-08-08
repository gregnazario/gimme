import Foundation

/// A TTL disk cache (spec §5.3). JSON files keyed by `manager:operation` under
/// ~/.cache/gimme. Source of truth is always live; the cache only avoids
/// re-querying within its TTL window. Writes invalidate on install/uninstall.
public final class Cache {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Sanitize a cache key into a safe filename component.
    private func file(for key: String) -> URL {
        let safe = key.map { c -> String in
            if c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-" { return String(c) }
            return "_"
        }.joined()
        return directory.appendingPathComponent("\(safe).json")
    }

    /// Test-only accessor for the on-disk file backing a key.
    public func fileForTesting(_ key: String) -> URL? {
        let url = file(for: key)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func get<T: Decodable>(_ key: String, ttlSeconds: Int, as type: T.Type) -> T? {
        let url = file(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // TTL check via modification date.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) > Double(ttlSeconds) {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func set<T: Encodable>(_ key: String, value: T) {
        let url = file(for: key)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func invalidate(_ key: String) {
        let url = file(for: key)
        try? FileManager.default.removeItem(at: url)
    }

    public func invalidatePrefix(_ prefix: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        // Map the prefix through the same sanitizer used for file names.
        let safePrefix = prefix.map { c -> String in
            if c.isLetter || c.isNumber || c == ":" || c == "_" || c == "-" { return String(c) }
            return "_"
        }.joined()
        for name in names where name.hasPrefix(safePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func clear() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
