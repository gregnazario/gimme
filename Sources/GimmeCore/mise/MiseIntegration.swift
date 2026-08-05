import Foundation

/// The per-tool outcome of a mise-driven batch install.
public struct MiseToolOutcome: Equatable {
    public enum Status: String, Equatable {
        case installed
        case alreadyCurrent = "already_current"
        case skippedManaged = "skipped_managed"
        case skippedUnsupported = "skipped_unsupported"
        case failed
    }
    public let tool: String
    public let spec: String          // the raw mise spec
    public let status: Status
    public let version: String?      // installed/active version when installed
    public let manager: MiseDetector.Manager?  // when skipped_managed
    public let reason: String?       // human-readable for skips
    public let error: GimmeError?    // when failed

    public init(tool: String, spec: String, status: Status, version: String? = nil,
                manager: MiseDetector.Manager? = nil, reason: String? = nil,
                error: GimmeError? = nil) {
        self.tool = tool; self.spec = spec; self.status = status; self.version = version
        self.manager = manager; self.reason = reason; self.error = error
    }

    public func toJSON() -> [String: Any] {
        var d: [String: Any] = [
            "tool": tool, "spec": spec, "status": status.rawValue
        ]
        if let v = version { d["version"] = v }
        if let m = manager { d["manager"] = m.rawValue }
        if let r = reason { d["reason"] = r }
        if let e = error { d["error"] = e.toJSON()["error"] as Any }
        return d
    }
}

/// The full result of a mise-driven batch install.
public struct MiseInstallResult: Equatable {
    public let source: String?       // ".tool-versions" or "mise.toml"
    public let outcomes: [MiseToolOutcome]

    public init(source: String?, outcomes: [MiseToolOutcome]) {
        self.source = source; self.outcomes = outcomes
    }

    public var ok: Bool {
        // ok = at least one tool installed or already-current.
        outcomes.contains { $0.status == .installed || $0.status == .alreadyCurrent }
    }

    public var anyFailed: Bool {
        outcomes.contains { $0.status == .failed }
    }

    public var summary: (installed: Int, skipped: Int, failed: Int) {
        var inst = 0, skip = 0, fail = 0
        for o in outcomes {
            switch o.status {
            case .installed, .alreadyCurrent: inst += 1
            case .skippedManaged, .skippedUnsupported: skip += 1
            case .failed: fail += 1
            }
        }
        return (inst, skip, fail)
    }

    public func toJSON() -> [String: Any] {
        let s = summary
        return [
            "cmd": "install-from-mise",
            "ok": ok,
            "schema_version": Schema.version,
            "source": source as Any,
            "tools": outcomes.map { $0.toJSON() },
            "summary": [
                "installed": s.installed,
                "skipped": s.skipped,
                "failed": s.failed
            ]
        ]
    }
}

/// Orchestrates a mise-driven batch install: read config from `cwd`, filter
/// (skip mise/asdf-managed + unsupported specs), install the rest via the
/// existing Installer.
public final class MiseIntegration {
    public let world: World
    public let detector: MiseDetector
    public let cwd: URL

    public init(world: World, detector: MiseDetector, cwd: URL) {
        self.world = world; self.detector = detector; self.cwd = cwd
    }

    /// Convenience: build a MiseIntegration for a World using its paths.
    public convenience init(world: World, cwd: URL) {
        let det = MiseDetector(paths: world.paths)
        self.init(world: world, detector: det, cwd: cwd)
    }

    /// Run the batch. Never throws — per-tool failures become `.failed` outcomes.
    public func run(dryRun: Bool) -> MiseInstallResult {
        let (requests, source) = MiseConfig.discover(startingAt: cwd)
        if requests.isEmpty {
            return MiseInstallResult(source: nil, outcomes: [])
        }

        var outcomes: [MiseToolOutcome] = []
        for req in requests {
            outcomes.append(handle(req, dryRun: dryRun))
        }
        return MiseInstallResult(source: source, outcomes: outcomes)
    }

    private func handle(_ req: ToolRequest, dryRun: Bool) -> MiseToolOutcome {
        // 1. Unsupported spec -> skip.
        guard let query = req.spec.toGimmeQuery(tool: req.tool) else {
            return MiseToolOutcome(
                tool: req.tool, spec: req.spec.raw, status: .skippedUnsupported,
                reason: "gimme does not support \(req.spec.raw) specs")
        }

        // 2. Mise/asdf-managed -> skip.
        if let manager = detector.owner(of: req.tool) {
            return MiseToolOutcome(
                tool: req.tool, spec: req.spec.raw, status: .skippedManaged,
                manager: manager,
                reason: "\(req.tool) is managed by \(manager.rawValue)")
        }

        // 3. Install (or plan) via the existing Installer.
        do {
            if dryRun {
                // Dry-run: plan only. We treat a valid plan as already-current-ish
                // for the outcome (no version installed). Use the plan's version.
                let plan = try world.installer.plan(query: query)
                return MiseToolOutcome(
                    tool: req.tool, spec: req.spec.raw, status: .alreadyCurrent,
                    version: plan.version, reason: "planned (dry-run)")
            }
            let result = try world.installer.install(query: query, dryRun: false, insecure: false)
            return MiseToolOutcome(
                tool: req.tool, spec: req.spec.raw, status: .installed, version: result.version)
        } catch let e as GimmeError {
            return MiseToolOutcome(
                tool: req.tool, spec: req.spec.raw, status: .failed, error: e)
        } catch {
            return MiseToolOutcome(
                tool: req.tool, spec: req.spec.raw, status: .failed,
                error: GimmeError.unknown("unexpected: \(error)"))
        }
    }
}
