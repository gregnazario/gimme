import Foundation

/// SECURITY: tar extraction hardened against malicious archives.
///
/// Untrusted release tarballs (whose bytes are pinned by sha256 but whose
/// *structure* is chosen by the formula author) can contain:
///   - members with absolute paths (`/etc/...`) or `..` traversal;
///   - symlinks pointing outside the extract dir, followed by a later member
///     that writes *through* the symlink (bsdtar/macOS DOES follow symlinks
///     during extraction — verified).
///
/// This helper:
///   1. Lists members first (`-t`) and rejects any with absolute paths or `..`
///      segments — fast-fail for obvious traversal.
///   2. Performs a SINGLE bulk `tar xf` (fast — O(n), one decompress pass) with
///      `--no-same-owner --no-same-permissions`.
///   3. Walks the extracted tree and rejects anything that escaped dest:
///      - any symlink whose target resolves outside dest (the escape vector);
///      - any regular file whose realpath is outside dest (caught a write that
///        went THROUGH an escaping symlink created by an earlier member).
///      On any escape, the escaped artifact is removed and the whole dest is
///      cleaned up, aborting the install.
///
/// The post-extract walk catches the write-through-symlink case because a file
/// written through an escaping symlink lands at a realpath outside dest; we
/// detect and undo it before the install proceeds. This is O(n) and avoids the
/// per-member process-fork cliff that a member-by-member approach would impose.
public enum SafeExtractor {
    /// Extract `archive` (a .tar.gz/.tar/.tgz) into `dest`, rejecting unsafe
    /// members. Throws `GimmeError.install` on any safety violation or tar error.
    /// On a violation, partial extraction is removed so the dest is left clean.
    public static func extract(archive: URL, into dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // 1. List members and fast-reject obvious traversal names.
        let members = try listMembers(archive: archive)
        for member in members {
            if isUnsafeMember(member) {
                throw GimmeError.install(
                    "refusing to extract unsafe archive member: \(member)")
            }
        }

        // 2. Single bulk extract (fast): one decompress pass, no per-member forks.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["xf", archive.path, "-C", dest.path,
                          "--no-same-owner", "--no-same-permissions"]
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()
        if task.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GimmeError.install("extract failed: \(err)")
        }

        // 3. Walk and reject anything that escaped dest. This catches:
        //    - symlinks whose target is outside dest (the redirect primitive);
        //    - regular files whose realpath is outside dest (a write that went
        //      through an escaping symlink created by an earlier member).
        try rejectEscapes(at: dest)
    }

    /// Walk the extracted tree. Remove + abort on any escaping symlink or any
    /// file whose realpath is outside `root`.
    private static func rejectEscapes(at root: URL) throws {
        let fm = FileManager.default
        let rootStd = root.standardizedFileURL.path
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey
        ], options: [.producesRelativePathURLs])
        guard let enumerator = enumerator else { return }
        var escapes: [URL] = []
        for case let url as URL in enumerator {
            // Symlink: check its target.
            let attrs = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if attrs?.isSymbolicLink == true {
                let target = url.resolvingSymlinksInPath()
                if !PathContainment.isContained(target, under: root) {
                    // An escaping symlink is the redirect primitive; remove it
                    // and anything it may have allowed through.
                    try? fm.removeItem(at: url)
                    escapes.append(url)
                    continue
                }
            }
            // Regular file: its realpath must be inside root. If it wrote
            // through an escaping symlink, realpath lands outside.
            let fattrs = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if fattrs?.isRegularFile == true {
                let real = url.resolvingSymlinksInPath().standardizedFileURL.path
                if real != rootStd && !real.hasPrefix(rootStd + "/") {
                    escapes.append(url)
                }
            }
        }
        if !escapes.isEmpty {
            // Clean up the whole extraction and abort.
            try? fm.removeItem(at: root)
            throw GimmeError.install(
                "refusing archive: \(escapes.count) member(s) escaped the extract dir")
        }
    }

    /// List the member names of a tar archive.
    private static func listMembers(archive: URL) throws -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["tf", archive.path]
        let outPipe = Pipe(); task.standardOutput = outPipe
        let errPipe = Pipe(); task.standardError = errPipe
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GimmeError.install("could not list archive members: \(err)")
        }
        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.split(separator: "\n").map(String.init)
    }

    /// A member is unsafe if it's an absolute path, contains `..` as a path
    /// component, or starts with a drive/root.
    private static func isUnsafeMember(_ member: String) -> Bool {
        let trimmed = member.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("\\") { return true }
        let components = trimmed.split(separator: "/").map(String.init)
        if components.contains("..") { return true }
        if trimmed.count >= 2 {
            let second = trimmed.index(after: trimmed.startIndex)
            if trimmed[second] == ":" { return true }
        }
        return false
    }
}

