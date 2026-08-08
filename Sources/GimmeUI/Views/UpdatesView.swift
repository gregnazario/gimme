import SwiftUI
import GimmeCore

struct UpdatesView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        VStack {
            HStack {
                Text("\(store.outdated.count) updates available").font(.headline)
                Spacer()
                Button("Update All") { Task { await store.updateAll() } }
                    .disabled(store.outdated.isEmpty)
            }.padding()
            List(store.outdated) { pkg in
                HStack {
                    ManagerBadge(manager: pkg.manager)
                    Text(pkg.name)
                    Text("\(pkg.installedVersion) → \(pkg.latestVersion)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Update") { Task { await store.upgrade(pkg) } }
                }
            }
        }
        .navigationTitle("Updates")
        .task { await store.loadAll() }
    }
}
