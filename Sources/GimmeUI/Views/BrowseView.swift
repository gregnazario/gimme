import SwiftUI
import GimmeCore

struct BrowseView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var query = ""
    @State private var selected: SearchHit?

    var body: some View {
        VStack {
            HStack {
                TextField("Search packages…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.runSearch(query) } }
                Toggle("All managers", isOn: $store.searchAll)
                Button {
                    Task { await store.runSearch(query) }
                } label: {
                    if store.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Search")
                    }
                }
                .disabled(store.isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            if store.isSearching && store.searchResults.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.searchResults.isEmpty {
                Text("Search for packages across managers")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.searchResults) { hit in
                    HStack {
                        ManagerBadge(manager: hit.manager)
                        Text(hit.name).fontWeight(.medium)
                        Text(hit.latestVersion).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = hit }
                }
            }
        }
        .navigationTitle("Browse")
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
