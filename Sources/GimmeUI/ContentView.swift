import SwiftUI
import GimmeCore

/// The main split-view layout: sidebar (installed tools) + detail (browse/operate).
struct ContentView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var selectedSection: SidebarSection = .installed
    @State private var selectedTool: String?

    enum SidebarSection: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case outdated = "Updates"
        case browse = "Browse"
        case taps = "Taps"
        case importSources = "Import"
        case system = "System"
        case log = "Activity"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .installed: return "arrow.down.circle"
            case .outdated: return "arrow.triangle.2.circlepath"
            case .browse: return "magnifyingglass"
            case .taps: return "shippingbox"
            case .importSources: return "square.and.arrow.down"
            case .system: return "globe"
            case .log: return "text.alignleft"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar: sections + quick stats.
            List(selection: $selectedSection) {
                SwiftUI.Section("gimme") {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
                SwiftUI.Section("Quick Stats") {
                    LabeledContent("Installed", value: "\(store.installedTools.count)")
                    LabeledContent("Available", value: "\(store.availableTools.count)")
                    LabeledContent("Taps", value: "\(store.tapNames.count)")
                }
            }
            .navigationTitle("gimme")
            .frame(minWidth: 200)
        } detail: {
            // Single detail pane: content depends on selected section.
            // No separate third pane — avoids the empty "Select a tool" issue.
            Group {
                switch selectedSection {
            case .installed: InstalledToolsView()
            case .outdated: OutdatedToolsView()
            case .browse: BrowseToolsView()
                case .taps: TapsView()
            case .importSources: ImportSourcesView()
            case .system: SystemToolsView()
            case .log: ActivityLogView()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: { store.updateAll() }) {
                        Label("Update All", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(store.installingTool != nil)

                    Button(action: { store.refresh() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
        }
        .onAppear { store.initialize() }
        .alert("Installation Failed", isPresented: $store.showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(store.lastInstallError ?? "An unknown error occurred.")
        }
    }
}

/// List of installed tools with uninstall/version-switch actions.
struct InstalledToolsView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        VStack {
            if store.installedTools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No tools installed").font(.title2)
                    Text("Browse available tools to install your first one.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.installedTools) { tool in
                    InstalledToolRow(tool: tool)
                }
            }
        }
        .navigationTitle("Installed")
        .searchable(text: $store.searchText, prompt: "Filter installed tools")
    }
}

/// Shows which tools have updates available, with per-tool and update-all buttons.
struct OutdatedToolsView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        VStack(spacing: 0) {
            // Header bar.
            HStack {
                if store.isCheckingOutdated {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking...").foregroundStyle(.secondary)
                    }
                } else if store.outdatedTools.isEmpty {
                    Label("All up to date", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green).font(.headline)
                } else {
                    Label("\(store.outdatedTools.count) update(s) available", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                }
                Spacer()
                Button("Check for Updates") { store.checkOutdated() }
                    .buttonStyle(.bordered)
                    .disabled(store.isCheckingOutdated)
                if !store.outdatedTools.isEmpty {
                    Button("Update All") { store.updateAllOutdated() }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.installingTool != nil)
                }
            }
            .padding(16)

            Divider()

            if store.outdatedTools.isEmpty && !store.isCheckingOutdated {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 48)).foregroundStyle(.green)
                    Text("Everything is up to date").font(.title3)
                    Text("Click 'Check for Updates' to scan again.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.outdatedTools.isEmpty && store.isCheckingOutdated {
                ProgressView("Scanning for updates...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.outdatedTools) { tool in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(tool.name).font(.headline)
                            HStack(spacing: 6) {
                                Text(tool.currentVersion)
                                    .foregroundStyle(.secondary)
                                    .strikethrough()
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                                Text(tool.latestVersion)
                                    .foregroundStyle(.green)
                                    .font(.body.bold())
                            }
                        }
                        Spacer()
                        // Source badge.
                        Text(tool.source)
                            .font(.caption2.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(tool.source == "brew" ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15), in: Capsule())
                        // Update button.
                        if store.installingTool == tool.name {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Update") { store.updateOutdated(tool) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(store.installingTool != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Updates")
        .onAppear {
            if store.outdatedTools.isEmpty && !store.isCheckingOutdated {
                store.checkOutdated()
            }
        }
    }
}

struct InstalledToolRow: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.InstalledToolInfo
    @State private var showDetail = false

    var isOutdated: Bool {
        store.outdatedTools.contains { $0.name == tool.name }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.headline)
                    if isOutdated {
                        // Update badge.
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        if let info = store.outdatedTools.first(where: { $0.name == tool.name }) {
                            Text("→ \(info.latestVersion)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Text(tool.activeVersion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.installingTool == tool.name {
                ProgressView().controlSize(.small)
            } else {
                if tool.allVersions.count > 1 {
                    Menu("Versions") {
                        ForEach(tool.allVersions, id: \.self) { version in
                            Button(version) { store.useVersion(tool.name, version) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                Button { showDetail = true } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) { store.uninstall(tool.name) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.installingTool != nil)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showDetail) {
            InstalledToolDetail(tool: tool)
                .frame(minWidth: 500, minHeight: 400)
        }
    }
}

/// Browse available formulae — paginated with infinite scroll (max 100 per page).
/// Never tries to render 8500 formulae at once.
struct BrowseToolsView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        VStack(spacing: 0) {
            if store.browseTotalCount == 0 && !store.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No formulae available").font(.title2)
                    Text("Import a tap from the Import tab to browse tools.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.browseResults.isEmpty && !store.searchText.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No results for \"\(store.searchText)\"").font(.title3)
                    Text("Try a different search term.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Count bar.
                HStack {
                    Text("\(store.browseResults.count) of \(store.browseTotalCount) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                // Paginated list with infinite scroll.
                List(store.browseResults) { tool in
                    AvailableToolRow(tool: tool)
                        .onAppear {
                            store.loadMoreIfNeeded(currentItem: tool)
                        }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Browse")
        .searchable(text: $store.searchText, prompt: "Search \(store.browseTotalCount) tools")
        .onChange(of: store.searchText) { newValue in
            store.searchFormulae(newValue)
        }
    }
}

/// Import sources: Homebrew formulae, Casks, and custom taps.
struct ImportSourcesView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var customTapName = ""
    @State private var customTapURL = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Homebrew Formulae
                importCard(
                    title: "Homebrew Formulae",
                    subtitle: "~6,000 CLI tools from the Homebrew library",
                    icon: "terminal",
                    isImported: store.hasHomebrew,
                    importAction: { store.importHomebrew() },
                    description: "Imports the entire Homebrew homebrew-core library. "
                               + "All formulae become searchable and installable via gimme. "
                               + "Ruby formulae are translated on-the-fly."
                )

                // MARK: - Homebrew Casks
                importCard(
                    title: "Homebrew Casks",
                    subtitle: "GUI macOS apps (.app bundles)",
                    icon: "app.badge",
                    isImported: store.hasHomebrewCask,
                    importAction: { store.importCasks() },
                    description: "Imports the Homebrew Cask library — macOS GUI applications "
                               + "like Firefox, VS Code, Slack, etc. Installed to /Applications."
                )

                // MARK: - Custom Tap
                VStack(alignment: .leading, spacing: 12) {
                    Label("Add Custom Tap", systemImage: "plus.circle")
                        .font(.headline)

                    Text("Point gimme at any git repository containing formula.toml or .rb files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Name", text: $customTapName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        TextField("Git URL", text: $customTapURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            store.addTap(name: customTapName, url: customTapURL)
                            customTapName = ""
                            customTapURL = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customTapName.isEmpty || customTapURL.isEmpty || store.isLoading)
                    }

                    if !store.tapNames.isEmpty {
                        Divider()
                        Text("Active Taps").font(.subheadline.bold())
                        ForEach(store.tapNames, id: \.self) { tap in
                            HStack {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.purple)
                                Text(tap)
                                Spacer()
                                Button(role: .destructive) {
                                    store.removeTap(name: tap)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                // MARK: - Stats
                VStack(spacing: 8) {
                    statRow("Available formulae", value: "\(store.availableCount)")
                    statRow("Installed tools", value: "\(store.installedTools.count)")
                    statRow("Active taps", value: "\(store.tapNames.count)")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(24)
        }
        .navigationTitle("Import")
    }

    private func importCard(title: String, subtitle: String, icon: String,
                            isImported: Bool, importAction: @escaping () -> Void,
                            description: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 32)

                VStack(alignment: .leading) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                if isImported {
                    Label("Imported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Button("Import") {
                        importAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(store.isLoading)
                }
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.body.monospaced())
        }
    }
}

/// Shows all tools installed by every package manager on the system.
struct SystemToolsView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var selectedManager: SystemManagers.Manager?

    var body: some View {
        VStack(spacing: 0) {
            // Manager filter bar.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    managerChip(.gimme, label: "All", isSelected: selectedManager == nil) {
                        selectedManager = nil
                    }
                    ForEach(store.systemManagers) { mgr in
                        managerChip(mgr, label: mgr.displayName, isSelected: selectedManager == mgr) {
                            selectedManager = mgr
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // Tools list, filtered by selected manager.
            let filtered = selectedManager == nil
                ? store.systemTools
                : store.systemTools.filter { $0.manager == selectedManager }

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No system tools found").font(.title3)
                    Text("Other package managers will appear here when detected.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    let grouped = Dictionary(grouping: filtered, by: { $0.manager })
                    ForEach(grouped.keys.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { mgr in
                        SwiftUI.Section {
                            ForEach(grouped[mgr] ?? []) { tool in
                                HStack {
                                    Text(tool.name).font(.body)
                                    Spacer()
                                    Text(tool.version)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } header: {
                            Label(mgr.displayName, systemImage: mgr.icon)
                                .font(.headline)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("System")
    }

    private func managerChip(_ mgr: SystemManagers.Manager?, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let mgr {
                    Image(systemName: mgr.icon)
                }
                Text(label)
                Text("\(store.systemTools.filter { mgr == nil || $0.manager == mgr }.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.purple.opacity(0.15) : Color.clear, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.purple : Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .font(.caption)
    }
}

struct AvailableToolRow: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.AvailableToolInfo
    @State private var showDetail = false

    var isInstalling: Bool { store.installingTool == tool.name }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(tool.name).font(.headline)
                Text(tool.desc).font(.caption).foregroundStyle(.secondary)
                if !tool.versions.isEmpty {
                    Text("v\(tool.versions.first ?? "?")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isInstalling {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing...").font(.caption).foregroundStyle(.secondary)
                }
            } else if tool.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.caption)
            } else {
                Button("Install") { store.install(tool.name) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.installingTool != nil)
            }
            Button { showDetail = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showDetail) {
            AvailableToolDetail(tool: tool)
                .frame(minWidth: 500, minHeight: 400)
        }
    }
}

/// Tap management: list, add, remove.
struct TapsView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var newTapName = ""
    @State private var newTapURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Formula Sources (Taps)")
                .font(.title2.bold())

            if store.tapNames.isEmpty {
                Text("No taps configured. Add one to start installing tools.")
                    .foregroundStyle(.secondary)
            } else {
                List(store.tapNames, id: \.self) { tap in
                    HStack {
                        Image(systemName: "shippingbox.fill")
                        Text(tap)
                        Spacer()
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Add Tap").font(.headline)
                HStack {
                    TextField("Name", text: $newTapName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    TextField("Git URL", text: $newTapURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        store.addTap(name: newTapName, url: newTapURL)
                        newTapName = ""
                        newTapURL = ""
                    }
                    .disabled(newTapName.isEmpty || newTapURL.isEmpty)
                }
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Taps")
    }
}

/// Activity log — shows install/uninstall/update operations.
struct ActivityLogView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.operationLog) { entry in
                    HStack(alignment: .top) {
                        Text(entry.timestamp, style: .time)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(colorForLevel(entry.level))
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Activity")
    }

    private func colorForLevel(_ level: GimmeStore.LogEntry.LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Detail view for a selected tool — shows versions, deps, provides.
struct ToolDetailView: View {
    @EnvironmentObject var store: GimmeStore
    let toolName: String
    @State private var formula: Formula?

    var body: some View {
        Group {
            if let formula = formula {
                Form {
                    Section("Package") {
                        LabeledContent("Name", value: formula.name)
                        if let desc = formula.package.desc {
                            LabeledContent("Description", value: desc)
                        }
                        if let homepage = formula.package.homepage {
                            LabeledContent("Homepage", value: homepage)
                        }
                        if let license = formula.package.license {
                            LabeledContent("License", value: license)
                        }
                    }
                    Section("Versions") {
                        ForEach(formula.versions.map(\.ver), id: \.self) { version in
                            Text(version)
                        }
                    }
                    if !formula.deps.isEmpty {
                        Section("Dependencies") {
                            ForEach(formula.deps, id: \.name) { dep in
                                Text("\(dep.name)\(dep.ver.map { " \($0)" } ?? "")")
                            }
                        }
                    }
                    if !formula.provides.bin.isEmpty {
                        Section("Provides") {
                            Text(formula.provides.bin.joined(separator: ", "))
                        }
                    }
                    Section("Install Strategy") {
                        Text(formula.install.strategy.rawValue)
                    }
                }
                
            } else {
                ProgressView()
            }
        }
        .navigationTitle(toolName)
        .onAppear {
            formula = store.world?.tapStore.allFormulae().first { $0.name == toolName }
        }
    }
}

extension GimmeStore {
    var world: World? { _world }
}

// MARK: - Detail Sheets

/// Detail sheet for an installed tool — shows receipt info, install path,
/// all versions, formula metadata (if available from a tap).
struct InstalledToolDetail: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.InstalledToolInfo
    @State private var receipt: Receipt?
    @State private var formula: Formula?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.largeTitle).foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text(tool.name).font(.title.bold())
                    Text("v\(tool.activeVersion)").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                // Action buttons in the header.
                VStack(spacing: 8) {
                    Button("Reinstall") { store.reinstall(tool.name) }
                        .buttonStyle(.bordered)
                        .disabled(store.installingTool != nil)
                    Button("Update") { store.update(tool.name) }
                        .buttonStyle(.bordered)
                        .disabled(store.installingTool != nil)
                    Button(role: .destructive) { store.uninstall(tool.name) } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.installingTool != nil)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailSection("Install Info") {
                        if let receipt = receipt {
                            detailRow("Source", receipt.source)
                            detailRow("Tap", receipt.tap)
                            detailRow("Installed", receipt.installedAt)
                            detailRow("gimme Version", receipt.gimmeVersion)
                            if receipt.source == "brew" {
                                Label("Installed via brew install", systemImage: "mug.fill").font(.caption)
                            }
                        } else {
                            Text("No receipt found").foregroundStyle(.secondary)
                        }
                    }

                    if let receipt = receipt, receipt.source != "brew", !receipt.asset.url.isEmpty {
                        detailSection("Download") {
                            detailRow("URL", receipt.asset.url, selectable: true)
                            if !receipt.asset.sha256.isEmpty {
                                detailRow("SHA256", receipt.asset.sha256, selectable: true)
                            }
                            if let arch = receipt.asset.arch {
                                detailRow("Architecture", arch)
                            }
                        }
                    }

                    if let receipt = receipt, !receipt.deps.isEmpty {
                        detailSection("Dependencies") {
                            ForEach(receipt.deps, id: \.name) { dep in
                                HStack {
                                    Text(dep.name)
                                    Spacer()
                                    Text(dep.resolved).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }

                    detailSection("All Versions") {
                        ForEach(tool.allVersions, id: \.self) { version in
                            HStack {
                                Text(version)
                                if version == tool.activeVersion {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    Text("active").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let formula = formula {
                        detailSection("Formula") {
                            if let desc = formula.package.desc {
                                detailRow("Description", desc, selectable: true)
                            }
                            if let homepage = formula.package.homepage {
                                HStack {
                                    Text("Homepage").foregroundStyle(.secondary)
                                    Spacer()
                                    Link(homepage, destination: URL(string: homepage) ?? URL(string: "https://example.com")!)
                                }
                            }
                            if let license = formula.package.license {
                                detailRow("License", license)
                            }
                        }
                        if !formula.provides.bin.isEmpty {
                            detailSection("Provides") {
                                ForEach(formula.provides.bin, id: \.self) { bin in
                                    Label(bin, systemImage: "terminal")
                                }
                            }
                        }
                    }

                    detailSection("File System") {
                        let cellarPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.gimme/cellar/\(tool.name)/\(tool.activeVersion)"
                        detailRow("Cellar", cellarPath, selectable: true)
                        if let which = store.findLocation(tool.name) {
                            detailRow("which", which, selectable: true)
                        }
                        if receipt?.source == "brew" {
                            ForEach(["/opt/homebrew", "/usr/local"], id: \.self) { brewPrefix in
                                let cp = "\(brewPrefix)/Cellar/\(tool.name)/\(tool.activeVersion)"
                                if FileManager.default.fileExists(atPath: cp) {
                                    detailRow("Brew Cellar", cp, selectable: true)
                                }
                            }
                        }
                    }

                    detailSection("Actions") {
                        HStack(spacing: 12) {
                            Button("Reveal in Finder") {
                                let path = store.findLocation(tool.name) ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.gimme/cellar/\(tool.name)/\(tool.activeVersion)"
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            if store.findLocation(tool.name) != nil {
                                Button("Open in Terminal") {
                                    if let path = store.findLocation(tool.name) {
                                        let task = Process()
                                        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                                        task.arguments = ["-a", "Terminal", path]
                                        try? task.run()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .onAppear {
            receipt = store.world?.cellar.receipt(for: tool.name, version: tool.activeVersion)
            formula = store.world?.tapStore.allFormulae().first { $0.name == tool.name }
        }
    }
}

/// Detail sheet for a browsable tool — shows formula metadata, versions,
/// assets, deps, and install button.
struct AvailableToolDetail: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.AvailableToolInfo
    @State private var formula: Formula?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "shippingbox")
                    .font(.largeTitle).foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text(tool.name).font(.title.bold())
                    if !tool.desc.isEmpty {
                        Text(tool.desc).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !tool.installed {
                    Button("Install") { store.install(tool.name) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.installingTool != nil)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailSection("Available Versions") {
                        ForEach(tool.versions, id: \.self) { version in
                            Label(version, systemImage: "tag")
                        }
                        if tool.versions.isEmpty {
                            Text("Version info not available (Homebrew formula)").foregroundStyle(.secondary)
                        }
                    }

                    if let formula = formula {
                        if let homepage = formula.package.homepage {
                            detailSection("Homepage") {
                                Link(homepage, destination: URL(string: homepage) ?? URL(string: "https://example.com")!)
                            }
                        }
                        if let license = formula.package.license {
                            detailSection("License") { Text(license) }
                        }
                        if !formula.deps.isEmpty {
                            detailSection("Dependencies") {
                                ForEach(formula.deps, id: \.name) { dep in
                                    HStack {
                                        Image(systemName: "link")
                                        Text(dep.name)
                                        if let ver = dep.ver {
                                            Spacer()
                                            Text(ver).foregroundStyle(.secondary).font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                        if !formula.provides.bin.isEmpty {
                            detailSection("Binaries") {
                                ForEach(formula.provides.bin, id: \.self) { bin in
                                    Label(bin, systemImage: "terminal")
                                }
                            }
                        }
                        if let firstAsset = formula.versions.first?.assets.first {
                            detailSection("Download") {
                                detailRow("URL", firstAsset.url, selectable: true)
                                if !firstAsset.sha256.isEmpty {
                                    detailRow("SHA256", firstAsset.sha256, selectable: true)
                                }
                            }
                        }
                        detailSection("Install Strategy") {
                            Label(formula.install.strategy.rawValue, systemImage: "hammer")
                        }
                    } else {
                        detailSection("Info") {
                            Text("This is a Homebrew formula. gimme will attempt a binary download first, then fall back to `brew install` if needed.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    if tool.installed {
                        detailSection("Status") {
                            Label("Already installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .padding(20)
            }
            

            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .onAppear {
            formula = store.world?.tapStore.allFormulae().first { $0.name == tool.name }
        }
    }
}

// MARK: - Reusable detail helpers

/// A titled section within a detail scroll view.
func detailSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.headline)
        VStack(alignment: .leading, spacing: 4) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A key-value row within a detail section.
func detailRow(_ key: String, _ value: String, selectable: Bool = false) -> some View {
    HStack(alignment: .top) {
        Text(key).foregroundStyle(.secondary)
        Spacer()
        if selectable {
            Text(value).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                .multilineTextAlignment(.trailing)
        } else {
            Text(value).lineLimit(3).multilineTextAlignment(.trailing)
        }
    }
}
