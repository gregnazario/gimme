import Foundation

/// A downloadable artifact for a version, gated on host.
public struct Asset: Codable, Equatable {
    public var arch: String?
    public var os: String?
    public var url: String
    public var sha256: String

    public init(arch: String? = nil, os: String? = nil, url: String, sha256: String) {
        self.arch = arch
        self.os = os
        self.url = url
        self.sha256 = sha256
    }

    /// An asset matches a host if all its declared constraints agree.
    /// Unset arch/os mean "any".
    public func matches(_ host: Host) -> Bool {
        if let assetOS = os, assetOS != host.os { return false }
        if let assetArch = arch, assetArch != host.arch { return false }
        return true
    }
}
