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
    @Published var preferences: Preferences = .init()
    @Published var config: Config = .defaults
    @Published var managerStatuses: [Gimme.ManagerStatus] = []
    @Published var showError = false
    @Published var errorMessage = ""

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

    func loadAll() async {
        loading = true
        defer { loading = false }
        do {
            installed = try await gimme.list(from: nil, refresh: false)
            outdated = try await gimme.outdated(from: nil, refresh: false)
        } catch {
            showError(error)
        }
        // Statuses are independent of list/outdated and shouldn't gate the UI.
        managerStatuses = await gimme.statuses()
    }

    /// Refresh just the per-manager status (availability + version).
    func loadStatuses() async {
        managerStatuses = await gimme.statuses()
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
            await loadAll()
        } catch { showError(error) }
    }

    func uninstall(_ pkg: InstalledPackage) async {
        log("uninstalling \(pkg.name)")
        do {
            try await gimme.uninstall(name: pkg.name, from: pkg.manager)
            log("uninstalled \(pkg.name)")
            await loadAll()
        } catch { showError(error) }
    }

    func upgrade(_ pkg: OutdatedPackage) async {
        do {
            try await gimme.upgrade(name: pkg.name, from: pkg.manager)
            log("upgraded \(pkg.name)")
            await loadAll()
        } catch { showError(error) }
    }

    func updateAll() async {
        log("updating all outdated packages")
        do {
            let summary = try await gimme.updateAll()
            summary.succeeded.forEach { log("updated \($0)") }
            summary.failed.forEach { log("FAILED \($0.id): \($0.error)") }
            await loadAll()
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
