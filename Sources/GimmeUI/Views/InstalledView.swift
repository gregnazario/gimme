import SwiftUI
import GimmeCore

struct InstalledView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var filter: ManagerID?
    @State private var searchText = ""
    @State private var selected: InstalledPackage?

    var filtered: [InstalledPackage] {
        var result = filter.map { f in store.installed.filter { $0.manager == f } } ?? store.installed
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter row: manager chips scroll horizontally (14 chips overflow
            // a normal window width), then the search field + refresh.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ManagerID.allCases, id: \.self) { m in
                        ManagerFilterChip(manager: m, isSelected: filter == m) {
                            filter = (filter == m) ? nil : m
                        }
                    }
                }
                .padding(.horizontal)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter installed packages…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: searchText) { _ in }  // live filter via @State
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
                Button { Task { await store.loadAll(refresh: true) } } label: {
                    if store.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.loading)
            }
            .padding(.horizontal)
            .padding(.top, 6)

            // Result count line.
            HStack {
                if !searchText.isEmpty || filter != nil {
                    Text("\(filtered.count) of \(store.installed.count)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(store.installed.count) installed")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 4)

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
        .onAppear {
            // If we were navigated here with a pending manager filter (e.g.
            // from Package Managers → "N packages"), apply it once, then clear
            // it so the user's own filter choices stick afterward.
            if let pending = store.pendingManagerFilter {
                filter = pending
                store.pendingManagerFilter = nil
            }
        }
    }
}
