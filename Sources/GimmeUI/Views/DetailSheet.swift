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

    // Fetched info for installed packages (nil while loading or unavailable).
    @State private var info: PackageInfo?
    @State private var infoLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with title + close.
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
                    detailRow("Installed version", p.version)
                    if !infoLoaded {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading details…").foregroundStyle(.secondary)
                        }
                    } else if let info {
                        if !info.summary.isEmpty {
                            detailRow("Description", info.summary)
                        }
                        if let latest = latestVersionLine(for: info, installed: p) {
                            detailRow("Latest version", latest)
                        }
                        if let homepage = info.homepage, !homepage.isEmpty {
                            detailRow("Homepage", homepage)
                        }
                        if let license = info.license, !license.isEmpty {
                            detailRow("License", license)
                        }
                    } else {
                        Text("Details unavailable from \(p.manager.displayName).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .frame(width: 460, height: 340)
        .task {
            // Only fetch for installed packages (searchable hits already have
            // their metadata from the registry search).
            if case .installed(let p) = package {
                info = await store.loadInfo(for: p)
                infoLoaded = true
            }
        }
    }

    private var titleText: String {
        switch package {
        case .installed(let p): return p.name
        case .searchable(let h): return h.name
        }
    }

    /// Build the "latest version" line, flagging when an update is available.
    private func latestVersionLine(for info: PackageInfo, installed: InstalledPackage) -> String? {
        guard !info.latestVersion.isEmpty else { return nil }
        if info.latestVersion != installed.version {
            return "\(info.latestVersion)  (update available)"
        }
        return info.latestVersion
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)   // so URLs/versions can be copied
        }
        .font(.callout)
    }
}
