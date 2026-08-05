import Foundation
import CGimmeLuaSupport

/// A sandboxed Lua host that exposes a controlled `ctx` API to formulae.
///
/// Blocked by construction (nil'd out after openlibs):
///   - `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.tmpname`, `os.setlocale`
///   - `io.popen`, `io.open`, `io.write`, `io.read`, `io.lines`, `io.close`, `io.tmpfile`
///   - `loadfile`, `dofile`, `load`, `require`, `debug`
///
/// Allowed: `string`, `table`, `math`, basic `os` (clock/time/date/getenv).
/// The `ctx` userdata exposes: download(), extract(path), install_dir(path),
/// mkdir(path), set_provides(list), dep_path(name), host().
public final class Sandbox {
    public struct Config {
        public var workDir: URL
        public var prefix: URL
        public var assetPath: URL
        public var depPaths: [String: URL]
        public var host: Host
        public init(workDir: URL, prefix: URL, assetPath: URL, depPaths: [String: URL], host: Host) {
            self.workDir = workDir; self.prefix = prefix
            self.assetPath = assetPath; self.depPaths = depPaths; self.host = host
        }
    }

    public let config: Config
    fileprivate var provides: [String] = []

    public init(config: Config) {
        self.config = config
        Sandbox.registerDispatchOnce()
    }

    /// Run the `install(ctx)` function defined in the Lua script. Returns the
    /// bin names the formula declared via `ctx:set_provides`.
    public func runInstall(at scriptURL: URL) throws -> [String] {
        guard let L = gimme_lua_newstate() else {
            throw GimmeError.install("could not create lua state")
        }
        defer { gimme_lua_close(L) }

        gimme_luaL_openlibs_sandboxed(L)
        gimme_lua_register_ctx(L, Unmanaged.passUnretained(self).toOpaque())

        let loadRC = scriptURL.path.withCString { gimme_luaL_dofile(L, $0) }
        if loadRC != 0 {
            throw GimmeError.install("lua load error: \(errorMessage(L))")
        }

        "install".withCString { gimme_lua_getglobal(L, $0) }
        guard gimme_lua_isfunction(L, -1) != 0 else {
            throw GimmeError.install("formula script must define `install(ctx)`")
        }
        gimme_lua_push_ctx(L)

        let callRC = gimme_lua_pcall(L, 1, 0, 0)
        if callRC != 0 {
            throw GimmeError.install("lua runtime error: \(errorMessage(L))")
        }
        return provides
    }

    private func errorMessage(_ L: OpaquePointer) -> String {
        guard let cstr = gimme_lua_tostring(L, -1) else { return "unknown" }
        return String(cString: cstr)
    }

    // MARK: - ctx method implementations (called via the dispatch table)

    fileprivate func ctxDownload() -> String { config.assetPath.path }

    fileprivate func ctxExtract(_ archivePath: String) throws -> String {
        let extractDir = config.workDir.appendingPathComponent("extracted")
        // SECURITY: use SafeExtractor which rejects traversal members and strips
        // escaping symlinks, so a malicious asset can't write outside the work dir.
        try SafeExtractor.extract(archive: URL(fileURLWithPath: archivePath), into: extractDir)
        return extractDir.path
    }

    fileprivate func ctxInstallDir(_ srcDir: String) throws {
        let src = URL(fileURLWithPath: srcDir)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        try fm.createDirectory(at: config.prefix, withIntermediateDirectories: true)
        if let entries = try? fm.contentsOfDirectory(atPath: src.path) {
            for entry in entries {
                // SECURITY: reject entry names that could traverse out of the
                // prefix (e.g. a tarball member named "..", "../../.ssh/...").
                guard PathContainment.isSafeComponent(entry) else {
                    throw GimmeError.install("refusing unsafe path component in install_dir: \(entry)")
                }
                let from = src.appendingPathComponent(entry)
                let to = config.prefix.appendingPathComponent(entry)
                guard PathContainment.isContained(to, under: config.prefix) else {
                    throw GimmeError.install("install_dir destination escapes prefix: \(entry)")
                }
                if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
                try fm.moveItem(at: from, to: to)
            }
        }
    }

    fileprivate func ctxMkdir(_ rel: String) throws {
        let resolved = resolvePath(rel)
        // SECURITY: mkdir must stay within the cellar prefix.
        guard PathContainment.isContained(resolved, under: config.prefix) else {
            throw GimmeError.install("mkdir destination escapes the prefix: \(rel)")
        }
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
    }

    fileprivate func ctxSetProvides(_ bins: [String]) { self.provides = bins }

    fileprivate func ctxDepPath(_ name: String) -> String? { config.depPaths[name]?.path }

    fileprivate func ctxHost() -> [String: String] {
        ["os": config.host.os, "arch": config.host.arch, "macos_version": config.host.macosVersion]
    }

    /// Resolve a formula-supplied path. `${prefix}` expands to the cellar
    /// prefix; relative paths resolve under the work dir. The result is
    /// validated to stay within the prefix or work dir — absolute paths and
    /// `..` traversal that escape both are rejected by the caller.
    fileprivate func resolvePath(_ rel: String) -> URL {
        let s = rel.replacingOccurrences(of: "${prefix}", with: config.prefix.path)
        return s.hasPrefix("/") ? URL(fileURLWithPath: s) : config.workDir.appendingPathComponent(s)
    }

    // MARK: - dispatch table registration (once per process)

    private static var dispatchRegistered = false
    private static func registerDispatchOnce() {
        guard !dispatchRegistered else { return }
        var table = gimme_swift_dispatch()
        table.download    = { sb in sandbox(from: sb).map { UnsafePointer(strdup($0.ctxDownload())) } }
        table.extract     = { sb, path in
            guard let box = sandbox(from: sb), let path = path else { return nil }
            return (try? box.ctxExtract(String(cString: path))).map { UnsafePointer(strdup($0)) }
        }
        table.install_dir = { sb, src in
            guard let box = sandbox(from: sb), let src = src else { return -1 }
            return (try? box.ctxInstallDir(String(cString: src))).map { _ in 0 } ?? -1
        }
        table.mkdir       = { sb, rel in
            guard let box = sandbox(from: sb), let rel = rel else { return -1 }
            return (try? box.ctxMkdir(String(cString: rel))).map { _ in 0 } ?? -1
        }
        table.dep_path    = { sb, name in
            guard let box = sandbox(from: sb), let name = name else { return nil }
            return box.ctxDepPath(String(cString: name)).map { UnsafePointer(strdup($0)) }
        }
        table.host = { sb, osOut, archOut, verOut in
            guard let box = sandbox(from: sb) else { return }
            let h = box.ctxHost()
            if let os = h["os"] { osOut?.pointee = UnsafePointer(strdup(os)) }
            if let arch = h["arch"] { archOut?.pointee = UnsafePointer(strdup(arch)) }
            if let ver = h["macos_version"] { verOut?.pointee = UnsafePointer(strdup(ver)) }
        }
        table.set_provides = { sb, bins, count in
            guard let box = sandbox(from: sb) else { return }
            var names: [String] = []
            if let bins = bins {
                for i in 0..<Int(count) {
                    if let p = bins[i] { names.append(String(cString: p)) }
                }
            }
            box.ctxSetProvides(names)
        }
        var tableCopy = table
        withUnsafePointer(to: &tableCopy) { gimme_lua_set_dispatch($0) }
        dispatchRegistered = true
    }
}

private func sandbox(from raw: UnsafeMutableRawPointer?) -> Sandbox? {
    guard let raw = raw else { return nil }
    return Unmanaged<Sandbox>.fromOpaque(raw).takeUnretainedValue()
}
