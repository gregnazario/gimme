import SwiftUI
import GimmeCore

struct ByManagerView: View {
    @EnvironmentObject var store: GimmeStore
    var body: some View {
        List {
            ForEach(ManagerID.allCases, id: \.self) { m in
                Section(m.displayName) {
                    let pkgs = store.installed.filter { $0.manager == m }
                    if pkgs.isEmpty {
                        Text("Nothing installed").foregroundStyle(.secondary)
                    } else {
                        ForEach(pkgs) { Text($0.name) }
                    }
                }
            }
        }
        .navigationTitle("By Manager")
        .task { await store.loadAll() }
    }
}
