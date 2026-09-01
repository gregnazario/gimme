import SwiftUI
import GimmeCore

struct BrowseView: View {
    @EnvironmentObject var store: GimmeStore
    @State private var query = ""
    @State private var selected: SearchHit?
    /// Tappable empty-state examples — each fills the field and searches.
    private let examples = ["jq", "http server", "terminal file manager"]

    var body: some View {
        VStack {
            HStack {
                TextField("Search packages…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await store.runSearch(query) } }
                Picker("Manager", selection: $store.browseManagerFilter) {
                    Text("All managers").tag(ManagerID?.none)
                    ForEach(store.searchableManagers, id: \.id) { s in
                        Text(s.displayName).tag(ManagerID?.some(s.id))
                    }
                }
                .frame(width: 170)
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

            let shown = store.filteredSearchResults
            if store.isSearching && shown.isEmpty {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                VStack(spacing: 12) {
                    Text(store.searchResults.isEmpty
                         ? "Search packages across every manager — try:"
                         : "No results from this manager.")
                        .foregroundStyle(.secondary)
                    if store.searchResults.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(examples, id: \.self) { example in
                                Button(example) {
                                    query = example
                                    Task { await store.runSearch(example) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            ManagerBadge(manager: hit.manager)
                            Text(hit.name).fontWeight(.medium)
                            Text(hit.latestVersion).foregroundStyle(.secondary)
                            if store.installedPackageIDs.contains(hit.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .help("Installed")
                            }
                        }
                        if !hit.summary.isEmpty {
                            Text(hit.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
