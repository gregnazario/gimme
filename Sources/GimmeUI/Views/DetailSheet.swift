import SwiftUI
import GimmeCore

struct DetailSheet: View {
    enum Subject {
        case installed(InstalledPackage)
        case searchable(SearchHit)
    }
    @EnvironmentObject var store: GimmeStore
    @Environment(\.dismiss) var dismiss
    let package: Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch package {
            case .installed(let p):
                Text(p.name).font(.title2)
                ManagerBadge(manager: p.manager)
                Text("version \(p.version)")
                Button("Uninstall") { Task { await store.uninstall(p); dismiss() } }
            case .searchable(let h):
                Text(h.name).font(.title2)
                ManagerBadge(manager: h.manager)
                Text(h.summary)
                Text(h.latestVersion).foregroundStyle(.secondary)
                Button("Install") { Task { await store.install(h); dismiss() } }
            }
            Spacer()
        }
        .padding()
        .frame(width: 360, height: 280)
    }
}
