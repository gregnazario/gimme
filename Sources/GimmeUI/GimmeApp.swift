import SwiftUI
import GimmeCore

@main
struct GimmeApp: App {
    @StateObject private var store = GimmeStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Brand accent — matches the icon gradient's indigo.
    static let accent = Color("#4F46E5")

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Self.accent)
                .frame(minWidth: 760, minHeight: 500)
                // Sheet content does not inherit GimmeStore from this chain
                // position (outside ContentView's .environmentObject) — inject
                // it explicitly or any store access crashes the app (seen in
                // the wild: Report an Issue crashed in onAppear on macOS 26).
                .sheet(isPresented: $store.showReportIssue) {
                    ReportIssueView()
                        .environmentObject(store)
                }
                .sheet(isPresented: $store.showAbout) {
                    AboutGimme(reportIssue: {
                        store.showAbout = false
                        store.showReportIssue = true
                    })
                }
                .alert("Update gimme?", isPresented: Binding(
                    get: { store.pendingUpdate != nil },
                    set: { if !$0 { store.pendingUpdate = nil } }
                )) {
                    Button("Update Now") {
                        if let release = store.pendingUpdate {
                            Task { await store.updateSelf(release) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(store.pendingUpdate.map { "gimme \($0.version) is available (you have \(GimmeVersion.current)). The app downloads, verifies, and relaunches itself." } ?? "")
                }
                .alert(item: $store.updateInfo) { info in
                    Alert(title: Text("gimme"), message: Text(info.text),
                          dismissButton: .default(Text("OK")))
                }
                .alert("Error", isPresented: $store.showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.errorMessage)
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About gimme") { store.showAbout = true }
                Button("Check for Updates…") { Task { await store.checkForUpdates(manual: true) } }
                    .disabled(store.isSelfUpdating)
                Divider()
                Button("Install Command-Line Tool…") { Task { await store.installCLITool() } }
                    .disabled(store.isInstallingCLI)
            }
            CommandGroup(after: .help) {
                Button("Report an Issue…") { store.showReportIssue = true }
            }
            CommandGroup(replacing: .toolbar) {
                Button("Refresh Current Section") { store.refreshCurrentSection() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Find Packages…") { store.focusInstalledFilter() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

/// About modal (app menu → About gimme). Presented as a sheet with the
/// standard close affordance (navigation policy §1).
struct AboutGimme: View {
    @Environment(\.dismiss) private var dismiss
    var reportIssue: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("About gimme").font(.title2).fontWeight(.semibold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding()
            Divider()
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                Text("gimme").font(.title).fontWeight(.bold)
                Text("Version \(GimmeVersion.current)")
                    .foregroundStyle(.secondary)
                Text("One interface for every package manager on your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Homebrew · Go · uv · Cargo · bun · npm · pnpm · Yarn · RubyGems · Composer · Deno · pipx · aqua · ubi · App Store")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let reportIssue {
                    Button("Report an Issue…", action: reportIssue)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(width: 360, height: 460)
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
    @Published var isSearching = false             // true while a search is running
    @Published var isInstalling = false            // true while installing from DetailSheet
    @Published var isUninstalling = false          // true while uninstalling from DetailSheet
    @Published var isRefreshingStatuses = false    // true while Package Managers refresh
    @Published var isConsolidating = false         // true while Consolidate refresh
    @Published var isRefreshingOutdated = false    // true while Updates refresh (beyond updateAll)
    @Published var bootstrapStatus: [ManagerID: String] = [:]  // manager → "bootstrapping…" or empty when done
    @Published var upgradeStatus: [String: UpgradeState] = [:]  // keyed by OutdatedPackage.id
    @Published var preferences: Preferences = .init()
    @Published var config: Config = .defaults
    @Published var managerStatuses: [Gimme.ManagerStatus] = []
    @Published var runtimeManagers: [RuntimeManagerStatus] = []
    @Published var consolidationReport: ConsolidationReport?
    /// Shared sidebar selection (so other views can navigate, e.g. Package
    /// Managers → Installed).
    @Published var sidebarSelection: SidebarSection = .installed
    /// When set, navigating to Installed applies this manager filter first.
    @Published var pendingManagerFilter: ManagerID?
    @Published var showError = false
    @Published var showReportIssue = false
    @Published var showAbout = false

    // MARK: - Self-update (spec: 2026-08-22-self-update-design.md)

    struct InfoAlert: Identifiable {
        let id = UUID()
        let text: String
    }
    /// Set when a newer release exists and the user should confirm updating.
    @Published var pendingUpdate: SelfUpdate.Release?
    /// One-shot informational alert (up-to-date, check failed).
    @Published var updateInfo: InfoAlert?
    @Published var isSelfUpdating = false
    private let selfUpdater = SelfUpdate()

    /// Latest-release check. `manual` (menu item) bypasses the 12 h cache and
    /// reports the result; the background launch check only posts a
    /// notification (when notifications are on).
    func checkForUpdates(manual: Bool) async {
        let key = "meta:selfupdate:latest"
        var release: SelfUpdate.Release?
        if !manual, let cached = gimme.cache.get(key, ttlSeconds: 12 * 3600, as: SelfUpdate.Release.self) {
            release = cached
        } else {
            release = await selfUpdater.latestRelease()
            if let release { gimme.cache.set(key, value: release) }
        }
        guard let release else {
            if manual { updateInfo = InfoAlert(text: "Could not check for updates. See github.com/gregnazario/gimme/releases.") }
            return
        }
        guard SelfUpdate.isNewer(release.version, than: GimmeVersion.current) else {
            if manual { updateInfo = InfoAlert(text: "gimme \(GimmeVersion.current) is up to date.") }
            return
        }
        if manual {
            pendingUpdate = release
        } else if config.notifyUpdates {
            notifier.post(title: "gimme",
                body: "gimme \(release.version) available — gimme menu → Check for Updates…")
        }
    }

    /// Fully automatic in-app update: download + verify the release app,
    /// then a detached swap script replaces the running bundle and relaunches
    /// (pkill first — a running app can't be replaced on APFS cleanly).
    func updateSelf(_ release: SelfUpdate.Release) async {
        guard !isSelfUpdating else { return }
        isSelfUpdating = true
        defer { isSelfUpdating = false }
        log("updating gimme to \(release.version)…")
        do {
            guard let assetURL = release.assets[selfUpdater.appAssetName] else {
                throw GimmeError.install("release \(release.tag) has no \(selfUpdater.appAssetName) asset")
            }
            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("gimme-appupdate-\(UUID().uuidString)")
            let staged = try await selfUpdater.downloadApp(to: stage, expectVersion: release.version,
                                                           assetURL: assetURL,
                                                           sumsURL: release.assets["SHA256SUMS"])
            let target = Bundle.main.bundleURL
            // Paths pass as positional parameters ($1/$2) — never interpolated
            // into the script string, so a path containing quotes can't inject
            // shell commands (audit 2026-08-24).
            let script = #"pkill -x GimmeUI; sleep 1; rm -rf "$1"; cp -R "$2" "$1"; open "$1""#
            Task.detached {
                _ = try? await ProcessRunner().run("/bin/sh",
                    args: ["-c", script, "gimme-update", target.path, staged.path],
                    env: nil, stream: nil)
            }
            // Let the detached script spawn before this process exits.
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        } catch {
            showError(error)
        }
    }
    @Published var errorMessage = ""

    // MARK: - CLI tool install (menu bar → Install Command-Line Tool…)

    @Published var isInstallingCLI = false
    private let cliToolInstaller = CLIToolInstaller()

    /// Install (or update in place) the `gimme` command-line tool from the
    /// latest GitHub release. Fresh installs land in ~/.local/bin — same
    /// location install.sh uses — so both entry points agree.
    func installCLITool() async {
        guard !isInstallingCLI else { return }
        isInstallingCLI = true
        defer { isInstallingCLI = false }
        do {
            let outcome = try await cliToolInstaller.installOrUpdate()
            log(outcome.message)
            var text = "\(outcome.message)."
            if case .installed = outcome {
                text += "\nLocation: \(cliToolInstaller.defaultTarget.path)"
                let dir = cliToolInstaller.defaultTarget.deletingLastPathComponent().path
                if !CLIToolInstaller.isOnPATH(dir) {
                    text += "\nNote: that folder is not on your PATH — add it to your shell profile to run `gimme` in a terminal."
                }
            }
            updateInfo = InfoAlert(text: text)
        } catch {
            showError(error)
        }
    }

    /// Per-package upgrade progress for the Updates view.
    enum UpgradeState: Equatable {
        case pending      // queued
        case upgrading    // in progress
        case done         // succeeded
        case failed(String) // failed with message
    }

    private let gimme: Gimme
    private let notifier = UpdateNotifier()

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
        // Warm Homebrew's search indexes in the background so Browse results
        // gain descriptions/versions shortly after launch. No-op when warm.
        if let brew = g.registryLookup(.homebrew) as? HomebrewManager {
            Task.detached { await brew.warmSearchIndexes() }
        }
    }

    struct ActivityEntry: Identifiable {
        let id = UUID(); let text: String; let time = Date()
    }

    func loadAll(refresh: Bool = false) async {
        loading = true
        defer { loading = false }
        // Stale-while-revalidate on the auto-load path: paint expired cache
        // data instantly, then revalidate in the background. Explicit
        // refreshes (button/⌘R) stay fully blocking.
        let preferStale = !refresh
        let needsRevalidation = preferStale && gimme.hasExpiredListOrOutdatedCache()
        // All four are independent — run concurrently so the user waits for
        // the slowest one, not the sum.
        async let installedResult = gimme.list(from: nil, refresh: refresh, preferStale: preferStale)
        async let outdatedResult = gimme.outdated(from: nil, refresh: refresh, preferStale: preferStale)
        async let statusesResult = gimme.statuses()
        async let runtimesResult = VersionManagerDetector.detect()
        do {
            installed = try await installedResult
            outdated = try await outdatedResult
        } catch { showError(error) }
        managerStatuses = await statusesResult
        runtimeManagers = await runtimesResult
        // Fire-and-forget: post a notification when a newer release exists
        // (12 h-cached; silent when up to date or notifications are off).
        Task { await checkForUpdates(manual: false) }
        if needsRevalidation { Task { await revalidateInstalledAndOutdated() } }
    }

    /// Background pass behind a stale-while-revalidate load. With normal TTL
    /// semantics this is a disk hit (no subprocess, no network) when the fast
    /// pass served fresh data, and a full refetch that republishes when it
    /// served expired data.
    private func revalidateInstalledAndOutdated() async {
        async let installedResult = gimme.list(from: nil, refresh: false)
        async let outdatedResult = gimme.outdated(from: nil, refresh: false)
        if let i = try? await installedResult { installed = i }
        if let o = try? await outdatedResult { outdated = o }
    }

    /// Refresh just the per-manager status (availability + version).
    /// force=true bypasses the statuses TTL cache (Refresh button).
    func loadStatuses(force: Bool = false) async {
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }
        async let statusesResult = gimme.statuses(refresh: force)
        async let runtimesResult = VersionManagerDetector.detect()
        managerStatuses = await statusesResult
        runtimeManagers = await runtimesResult
    }

    /// Build the consolidation report (refresh bypasses cache).
    func loadConsolidationReport(refresh: Bool = false) async {
        isConsolidating = true
        defer { isConsolidating = false }
        do {
            consolidationReport = try await gimme.consolidate(refresh: refresh)
        } catch { showError(error) }
    }

    /// All package names that are part of a duplicate, for the detail-sheet hint.
    var duplicatedPackageIDs: Set<String> {
        guard let report = consolidationReport, report.hasDuplicates else { return [] }
        return Set(report.duplicates.flatMap { $0.installed.map { $0.id } })
    }

    /// Navigate to the Installed tab pre-filtered to one manager.
    func showInstalledFiltered(by manager: ManagerID) {
        pendingManagerFilter = manager
        sidebarSelection = .installed
    }

    /// ⌘R — refresh whatever section is showing.
    func refreshCurrentSection() {
        switch sidebarSelection {
        case .installed, .managers: Task { await loadAll(refresh: true) }
        case .updates:              Task { await refreshOutdated() }
        case .consolidate:          Task { await loadConsolidationReport(refresh: true) }
        case .browse:
            // Re-run only when a real query exists — empty would flood with
            // irrelevant hits (the Search button guards this; ⌘R must too).
            if !lastQuery.isEmpty { Task { await runSearch(lastQuery) } }
        case .preferences, .activity: break
        }
    }

    /// The most recent Browse query (so ⌘R re-runs it after results exist).
    @Published var lastQuery: String = ""

    /// ⌘F — jump to Installed and focus the filter field. The focus trigger
    /// increments AFTER the section switch so InstalledView is mounted and its
    /// onChange actually fires (same-tick increment would be missed).
    func focusInstalledFilter() {
        sidebarSelection = .installed
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)  // let the view mount
            installedFilterFocusTrigger += 1
        }
    }
    /// Incremented each time ⌘F fires; InstalledView focuses its field on change.
    @Published var installedFilterFocusTrigger: Int = 0

    /// Persist the current config (used by the Preferences UI bindings) and
    /// sync it into the engine so changes take effect immediately (no restart).
    func persistConfig() {
        gimme.config = config
        let paths = GimmePaths.defaultUser
        try? config.toTOML().write(to: paths.configFile, atomically: true, encoding: .utf8)
    }

    /// Clear the on-disk cache (forces a refresh everywhere on next query).
    func clearCache() {
        let paths = GimmePaths.defaultUser
        let cache = Cache(directory: paths.cacheDir)
        cache.clear()
    }

    /// Bootstrap (install) a missing backend manager.
    func bootstrap(_ id: ManagerID) async {
        guard let m = gimme.registryLookup(id) else { return }
        bootstrapStatus[id] = "Installing…"
        log("bootstrapping \(id.rawValue)…")
        do {
            try await Bootstrap.run(m, confirm: { _ in true })
            log("bootstrapped \(id.rawValue)")
            bootstrapStatus.removeValue(forKey: id)
            // force: the TTL-cached statuses would still say NOT INSTALLED.
            await loadStatuses(force: true)
        } catch {
            bootstrapStatus.removeValue(forKey: id)
            showError(error)
        }
    }

    func runSearch(_ query: String) async {
        isSearching = true
        defer { isSearching = false }
        lastQuery = query
        do { searchResults = try await gimme.search(query: query, all: searchAll, refresh: false) }
        catch { showError(error) }
    }

    func install(_ hit: SearchHit) async {
        isInstalling = true
        defer { isInstalling = false }
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
            await loadAll(refresh: false)
        } catch { showError(error) }
    }

    func uninstall(_ pkg: InstalledPackage) async {
        isUninstalling = true
        defer { isUninstalling = false }
        log("uninstalling \(pkg.name)")
        do {
            try await gimme.uninstall(name: pkg.name, from: pkg.manager)
            log("uninstalled \(pkg.name)")
            await loadAll(refresh: false)
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
        if config.notifyUpdates { await notifier.requestAuthorizationIfNeeded() }
        upgradeStatus[pkg.id] = .upgrading
        do {
            try await gimme.upgrade(name: pkg.name, from: pkg.manager)
            upgradeStatus[pkg.id] = .done
            log("upgraded \(pkg.name)")
            notifyRunFinished(updated: [(pkg.name, pkg.latestVersion)], failed: [])
            await loadAll(refresh: false)
        } catch {
            upgradeStatus[pkg.id] = .failed("\(error)")
            showError(error)
            notifyRunFinished(updated: [], failed: [(pkg.name, "\(error)")])
        }
    }

    func updateAll() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        if config.notifyUpdates { await notifier.requestAuthorizationIfNeeded() }
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
            notifyRunFinished(
                updated: summary.succeeded.map { id in (id, nil) },
                failed: summary.failed.map { ($0.id, $0.error) })
            await loadAll(refresh: false)
        } catch { showError(error) }
    }

    /// Post the run notification unless the user turned notifications off
    /// (Preferences → Notifications, config.toml `notifyUpdates`).
    private func notifyRunFinished(updated: [(name: String, version: String?)],
                                    failed: [(name: String, error: String)]) {
        guard config.notifyUpdates else { return }
        notifier.runFinished(updated: updated, failed: failed)
    }

    /// Re-query outdated packages across managers (bypasses cache).
    func refreshOutdated() async {
        isRefreshingOutdated = true
        defer { isRefreshingOutdated = false }
        do {
            outdated = try await gimme.outdated(from: nil, refresh: true)
            // Clear stale per-package status for packages no longer outdated.
            let currentIDs = Set(outdated.map { $0.id })
            for id in upgradeStatus.keys where !currentIDs.contains(id) {
                upgradeStatus.removeValue(forKey: id)
            }
        } catch { showError(error) }
    }

    /// True force refresh: bypasses the per-package registry/App Store
    /// response caches too, so every "latest version" is re-asked.
    func forceRefreshOutdated() async {
        isRefreshingOutdated = true
        defer { isRefreshingOutdated = false }
        do {
            outdated = try await gimme.outdated(from: nil, refresh: true, force: true)
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
