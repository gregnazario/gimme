import Foundation

/// The shared sudo askpass helper (the Homebrew pattern): when sudo needs a
/// password but has no terminal — GUI launches — it runs this script, which
/// shows the native password dialog via osascript. The password goes to
/// sudo's private pipe and nowhere else: never stored, logged, or captured.
/// sudo prefers the terminal prompt whenever one exists, so injecting
/// SUDO_ASKPASS never changes CLI behavior.
enum SudoAskpass {
    /// Default helper location: ~/.cache/gimme/sudo-askpass.sh.
    static var defaultHelperURL: URL {
        GimmePaths.defaultUser.cacheDir.appendingPathComponent("sudo-askpass.sh")
    }

    /// Writes the helper if needed (0700 from the first byte, no default-
    /// perms window; skipped when content is already current) and returns its
    /// URL, or nil when it can't be written.
    static func installHelper(at url: URL? = nil) -> URL? {
        let url = url ?? defaultHelperURL
        let script = """
        #!/bin/sh
        # Written by gimme. sudo calls this when it needs a password but has no
        # terminal (GUI launches); the password goes to sudo and nowhere else.
        /usr/bin/osascript -e 'display dialog "gimme needs your Mac password to update App Store apps:" default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null

        """
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != script {
                // createFile applies 0700 at creation; setAttributes pins it
                // again in case the file pre-existed with looser modes.
                if !fm.createFile(atPath: url.path, contents: Data(script.utf8),
                                  attributes: [.posixPermissions: 0o700]) {
                    return nil
                }
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            }
            return url
        } catch { return nil }
    }

    /// The augmented process environment plus SUDO_ASKPASS pointing at the
    /// helper (installed on demand). Falls back to the plain augmented
    /// environment if the helper can't be written — callers' sudo simply
    /// behaves as before in that case.
    static func environment(helperURL: URL? = nil) -> [String: String] {
        var env = ProcessRunner.augmentedEnvironment()
        if let helper = installHelper(at: helperURL) {
            env["SUDO_ASKPASS"] = helper.path
        }
        return env
    }
}
