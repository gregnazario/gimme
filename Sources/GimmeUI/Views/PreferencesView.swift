import SwiftUI
import GimmeCore

struct PreferencesView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List {
            Section("Priority") {
                ForEach(store.config.priority, id: \.self) { Text($0) }
            }
            Section("Ecosystem consolidation targets") {
                Text("Pick the preferred provider per ecosystem. Used by Consolidate to recommend where duplicates should live.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Ecosystem.allCases.filter { $0.managers.count > 1 }, id: \.self) { eco in
                    Picker(eco.displayName, selection: ecosystemBinding(eco)) {
                        ForEach(eco.managers, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                }
            }
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
            Section("Cache") {
                Text("list TTL: \(store.config.listCacheTTLSeconds)s")
                Text("info TTL: \(store.config.infoCacheTTLSeconds)s")
            }
        }
        .navigationTitle("Preferences")
    }

    /// Picker binding that reads/writes the config's ecosystem preference,
    /// defaulting to the recommended manager when unset.
    private func ecosystemBinding(_ eco: Ecosystem) -> Binding<ManagerID> {
        Binding(
            get: { store.config.ecosystems.recommended(for: eco) },
            set: { newValue in
                store.config.ecosystems.preferences[eco] = newValue
                store.persistConfig()
            }
        )
    }
}
