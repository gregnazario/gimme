import Foundation

/// Per-package remembered manager overrides (spec §5.2). Persisted to
/// ~/.config/gimme/preferences.toml, separate from config.toml.
public struct Preferences: Equatable, Sendable {
    /// Map of package name -> chosen manager.
    public private(set) var overrides: [String: ManagerID]

    public init(overrides: [String: ManagerID] = [:]) {
        self.overrides = overrides
    }

    public func remembered(for name: String) -> ManagerID? {
        overrides[name]
    }

    public mutating func remember(_ name: String, _ manager: ManagerID) {
        overrides[name] = manager
    }

    public mutating func forget(_ name: String) {
        overrides.removeValue(forKey: name)
    }

    public mutating func forgetAll() {
        overrides.removeAll()
    }

    public static func load(at path: URL) -> Preferences {
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let root = try? TOML.parseData(data) else {
            return Preferences()
        }
        var overrides: [String: ManagerID] = [:]
        // Stored as an array-of-tables so package names with dots/slashes
        // (e.g. "github.com/spf13/cobra") survive without quoted-key support
        // in the TOML parser:
        //   [[override]]
        //   name = "ripgrep"
        //   manager = "cargo"
        if let arr = root.array("override") {
            for entry in arr {
                guard let table = entry.asTable,
                      let name = table.string("name"),
                      let raw = table.string("manager"),
                      let id = ManagerID(rawValue: raw) else { continue }
                overrides[name] = id
            }
        }
        return Preferences(overrides: overrides)
    }

    public func save(at path: URL) throws {
        var lines: [String] = []
        for (name, id) in overrides.sorted(by: { $0.key < $1.key }) {
            lines.append("[[override]]")
            lines.append("name = \"\(escapeValue(name))\"")
            lines.append("manager = \"\(id.rawValue)\"")
            lines.append("")
        }
        let body = lines.joined(separator: "\n")
        try body.write(to: path, atomically: true, encoding: .utf8)
    }

    /// Escape a TOML basic-string value: backslash and double-quote, strip newlines.
    private func escapeValue(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n", "\r": continue
            default: out.append(ch)
            }
        }
        return out
    }
}
