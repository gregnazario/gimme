import SwiftUI
import GimmeCore

struct UpdatesView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .navigationTitle("Updates")
        .task { await store.refreshOutdated() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if store.isUpdating {
                ProgressView()
                    .controlSize(.small)
                Text("Updating…")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(store.outdated.count) update\(store.outdated.count == 1 ? "" : "s") available")
                    .font(.headline)
            }
            Spacer()
            Button {
                Task { await store.refreshOutdated() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isUpdating)
            .help("Re-check for updates across all managers")

            Button {
                Task { await store.updateAll() }
            } label: {
                Label("Update All", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            // Enable only when there's something to update and nothing in flight.
            .disabled(store.outdated.isEmpty || store.isUpdating)
            .help("Upgrade every outdated package across all managers")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var list: some View {
        Group {
            if store.outdated.isEmpty && !store.isUpdating {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("Up to date")
                        .font(.title3).fontWeight(.medium)
                    Text("No outdated packages across any manager.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.outdated) { pkg in
                    UpdateRow(pkg: pkg, state: store.upgradeStatus[pkg.id]) {
                        Task { await store.upgrade(pkg) }
                    }
                }
            }
        }
    }
}

/// One outdated package with its version transition, per-row status, and an
/// Update button.
struct UpdateRow: View {
    let pkg: OutdatedPackage
    let state: GimmeStore.UpgradeState?
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ManagerBadge(manager: pkg.manager)
            VStack(alignment: .leading, spacing: 1) {
                Text(pkg.name).fontWeight(.medium)
                Text("\(pkg.installedVersion) → \(pkg.latestVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusView
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var statusView: some View {
        switch state {
        case nil:
            Button("Update", action: onUpdate)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .pending:
            Label("Queued", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upgrading:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Updating").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text("Failed").font(.caption).foregroundStyle(.red)
            }
            .help(msg)
        }
    }
}
