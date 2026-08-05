import Foundation

/// Runs a formula's install strategy in a staging directory and returns the
/// staged dir for the Cellar to commit.
public struct Stager {
    public let paths: GimmePaths
    public let host: Host

    public init(paths: GimmePaths, host: Host) {
        self.paths = paths; self.host = host
    }

    /// Stage a version into a fresh directory under `paths.staging`.
    /// Returns the staged directory (to be atomically committed by Cellar).
    public func run(
        formula: Formula,
        version: Formula.Version,
        assetPath: URL,
        prefix: URL,
        formulaDir: URL? = nil,
        depPaths: [String: URL]
    ) throws -> URL {
        let staging = paths.staging.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let workDir = staging.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        do {
            switch formula.install.strategy {
            case .steps:
                try runSteps(formula.install.steps, assetPath: assetPath,
                             workDir: workDir, prefix: staging)
            case .lua:
                guard let scriptName = formula.install.script else {
                    throw GimmeError.install("strategy=lua but no install.script declared")
                }
                guard let dir = formulaDir else {
                    throw GimmeError.install("strategy=lua requires the formula directory")
                }
                let script = dir.appendingPathComponent(scriptName)
                let cfg = Sandbox.Config(
                    workDir: workDir, prefix: staging, assetPath: assetPath,
                    depPaths: depPaths, host: host)
                let sandbox = Sandbox(config: cfg)
                _ = try sandbox.runInstall(at: script)
            case .source:
                throw GimmeError.install("source builds are not supported in the foundation")
            }
        } catch {
            // Atomicity: clean up staging on any failure.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    /// Execute declarative steps. Variables: ${asset} -> asset path,
    /// ${prefix} -> the staging dir (which becomes the cellar prefix on commit).
    private func runSteps(_ steps: [Formula.Step], assetPath: URL, workDir: URL, prefix: URL) throws {
        var extractedDir: URL? = nil
        for step in steps {
            if let extractRef = step.extract {
                let target = resolveStepPath(extractRef, asset: assetPath,
                                             extracted: extractedDir, prefix: prefix)
                let out = workDir.appendingPathComponent("extracted")
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try SafeExtractor.extract(archive: target, into: out)
                extractedDir = out
            } else if let copy = step.copy {
                let src = resolveStepPath(copy.from, asset: assetPath,
                                          extracted: extractedDir, prefix: prefix)
                // If `to` ends with the prefix or a directory, place the item
                // inside it under its source basename (so `copy pkg -> ${prefix}`
                // yields `${prefix}/pkg`, mirroring `cp -r pkg $prefix`).
                let destBase = resolveStepPath(copy.to, asset: assetPath,
                                               extracted: extractedDir, prefix: prefix)
                let dest: URL
                if destBase.path == prefix.path || FileManager.default.isDirectory(destBase) {
                    dest = destBase.appendingPathComponent(src.lastPathComponent)
                } else {
                    dest = destBase
                }
                // SECURITY: copy destinations must stay within the staging prefix.
                guard PathContainment.isContained(dest, under: prefix) else {
                    throw GimmeError.install("copy destination escapes the staging prefix: \(copy.to)")
                }
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
            }
        }
    }

    private func resolveStepPath(_ s: String, asset: URL, extracted: URL?, prefix: URL) -> URL {
        var p = s
        p = p.replacingOccurrences(of: "${asset}", with: asset.path)
        p = p.replacingOccurrences(of: "${prefix}", with: prefix.path)
        if p.hasPrefix("/") { return URL(fileURLWithPath: p) }
        // Relative to extracted dir if present, else work dir.
        return (extracted ?? prefix).appendingPathComponent(p)
    }
}
