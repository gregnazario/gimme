import SwiftUI
import GimmeCore

@main
struct GimmeApp: App {
    @StateObject private var store = GimmeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .alert("Error", isPresented: $store.showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.errorMessage)
                }
        }
    }
}

/// The central UI store. Talks only through Gimme (Registry/Resolver/Cache).
/// All backend operations run on a background Task; results land on @Published
/// main-actor state (spec §8.4).
@MainActor
final class GimmeStore: ObservableObject {
    @Published var installed: [InstalledPackage] = []
    @Published var outdated: [OutdatedPackage] = []
    @Published var searchResults: [SearchHit] = []
    @Published var searchAll = false
    @Published var activity: [ActivityEntry] = []
    @Published var loading = false
    @Published var isUpdating = false              // true while updateAll is running
    @Published var upgradeStatus: [String: UpgradeState] = [:]  // keyed by OutdatedPackage.id
    @Published var preferences: Preferences = .init()
    @Published var config: Config = .defaults
    @Published var managerStatuses: [Gimme.ManagerStatus] = []
    @Published var runtimeManagers: [RuntimeManagerStatus] = []
    @Published var consolidationReport: ConsolidationReport?
    @Published var showError = false
    @Published var errorMessage = ""

    /// Per-package upgrade progress for the Updates view.
    enum UpgradeState: Equatable {
        case pending      // queued
        case upgrading    // in progress
        case done         // succeeded
        case failed(String) // failed with message
    }

    private let gimme: Gimme

    init() {
        let paths = GimmePaths.defaultUser
        try? paths.ensureDirectories()
        let g = Gimme(
            registry: Gimme.defaultRegistry(),
            preferences: Preferences.load(at: paths.preferencesFile),
            config: Config.loadOrCreate(at: paths.configFile),
            cache: Cache(directory: paths.cacheDir),
            preferencesFile: paths.preferencesFile
        )
        self.gimme = g
        self.preferences = g.preferences
        self.config = g.config
    }

    struct ActivityEntry: Identifiable {
        let id = UUID(); let text: String; let time = Date()
    }

    func loadAll(refresh: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            installed = try await gimme.list(from: nil, refresh: refresh)
            outdated = try await gimme.outdated(from: nil, refresh: refresh)
        } catch {
            showError(error)
        }
        // Statuses are independent of list/outdated and shouldn't gate the UI.
        managerStatuses = await gimme.statuses()
        runtimeManagers = await VersionManagerDetector.detect()
    }

    /// Refresh just the per-manager status (availability + version).
    func loadStatuses() async {
        managerStatuses = await gimme.statuses()
        runtimeManagers = await VersionManagerDetector.detect()
    }

    /// Build the consolidation report (refresh bypasses cache).
    func loadConsolidationReport(refresh: Bool = false) async {
        do {
            consolidationReport = try await gimme.consolidate(refresh: refresh)
        } catch { showError(error) }
    }

    /// All package names that are part of a duplicate, for the detail-sheet hint.
    var duplicatedPackageIDs: Set<String> {
        guard let report = consolidationReport, report.hasDuplicates else { return [] }
        return Set(report.duplicates.flatMap { $0.installed.map { $0.id } })
    }

    /// Persist the current config (used by the Preferences UI bindings).
    func persistConfig() {
        let paths = GimmePaths.defaultUser
        try? config.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    /// Bootstrap (install) a missing backend manager.
    func bootstrap(_ id: ManagerID) async {
        guard let m = gimme.registryLookup(id) else { return }
        log("bootstrapping \(id.rawValue)…")
        do {
            try await Bootstrap.run(m, confirm: { _ in true })
            log("bootstrapped \(id.rawValue)")
            await loadStatuses()
        } catch {
            showError(error)
        }
    }

    func runSearch(_ query: String) async {
        do { searchResults = try await gimme.search(query: query, all: searchAll, refresh: false) }
        catch { showError(error) }
    }

    func install(_ hit: SearchHit) async {
        log("installing \(hit.name) via \(hit.manager.rawValue)")
        do {
            _ = try await gimme.install(name: hit.name, from: hit.manager, options: InstallOptions(),
                                        confirmBootstrap: { id in
                                            // GUI auto-bootstraps; a future revision could prompt.
                                            self.log("bootstrapping \(id.rawValue)…")
                                            return true
                                        },
                                        onProgress: { line in
                                            Task { @MainActor in self.log("\(hit.manager.rawValue): \(line)") }
                                        })
            log("installed \(hit.name)")
            await loadAll(refresh: true)
        } catch { showError(error) }
    }

    func uninstall(_ pkg: InstalledPackage) async {
        log("uninstalling \(pkg.name)")
        do {
            try await gimme.uninstall(name: pkg.name, from: pkg.manager)
            log("uninstalled \(pkg.name)")
            await loadAll(refresh: true)
        } catch { showError(error) }
    }

    /// Fetch the manager's full info for an installed package (description,
    /// latest version, homepage, license) for the detail sheet.
    func loadInfo(for pkg: InstalledPackage) async -> PackageInfo? {
        do {
            return try await gimme.info(name: pkg.name, from: pkg.manager)
        } catch {
            return nil
        }
    }

    func upgrade(_ pkg: OutdatedPackage) async {
        upgradeStatus[pkg.id] = .upgrading
        do {
            try await gimme.upgrade(name: pkg.name, from: pkg.manager)
            upgradeStatus[pkg.id] = .done
            log("upgraded \(pkg.name)")
            await loadAll(refresh: true)
        } catch {
            upgradeStatus[pkg.id] = .failed("\(error)")
            showError(error)
        }
    }

    func updateAll() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        log("updating all outdated packages")
        // Mark every outdated package as pending so the UI shows the full queue.
        for pkg in outdated { upgradeStatus[pkg.id] = .pending }
        do {
            let summary = try await gimme.updateAll(
                onPackageStart: { [weak self] id in
                    Task { @MainActor in self?.upgradeStatus[id] = .upgrading }
                }
            )
            for id in summary.succeeded {
                upgradeStatus[id] = .done
                log("updated \(id)")
            }
            for failure in summary.failed {
                upgradeStatus[failure.id] = .failed(failure.error)
                log("FAILED \(failure.id): \(failure.error)")
            }
            await loadAll(refresh: true)
        } catch { showError(error) }
    }

    /// Re-query outdated packages across managers (bypasses cache).
    func refreshOutdated() async {
        do {
            outdated = try await gimme.outdated(from: nil, refresh: true)
            // Clear stale per-package status for packages no longer outdated.
            let currentIDs = Set(outdated.map { $0.id })
            for id in upgradeStatus.keys where !currentIDs.contains(id) {
                upgradeStatus.removeValue(forKey: id)
            }
        } catch { showError(error) }
    }

    func forget(_ name: String) {
        do { try gimme.forget(name: name); preferences = gimme.preferences }
        catch { showError(error) }
    }

    private func log(_ text: String) {
        activity.insert(ActivityEntry(text: text), at: 0)
    }

    private func showError(_ error: Error) {
        if let e = error as? GimmeError { errorMessage = e.message }
        else { errorMessage = "\(error)" }
        showError = true
    }
}
