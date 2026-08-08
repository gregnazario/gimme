import SwiftUI
import GimmeCore

struct InstalledView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var filter: ManagerID?
    @State private var selected: InstalledPackage?

    var filtered: [InstalledPackage] {
        filter.map { f in store.installed.filter { $0.manager == f } } ?? store.installed
    }

    var body: some View {
        VStack {
            HStack {
                ForEach(ManagerID.allCases, id: \.self) { m in
                    ManagerFilterChip(manager: m, isSelected: filter == m) { filter = (filter == m) ? nil : m }
                }
                Spacer()
                Button("Refresh") { Task { await store.loadAll() } }
            }
            .padding(.horizontal)

            List(filtered) { pkg in
                HStack {
                    ManagerBadge(manager: pkg.manager)
                    Text(pkg.name).fontWeight(.medium)
                    Text(pkg.version).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = pkg }
            }
        }
        .navigationTitle("Installed")
        .sheet(item: $selected) { pkg in DetailSheet(package: .installed(pkg)) }
        .task { await store.loadAll() }
    }
}
