import Foundation

/// Dot-segment numeric version comparison, shared by the App Store adapter
/// (store version vs installed) and self-update (latest release vs running
/// build). Not semver — package-manager and app-store versions are loose.
enum DottedVersion {
    /// True when `installed` is strictly older than `latest`: numeric
    /// dot-segment comparison with zero-padding ("1.0" == "1.0.0");
    /// non-numeric segments fall back to lexical ordering. Never true for
    /// equal values.
    static func isOlder(_ installed: String, than latest: String) -> Bool {
        guard installed != latest else { return false }
        let a = installed.split(separator: ".").map(String.init)
        let b = latest.split(separator: ".").map(String.init)
        for i in 0..<max(a.count, b.count) {
            let sa = i < a.count ? a[i] : "0"
            let sb = i < b.count ? b[i] : "0"
            if let na = Int(sa), let nb = Int(sb) {
                if na != nb { return na < nb }
            } else if sa != sb {
                return sa < sb
            }
        }
        return false
    }
}
