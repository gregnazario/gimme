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
        VStack(spacing: 0) {
            // Header with title + a visible close affordance.
            HStack {
                Text(titleText)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 12) {
                switch package {
                case .installed(let p):
                    ManagerBadge(manager: p.manager)
                    detailRow("Version", p.version)
                    Button("Uninstall", role: .destructive) {
                        Task { await store.uninstall(p); dismiss() }
                    }
                case .searchable(let h):
                    ManagerBadge(manager: h.manager)
                    if !h.summary.isEmpty { detailRow("Summary", h.summary) }
                    detailRow("Latest version", h.latestVersion)
                    Button {
                        Task { await store.install(h); dismiss() }
                    } label: {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 240)
    }

    private var titleText: String {
        switch package {
        case .installed(let p): return p.name
        case .searchable(let h): return h.name
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}
