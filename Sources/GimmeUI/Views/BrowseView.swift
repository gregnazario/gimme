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
                Button("Search") { Task { await store.runSearch(query) } }
            }.padding()
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
        .navigationTitle("Browse")
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
