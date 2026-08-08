import SwiftUI
import GimmeCore

struct PreferencesView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List {
            Section("Priority") {
                ForEach(store.config.priority, id: \.self) { Text($0) }
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
}
