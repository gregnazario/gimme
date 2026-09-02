import SwiftUI
import GimmeCore

/// Query-less discovery: curated collections of worth-installing tools.
/// Cards grid → push into a collection (nav policy §2, toolbar Back);
/// tapping a tool opens the shared DetailSheet (§1). Curated order stands —
/// no ranking.
struct ExploreView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                          spacing: 12) {
                    ForEach(ExploreCollections.all) { collection in
                        NavigationLink(value: collection) {
                            ExploreCard(collection: collection)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Explore")
            .navigationDestination(for: ExploreCollection.self) { collection in
                CollectionView(collection: collection)
            }
        }
    }
}

private struct ExploreCard: View {
    let collection: ExploreCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: collection.icon)
                .font(.title)
                .foregroundStyle(GimmeApp.accent)
            Text(collection.name).fontWeight(.semibold)
            Text(collection.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
            Text("\(collection.tools.count) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct CollectionView: View {
    @EnvironmentObject var store: GimmeStore
    let collection: ExploreCollection
    @State private var selected: SearchHit?

    var body: some View {
        List(collection.tools) { tool in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    ManagerBadge(manager: tool.manager)
                    Text(tool.name).fontWeight(.medium)
                    if store.installedPackageIDs.contains(tool.id) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .help("Installed")
                    }
                }
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { selected = tool.searchHit }
        }
        .navigationTitle(collection.name)
        .sheet(item: $selected) { hit in DetailSheet(package: .searchable(hit)) }
    }
}
