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
    @State private var showDetail = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(tool.name).font(.headline)
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
            }
            .padding(20)

            Divider()

            Form {
                if let receipt = receipt {
                    SwiftUI.Section("Install Info") {
                        LabeledContent("Installed", value: receipt.installedAt)
                        LabeledContent("Source", value: receipt.source)
                        LabeledContent("Tap", value: receipt.tap)
                        LabeledContent("gimme Version", value: receipt.gimmeVersion)
                    }
                    if receipt.source == "brew" {
                        SwiftUI.Section("Installed via Homebrew") {
                            Label("This tool was installed by delegating to `brew install`", systemImage: "mug.fill")
                                .font(.caption)
                            LabeledContent("Binary path", value: "/opt/homebrew/bin/\(tool.name)")
                        }
                    } else {
                        SwiftUI.Section("Download") {
                            LabeledContent("URL", value: receipt.asset.url)
                            if !receipt.asset.sha256.isEmpty {
                                LabeledContent("SHA256") {
                                    Text(receipt.asset.sha256)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                            }
                            if let arch = receipt.asset.arch {
                                LabeledContent("Architecture", value: arch)
                            }
                        }
                    }
                    if !receipt.deps.isEmpty {
                        SwiftUI.Section("Dependencies") {
                            ForEach(receipt.deps, id: \.name) { dep in
                                HStack {
                                    Text(dep.name)
                                    Spacer()
                                    Text(dep.resolved).foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }

                SwiftUI.Section("All Versions") {
                    ForEach(tool.allVersions, id: \.self) { version in
                        HStack {
                            Text(version)
                            if version == tool.activeVersion {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("active").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let formula = formula {
                    SwiftUI.Section("Formula") {
                        if let desc = formula.package.desc {
                            LabeledContent("Description") { Text(desc).textSelection(.enabled) }
                        }
                        if let homepage = formula.package.homepage {
                            LabeledContent("Homepage") {
                                Link(homepage, destination: URL(string: homepage) ?? URL(string: "https://example.com")!)
                            }
                        }
                        if let license = formula.package.license {
                            LabeledContent("License", value: license)
                        }
                    }
                    if !formula.provides.bin.isEmpty {
                        SwiftUI.Section("Provides") {
                            ForEach(formula.provides.bin, id: \.self) { bin in
                                Label(bin, systemImage: "terminal")
                            }
                        }
                    }
                }

                // File system info.
                SwiftUI.Section("File System") {
                    let prefix = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.gimme/cellar/\(tool.name)/\(tool.activeVersion)"
                    LabeledContent("Cellar path") {
                        Text(prefix).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    let shim = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.gimme/bin/\(tool.name)"
                    if FileManager.default.fileExists(atPath: shim) {
                        LabeledContent("Shim") {
                            Text(shim).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

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

            Form {
                SwiftUI.Section("Available Versions") {
                    ForEach(tool.versions, id: \.self) { version in
                        Label(version, systemImage: "tag")
                    }
                    if tool.versions.isEmpty {
                        Text("Version info not available (Homebrew formula)").foregroundStyle(.secondary)
                    }
                }

                if let formula = formula {
                    if let homepage = formula.package.homepage {
                        SwiftUI.Section("Homepage") {
                            Link(homepage, destination: URL(string: homepage) ?? URL(string: "https://example.com")!)
                        }
                    }
                    if let license = formula.package.license {
                        LabeledContent("License", value: license)
                    }
                    if !formula.deps.isEmpty {
                        SwiftUI.Section("Dependencies") {
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
                        SwiftUI.Section("Binaries") {
                            ForEach(formula.provides.bin, id: \.self) { bin in
                                Label(bin, systemImage: "terminal")
                            }
                        }
                    }
                    if let firstAsset = formula.versions.first?.assets.first {
                        SwiftUI.Section("Download") {
                            LabeledContent("URL") {
                                Text(firstAsset.url)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            if !firstAsset.sha256.isEmpty {
                                LabeledContent("SHA256") {
                                    Text(firstAsset.sha256)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                    SwiftUI.Section("Install Strategy") {
                        Label(formula.install.strategy.rawValue, systemImage: "hammer")
                    }
                } else {
                    SwiftUI.Section("Info") {
                        Text("This is a Homebrew formula. gimme will attempt a binary download first, then fall back to `brew install` if needed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if tool.installed {
                    SwiftUI.Section("Status") {
                        Label("Already installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .formStyle(.grouped)

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
