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

    /// Refresh installed + available tool lists from the engine.
    func refresh() {
        guard let world = _world else { initialize(); return }
        isLoading = true
        defer { isLoading = false }

        // Installed tools.
        let entries = world.state.loadInstalled()
        installedTools = entries.map { (name, entry) in
            InstalledToolInfo(
                name: name,
                activeVersion: entry.active ?? "—",
                allVersions: entry.installed)
        }.sorted { $0.name < $1.name }

        // Available tools (from all taps).
        let installed = Set(entries.keys)
        availableTools = world.tapStore.allFormulae().map { formula in
            AvailableToolInfo(
                name: formula.name,
                desc: formula.package.desc ?? "",
                versions: formula.versions.map(\.ver),
                installed: installed.contains(formula.name))
        }.sorted { $0.name < $1.name }
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

    var hasTaps: Bool {
        world?.tapStore.list().isEmpty == false
    }

    var tapNames: [String] {
        world?.tapStore.list() ?? []
    }

    private func log(_ message: String, level: LogEntry.LogLevel) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        operationLog.insert(entry, at: 0)
        if operationLog.count > 100 { operationLog.removeLast() }
    }
}
