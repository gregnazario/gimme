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
        case log = "Activity"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .installed: return "arrow.down.circle"
            case .browse: return "magnifyingglass"
            case .taps: return "shippingbox"
            case .importSources: return "square.and.arrow.down"
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
        }
        .padding(.vertical, 4)
    }
}

/// Browse all available formulae from taps, with install buttons.
struct BrowseToolsView: View {
    @EnvironmentObject var store: GimmeStore

    var filteredTools: [GimmeStore.AvailableToolInfo] {
        if store.searchText.isEmpty {
            return store.availableTools
        }
        return store.availableTools.filter {
            $0.name.localizedCaseInsensitiveContains(store.searchText) ||
            $0.desc.localizedCaseInsensitiveContains(store.searchText)
        }
    }

    var body: some View {
        Group {
            if store.availableTools.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No formulae available").font(.title2)
                    Text("Add a tap to browse installable tools.\nTry: gimme tap add core <git-url>")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredTools) { tool in
                    AvailableToolRow(tool: tool)
                }
            }
        }
        .navigationTitle("Browse")
        .searchable(text: $store.searchText, prompt: "Search tools")
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

struct AvailableToolRow: View {
    @EnvironmentObject var store: GimmeStore
    let tool: GimmeStore.AvailableToolInfo

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
            if tool.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Install") {
                    store.install(tool.name)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.isLoading)
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
