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
        isLoading = true
        log("Installing \(name)...", level: .info)
        do {
            let result = try world.installer.install(query: name)
            log("✓ Installed \(result.tool) \(result.version)", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ Unexpected error: \(error)", level: .error)
        }
        isLoading = false
    }

    /// Uninstall a tool by name.
    func uninstall(_ name: String) {
        guard let world = _world else { return }
        isLoading = true
        log("Removing \(name)...", level: .info)
        do {
            try world.installer.uninstall(tool: name)
            log("✓ Removed \(name)", level: .success)
            refresh()
        } catch let e as GimmeError {
            log("✗ \(e.message)", level: .error)
        } catch {
            log("✗ Unexpected error: \(error)", level: .error)
        }
        isLoading = false
    }

    /// Update a tool to latest.
    func update(_ name: String) {
        install(name)
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
