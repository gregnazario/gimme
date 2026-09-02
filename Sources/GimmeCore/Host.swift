import Foundation

/// The host machine gimme is running on. Formulae gate assets on os/arch.
public struct Host: Equatable, Codable, Sendable {
    public let os: String
    public let arch: String
    public let macosVersion: String

    public init(os: String, arch: String, macosVersion: String) {
        self.os = os
        self.arch = arch
        self.macosVersion = macosVersion
    }

    /// Resolved once at startup from compile-time + runtime info.
    public static let current: Host = {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let ver = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        return Host(os: "macos", arch: arch, macosVersion: ver)
    }()
}
