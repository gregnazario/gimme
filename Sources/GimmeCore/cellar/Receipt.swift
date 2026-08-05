import Foundation

/// Per-install audit record. The source of truth for what's installed.
public struct Receipt: Codable, Equatable {
    public struct AssetRef: Codable, Equatable {
        public var url: String
        public var sha256: String
        public var arch: String?
        public var os: String?
        public init(url: String, sha256: String, arch: String? = nil, os: String? = nil) {
            self.url = url; self.sha256 = sha256; self.arch = arch; self.os = os
        }
        public init(_ asset: Asset) {
            self.url = asset.url; self.sha256 = asset.sha256
            self.arch = asset.arch; self.os = asset.os
        }
    }

    public struct DepRef: Codable, Equatable {
        public var name: String
        public var version: String
        public var resolved: String
        public init(name: String, version: String, resolved: String) {
            self.name = name; self.version = version; self.resolved = resolved
        }
    }

    public var formula: String
    public var tap: String
    public var version: String
    public var installedAt: String
    public var asset: AssetRef
    public var deps: [DepRef]
    public var gimmeVersion: String
    public var source: String

    public init(
        formula: String, tap: String, version: String, installedAt: String,
        asset: AssetRef, deps: [DepRef] = [], gimmeVersion: String = GimmeCoreVersion.value,
        source: String = "download"
    ) {
        self.formula = formula; self.tap = tap; self.version = version
        self.installedAt = installedAt; self.asset = asset; self.deps = deps
        self.gimmeVersion = gimmeVersion; self.source = source
    }

    public static let filename = "RECEIPT.json"

    /// Write RECEIPT.json into a prefix directory (atomically: a crash mid-write
    /// must not corrupt the receipt, which is the source of truth for installs).
    public func write(into prefix: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: prefix.appendingPathComponent(Self.filename), options: [.atomic])
    }

    /// Read a receipt from a prefix directory. Returns nil if absent.
    public static func read(from prefix: URL) -> Receipt? {
        let file = prefix.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else {
            return nil
        }
        return receipt
    }
}
