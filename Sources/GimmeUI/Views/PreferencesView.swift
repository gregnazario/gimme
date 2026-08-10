import SwiftUI
import GimmeCore

struct PreferencesView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        List {
            prioritySection
            ecosystemSection
            disabledSection
            overridesSection
            cacheSection
        }
        .navigationTitle("Preferences")
    }

    // MARK: - Priority (reorderable list of managers)

    private var prioritySection: some View {
        Section {
            ForEach(Array(store.config.priority.enumerated()), id: \.element) { idx, idRaw in
                HStack {
                    if let id = ManagerID(rawValue: idRaw) {
                        ManagerBadge(manager: id)
                        Text(id.displayName)
                    } else {
                        Text(idRaw).foregroundStyle(.red)
                    }
                    Spacer()
                    // Reorder controls (macOS has no EditButton on our floor).
                    Button {
                        movePriority(idx, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless).disabled(idx == 0)
                    Button {
                        movePriority(idx, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless).disabled(idx == store.config.priority.count - 1)
                    Button(role: .destructive) {
                        store.config.priority.remove(at: idx)
                        store.persistConfig()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Add a manager to the priority list.
            Menu {
                ForEach(unprioritizedManagers, id: \.self) { id in
                    Button(id.displayName) {
                        store.config.priority.append(id.rawValue)
                        store.persistConfig()
                    }
                }
            } label: {
                Label("Add manager…", systemImage: "plus.circle")
            }
            .disabled(unprioritizedManagers.isEmpty)
        } header: {
            Text("Install priority")
        } footer: {
            Text("When you run `gimme install <name>` without --from, managers are searched in this order. Use the arrows to reorder.")
        }
    }

    private func movePriority(_ index: Int, by delta: Int) {
        let target = index + delta
        guard target >= 0, target < store.config.priority.count else { return }
        store.config.priority.swapAt(index, target)
        store.persistConfig()
    }

    /// Managers not yet in the priority list (available to add).
    private var unprioritizedManagers: [ManagerID] {
        let inList = Set(store.config.priority)
        return ManagerID.allCases.filter { !inList.contains($0.rawValue) }
    }

    // MARK: - Ecosystem consolidation targets

    private var ecosystemSection: some View {
        Section {
            ForEach(Ecosystem.allCases.filter { $0.managers.count > 1 }, id: \.self) { eco in
                Picker(eco.displayName, selection: ecosystemBinding(eco)) {
                    ForEach(eco.managers, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
            }
        } header: {
            Text("Ecosystem consolidation targets")
        } footer: {
            Text("Preferred provider per ecosystem. Used by Consolidate to recommend where duplicates should live. Separate from install priority.")
        }
    }

    // MARK: - Disabled managers (toggles)

    private var disabledSection: some View {
        Section {
            ForEach(ManagerID.allCases, id: \.self) { id in
                Toggle(id.displayName, isOn: disabledBinding(id))
                    .toggleStyle(.switch)
            }
        } header: {
            Text("Enabled managers")
        } footer: {
            Text("Disabled managers are skipped by the resolver and don't appear in search/list.")
        }
    }

    // MARK: - Remembered overrides

    private var overridesSection: some View {
        Section("Remembered overrides") {
            if store.preferences.overrides.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.preferences.overrides.keys.sorted()), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(store.preferences.overrides[name]?.rawValue ?? "")
                        Button("Forget") { store.forget(name) }
                    }
                }
            }
        }
    }

    // MARK: - Cache TTLs

    private var cacheSection: some View {
        Section {
            HStack {
                Text("List / outdated TTL")
                Spacer()
                Picker("", selection: listTTLBinding) {
                    Text("1 min").tag(60)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 hour").tag(3600)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Text("Info / search TTL")
                Spacer()
                Picker("", selection: infoTTLBinding) {
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("1 hour").tag(3600)
                    Text("1 day").tag(86400)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Button("Clear cache now") {
                store.clearCache()
            }
        } header: {
            Text("Cache")
        } footer: {
            Text("How long list/outdated/info results are reused before re-querying managers. Clear to force a refresh everywhere.")
        }
    }

    // MARK: - Bindings

    private func ecosystemBinding(_ eco: Ecosystem) -> Binding<ManagerID> {
        Binding(
            get: { store.config.ecosystems.recommended(for: eco) },
            set: { newValue in
                store.config.ecosystems.preferences[eco] = newValue
                store.persistConfig()
            }
        )
    }

    /// Toggle binding for a manager's enabled state (reads/writes config.disabled).
    private func disabledBinding(_ id: ManagerID) -> Binding<Bool> {
        Binding(
            get: { !store.config.disabled.contains(id.rawValue) },
            set: { isEnabled in
                if isEnabled {
                    store.config.disabled.removeAll { $0 == id.rawValue }
                } else {
                    store.config.disabled.append(id.rawValue)
                }
                store.persistConfig()
            }
        )
    }

    private var listTTLBinding: Binding<Int> {
        Binding(
            get: { store.config.listCacheTTLSeconds },
            set: { store.config.listCacheTTLSeconds = $0; store.persistConfig() }
        )
    }

    private var infoTTLBinding: Binding<Int> {
        Binding(
            get: { store.config.infoCacheTTLSeconds },
            set: { store.config.infoCacheTTLSeconds = $0; store.persistConfig() }
        )
    }
}
