import SwiftUI
import GimmeCore

/// Info page about the package managers themselves (status, version, bootstrap,
/// package count) plus runtime version managers. Replaces the old "By Manager"
/// view, which duplicated Installed's per-manager package lists.
///
/// Per the AGENTS.md navigation policy: this is a sidebar root (no back button).
/// The "N packages" affordance on each card navigates to Installed pre-filtered
/// to that manager — a push into the Installed flow, not a modal.
struct PackageManagersView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        List {
            Section("Package managers") {
                ForEach(store.managerStatuses) { status in
                    ManagerStatusRow(
                        status: status,
                        packageCount: packageCount(for: status.id),
                        onBootstrap: { Task { await store.bootstrap(status.id) } },
                        onShowPackages: { store.showInstalledFiltered(by: status.id) },
                        bootstrapState: store.bootstrapStatus[status.id]
                    )
                }
            }
            if !store.runtimeManagers.isEmpty {
                Section("Runtime version managers (coexist; not managed by gimmie)") {
                    ForEach(store.runtimeManagers, id: \.kind) { vm in
                        RuntimeManagerRow(vm: vm)
                    }
                }
            }
        }
        .navigationTitle("Package Managers")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.loadStatuses(force: true) } } label: {
                    if store.isRefreshingStatuses {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshingStatuses)
            }
        }
        // loadAll (not just statuses) so the per-card package counts come from
        // `store.installed` — otherwise they read 0 on a first visit.
        .task { await store.loadAll() }
    }

    /// Count installed packages for a manager from the cached installed list.
    private func packageCount(for id: ManagerID) -> Int {
        store.installed.filter { $0.manager == id }.count
    }
}

/// One backend manager's status card: icon, name, version (or "not installed"),
/// a bootstrap button when missing, and a "N packages" button that jumps to
/// Installed filtered to this manager.
struct ManagerStatusRow: View {
    let status: Gimme.ManagerStatus
    let packageCount: Int
    let onBootstrap: () -> Void
    /// Navigate to Installed pre-filtered to this manager.
    let onShowPackages: () -> Void
    /// Bootstrap state ("Installing…" or nil when idle).
    let bootstrapState: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.id.iconName)
                .frame(width: 20)
                .foregroundStyle(status.available ? statusColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.displayName).fontWeight(.medium)
                    if !status.enabled {
                        Text("disabled").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(status.available ? (status.version ?? "installed") : "not installed")
                    .font(.caption)
                    .foregroundStyle(status.available ? Color.secondary : Color.orange)
            }
            Spacer()
            // Jump to Installed filtered to this manager.
            Button {
                onShowPackages()
            } label: {
                Text("\(packageCount) package\(packageCount == 1 ? "" : "s")")
                    .font(.caption)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(packageCount == 0)
            .help(packageCount == 0 ? "No packages installed via \(status.id.rawValue)" : "Show in Installed")

            if !status.available {
                if let bsState = bootstrapState {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text(bsState).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Install", action: onBootstrap)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color { ManagerPalette.color(for: status.id) }
}


/// One runtime version manager (mise/asdf) with a summary of managed runtimes.
struct RuntimeManagerRow: View {
    let vm: RuntimeManagerStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath").foregroundStyle(.purple)
                Text(vm.kind.rawValue.capitalized).fontWeight(.medium)
                Spacer()
                Text("\(vm.runtimes.count) runtimes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(vm.runtimes.prefix(10).enumerated()), id: \.offset) { _, r in
                Text("    \(r.tool) \(r.version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.runtimes.count > 10 {
                Text("    … +\(vm.runtimes.count - 10) more")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
