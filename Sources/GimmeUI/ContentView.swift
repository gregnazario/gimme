import SwiftUI
import GimmeCore

/// The main split-view layout: sidebar (installed tools) + detail (browse/operate).
struct ContentView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var selectedSection: SidebarSection = .installed
    @State private var selectedTool: String?

    enum SidebarSection: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case browse = "Browse"
        case taps = "Taps"
        case importSources = "Import"
        case system = "System"
        case log = "Activity"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .installed: return "arrow.down.circle"
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
                case .browse: BrowseToolsView()
                case .taps: TapsView()
            case .importSources: ImportSourcesView()
            case .system: SystemToolsView()
            case .log: ActivityLogView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
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

struct InstalledToolRow: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.InstalledToolInfo
    @State private var showVersionPicker = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(tool.name).font(.headline)
                Text(tool.activeVersion).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.installingTool == tool.name {
                ProgressView()
                    .controlSize(.small)
            } else {
                if tool.allVersions.count > 1 {
                    Menu("Versions") {
                        ForEach(tool.allVersions, id: \.self) { version in
                            Button(version) {
                                store.useVersion(tool.name, version)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                Button(role: .destructive) {
                    store.uninstall(tool.name)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.installingTool != nil)
            }
        }
        .padding(.vertical, 4)
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

    var isInstalling: Bool {
        store.installingTool == tool.name
    }

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
                // Spinner while installing this specific tool.
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if tool.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Install") {
                    store.install(tool.name)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.installingTool != nil)
            }
        }
        .padding(.vertical, 4)
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
                .formStyle(.grouped)
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
