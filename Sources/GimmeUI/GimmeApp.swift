import SwiftUI
import GimmeCore

/// The gimme macOS app — a native UI for browsing, installing, updating, and
/// managing tools. Links GimmeCore directly (no subprocess/JSON), so state
/// changes are instant.
@main
struct GimmeApp: App {
    @StateObject private var store = GimmeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

/// The central observable state for the gimme UI. Wraps a `World` (the gimme
/// engine) and exposes UI-friendly state + actions.
@MainActor
final class GimmeStore: ObservableObject {
    @Published var installedTools: [InstalledToolInfo] = []
    @Published var availableTools: [AvailableToolInfo] = []
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var installingTool: String? = nil
    @Published var lastInstallError: String? = nil
    @Published var showErrorAlert: Bool = false

    // System tools from other package managers (brew, mise, cargo, etc.)
    @Published var systemTools: [SystemManagers.SystemTool] = []
    @Published var systemManagers: [SystemManagers.Manager] = []

    // Outdated tools (have updates available).
    @Published var outdatedTools: [OutdatedToolInfo] = []
    @Published var isCheckingOutdated: Bool = false

    struct OutdatedToolInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let currentVersion: String
        let latestVersion: String
        let source: String   // "gimme" or "brew"
    }
    @Published var lastError: String?
    @Published var operationLog: [LogEntry] = []

    // Lazy loading for the browse view — don't load 8500 formulae eagerly.
    @Published var browseResults: [AvailableToolInfo] = []
    @Published var browseTotalCount: Int = 0
    @Published var browseHasSearched: Bool = false
    private let browsePageSize = 100
    private var browseOffset: Int = 0
    private var allFormulaeCache: [AvailableToolInfo] = []

    private(set) var _world: World?

    struct InstalledToolInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let activeVersion: String
        let allVersions: [String]
    }

    struct AvailableToolInfo: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let desc: String
        let versions: [String]
        let installed: Bool
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel
        enum LogLevel { case info, success, warning, error }
    }

    /// Initialize the gimme world (creates ~/.gimme if needed).
    func initialize() {
        do {
            _world = try World(prefix: GimmePaths.defaultUserPrefix)
            refresh()
        } catch {
            log("Failed to initialize gimme: \(error.localizedDescription)", level: .error)
        }
    }

    /// Refresh installed tool lists + build the formula cache for lazy browsing.
    func refresh() {
        guard let world = _world else { initialize(); return }
        isLoading = true
        defer { isLoading = false }

        // Installed tools (usually a small list — safe to load eagerly).
        let entries = world.state.loadInstalled()
        let installed = Set(entries.keys)
        installedTools = entries.map { (name, entry) in
            InstalledToolInfo(
                name: name,
                activeVersion: entry.active ?? "—",
                allVersions: entry.installed)
        }.sorted { $0.name < $1.name }

        // Build the formula cache lazily — don't hold the main thread for 8500
        // formulae. We store the lightweight AvailableToolInfo so the browse
        // view can filter + paginate from memory without re-parsing.
        let formulae = world.tapStore.allFormulae()
        allFormulaeCache = formulae.map { formula in
            AvailableToolInfo(
                name: formula.name,
                desc: formula.package.desc ?? "",
                versions: formula.versions.map(\.ver),
                installed: installed.contains(formula.name))
        }.sorted { $0.name < $1.name }
        browseTotalCount = allFormulaeCache.count
        availableTools = Array(allFormulaeCache.prefix(browsePageSize))
        browseResults = availableTools
        browseOffset = browsePageSize
        browseHasSearched = false

        // Scan system package managers for tools installed by brew, mise, etc.
        systemManagers = SystemManagers.detectedManagers()
        let gimmeInstalled = installedTools.map { (name: $0.name, version: $0.activeVersion) }
        systemTools = SystemManagers.scanAllTools(gimmeTools: gimmeInstalled)
    }

    /// Search/filter the formula cache. Resets pagination to show the first page.
    func searchFormulae(_ query: String) {
        browseHasSearched = true
        if query.isEmpty {
            browseTotalCount = allFormulaeCache.count
            browseResults = Array(allFormulaeCache.prefix(browsePageSize))
        } else {
            let q = query.lowercased()
            let filtered = allFormulaeCache.filter {
                $0.name.lowercased().contains(q) ||
                $0.desc.lowercased().contains(q)
            }
            browseTotalCount = filtered.count
            browseResults = Array(filtered.prefix(browsePageSize))
        }
        browseOffset = browsePageSize
    }

    /// Load the next page of results (infinite scroll).
    func loadMoreIfNeeded(currentItem: AvailableToolInfo) {
        // Trigger when the last visible item is shown.
        guard let lastShown = browseResults.last,
              lastShown.id == currentItem.id else { return }
        guard browseOffset < browseTotalCount else { return }

        let source: [AvailableToolInfo]
        if browseHasSearched && !searchText.isEmpty {
            let q = searchText.lowercased()
            source = allFormulaeCache.filter {
                $0.name.lowercased().contains(q) ||
                $0.desc.lowercased().contains(q)
            }
        } else {
            source = allFormulaeCache
        }

        let nextBatch = Array(source[browseOffset..<min(browseOffset + browsePageSize, source.count)])
        browseResults.append(contentsOf: nextBatch)
        browseOffset += browsePageSize
    }

    /// Install a tool by name.
    func install(_ name: String) {
        guard let world = _world else { return }
        installingTool = name
        log("Installing \(name)...", level: .info)
        // Run on a background thread so the UI stays responsive.
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<(String, String), GimmeError>
            do {
                let r = try world.installer.install(query: name)
                result = .success((r.tool, r.version))
            } catch let e as GimmeError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown("Unexpected: \(error)"))
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let (tool, version)):
                    self.log("✓ Installed \(tool) \(version)", level: .success)
                case .failure(let e):
                    self.log("✗ \(e.message)", level: .error)
                    self.lastInstallError = "Failed to install \(name): \(e.message)"
                    self.showErrorAlert = true
                }
                self.installingTool = nil
                self.refresh()
            }
        }
    }

    /// Uninstall a tool by name.
    func uninstall(_ name: String) {
        guard let world = _world else { return }
        installingTool = name
        log("Removing \(name)...", level: .info)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, GimmeError>
            do {
                try world.installer.uninstall(tool: name)
                result = .success(())
            } catch let e as GimmeError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown("Unexpected: \(error)"))
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.log("✓ Removed \(name)", level: .success)
                case .failure(let e):
                    self.log("✗ \(e.message)", level: .error)
                    self.lastInstallError = "Failed to remove \(name): \(e.message)"
                    self.showErrorAlert = true
                }
                self.installingTool = nil
                self.refresh()
            }
        }
    }

    /// Update a tool to latest.
    func update(_ name: String) {
        install(name)
    }

    /// Reinstall a tool (for gimme or brew-managed tools).
    func reinstall(_ name: String) {
        guard let world = _world else { return }
        installingTool = name
        log("Reinstalling \(name)...", level: .info)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, GimmeError>
            // Check if it's a brew-managed install.
            let isBrew = (try? world.cellar.receipt(for: name,
                version: world.state.loadInstalled()[name]?.active ?? ""))?.source == "brew"
            do {
                if isBrew {
                    let delegate = BrewDelegate(paths: world.paths)
                    _ = try delegate.reinstall(tool: name)
                } else {
                    try world.installer.uninstall(tool: name)
                    _ = try world.installer.install(query: name)
                }
                result = .success(())
            } catch let e as GimmeError {
                result = .failure(e)
            } catch {
                result = .failure(.unknown("Unexpected: \(error)"))
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.log("✓ Reinstalled \(name)", level: .success)
                case .failure(let e):
                    self.log("✗ \(e.message)", level: .error)
                    self.lastInstallError = "Failed to reinstall \(name): \(e.message)"
                    self.showErrorAlert = true
                }
                self.installingTool = nil
                self.refresh()
            }
        }
    }

    /// Update all tools (gimme + brew).
    func updateAll() {
        guard let world = _world else { return }
        installingTool = "Updating all..."
        log("Updating all tools...", level: .info)
        DispatchQueue.global(qos: .userInitiated).async {
            // gimme tools.
            let gimmeTools = world.cellar.installedTools()
            for tool in gimmeTools {
                let receipt = world.cellar.receipt(for: tool,
                    version: world.state.loadInstalled()[tool]?.active ?? "")
                if receipt?.source == "brew" { continue }
                _ = try? world.installer.install(query: tool)
            }
            // Brew tools.
            if BrewDelegate.isAvailable {
                let delegate = BrewDelegate(paths: world.paths)
                _ = try? delegate.upgradeAll()
            }
            DispatchQueue.main.async {
                self.log("✓ Update complete", level: .success)
                self.installingTool = nil
                self.refresh()
            }
        }
    }

    /// Check which installed tools have updates available.
    /// Checks gimme tools via livecheck + brew tools via `brew outdated`.
    func checkOutdated() {
        guard let world = _world else { return }
        isCheckingOutdated = true
        log("Checking for updates...", level: .info)

        DispatchQueue.global(qos: .userInitiated).async {
            var outdated: [OutdatedToolInfo] = []

            // gimme tools — use livecheck.
            let installed = world.state.loadInstalled()
            for (name, entry) in installed {
                guard let active = entry.active else { continue }
                let receipt = world.cellar.receipt(for: name, version: active)
                if receipt?.source == "brew" { continue }  // skip brew-managed here

                if let formula = try? world.tapStore.find(name),
                   let latest = try? world.livecheck.latest(for: formula),
                   latest > (GimmeCore.Version(active) ?? GimmeCore.Version("0")!) {
                    outdated.append(OutdatedToolInfo(
                        name: name, currentVersion: active,
                        latestVersion: latest.description, source: "gimme"))
                }
            }

            // Brew tools — use `brew outdated`.
            if BrewDelegate.isAvailable {
                let delegate = BrewDelegate(paths: world.paths)
                if let info = try? delegate.outdated(),
                   let formulae = info["formulae"] as? [[String: Any]] {
                    for f in formulae {
                        guard let name = f["name"] as? String,
                              let installedVersions = f["installed_versions"] as? [String],
                              let currentVer = f["current_version"] as? String else { continue }
                        let installedVer = installedVersions.first ?? "?"
                        outdated.append(OutdatedToolInfo(
                            name: name, currentVersion: installedVer,
                            latestVersion: currentVer, source: "brew"))
                    }
                }
            }

            DispatchQueue.main.async {
                self.outdatedTools = outdated.sorted { $0.name < $1.name }
                if outdated.isEmpty {
                    self.log("✓ All tools up to date", level: .success)
                } else {
                    self.log("\(outdated.count) tool(s) need updating", level: .warning)
                }
                self.isCheckingOutdated = false
            }
        }
    }

    /// Update a single outdated tool.
    func updateOutdated(_ tool: OutdatedToolInfo) {
        if tool.source == "brew" {
            guard let world = _world else { return }
            installingTool = tool.name
            log("Updating \(tool.name) via brew...", level: .info)
            DispatchQueue.global(qos: .userInitiated).async {
                let delegate = BrewDelegate(paths: world.paths)
                do {
                    _ = try delegate.upgrade(tool: tool.name)
                    DispatchQueue.main.async {
                        self.log("✓ Updated \(tool.name) to \(tool.latestVersion)", level: .success)
                        self.installingTool = nil
                        self.checkOutdated()
                        self.refresh()
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.log("✗ Failed: \(error)", level: .error)
                        self.installingTool = nil
                    }
                }
            }
        } else {
            install(tool.name)
        }
    }

    /// Update all outdated tools.
    func updateAllOutdated() {
        for tool in outdatedTools {
            updateOutdated(tool)
        }
    }

    /// Find a tool's binary location on disk.
    func findLocation(_ name: String) -> String? {
        BrewDelegate.findBinary(name)
    }

    /// Get brew info for a tool.
    func brewInfo(_ name: String) -> [String: Any]? {
        guard let world = _world else { return nil }
        let delegate = BrewDelegate(paths: world.paths)
        return try? delegate.info(tool: name)
    }

    /// Switch the active version of a tool.
    func useVersion(_ tool: String, _ version: String) {
        guard let world = _world else { return }
        isLoading = true
        do {
            try world.installer.switchActive(tool: tool, version: version)
            log("✓ Switched \(tool) to \(version)", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ Unexpected error: \(error)", level: .error)
        }
        isLoading = false
    }

    /// Add a tap.
    func addTap(name: String, url: String) {
        guard let world = _world else { return }
        do {
            try world.tapStore.add(name: name, url: url)
            log("✓ Added tap: \(name)", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ \(error)", level: .error)
        }
    }

    /// Remove a tap.
    func removeTap(name: String) {
        guard let world = _world else { return }
        do {
            try world.tapStore.remove(name: name)
            log("✓ Removed tap: \(name)", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ \(error)", level: .error)
        }
    }

    /// Import Homebrew homebrew-core (~6000 formulae). Clones the repo and
    /// adds it as a tap. All formulae become searchable/installable.
    func importHomebrew() {
        guard let world = _world else { return }
        isLoading = true
        log("Importing Homebrew formulae (~6000 tools)...", level: .info)
        do {
            let tapName = "homebrew"
            let dest = world.paths.taps.appendingPathComponent(tapName)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try world.tapStore.add(name: tapName,
                                       url: "https://github.com/Homebrew/homebrew-core.git")
            }
            let formulae = world.tapStore.allFormulae()
            log("✓ Imported \(formulae.count) formulae from Homebrew", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ \(error)", level: .error)
        }
        isLoading = false
    }

    /// Import Homebrew Casks (GUI apps). Clones homebrew-cask and adds it.
    func importCasks() {
        guard let world = _world else { return }
        isLoading = true
        log("Importing Homebrew Casks (GUI apps)...", level: .info)
        do {
            let tapName = "homebrew-cask"
            let dest = world.paths.taps.appendingPathComponent(tapName)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try world.tapStore.add(name: tapName,
                                       url: "https://github.com/Homebrew/homebrew-cask.git")
            }
            // Count casks by scanning the Casks/ dir.
            let casksDir = dest.appendingPathComponent("Casks")
            let caskCount = (try? FileManager.default.contentsOfDirectory(atPath: casksDir.path)
                .filter { $0.hasSuffix(".rb") }.count) ?? 0
            log("✓ Imported \(caskCount) casks from Homebrew Cask", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ \(error)", level: .error)
        }
        isLoading = false
    }

    var hasTaps: Bool {
        _world?.tapStore.list().isEmpty == false
    }

    var tapNames: [String] {
        _world?.tapStore.list() ?? []
    }

    var hasHomebrew: Bool {
        tapNames.contains("homebrew")
    }

    var hasHomebrewCask: Bool {
        tapNames.contains("homebrew-cask")
    }

    /// Available formulae count (from all taps).
    var availableCount: Int {
        _world?.tapStore.allFormulae().count ?? 0
    }

    private func log(_ message: String, level: LogEntry.LogLevel) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        operationLog.insert(entry, at: 0)
        if operationLog.count > 100 { operationLog.removeLast() }
    }
}
