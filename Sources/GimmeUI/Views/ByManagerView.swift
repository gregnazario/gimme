import SwiftUI
import GimmeCore

struct ByManagerView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        List {
            // Status header: one row per backend manager.
            Section("Managers") {
                ForEach(store.managerStatuses) { status in
                    ManagerStatusRow(status: status) {
                        Task { await store.bootstrap(status.id) }
                    }
                }
            }
            // Installed packages grouped by manager.
            ForEach(ManagerID.allCases, id: \.self) { m in
                let pkgs = store.installed.filter { $0.manager == m }
                Section("\(m.displayName) — \(pkgs.count) installed") {
                    if pkgs.isEmpty {
                        Text("Nothing installed").foregroundStyle(.secondary)
                    } else {
                        ForEach(pkgs) { pkg in
                            HStack {
                                Text(pkg.name)
                                Spacer()
                                Text(pkg.version).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            // Runtime version managers (mise/asdf) — detect only, not managed.
            if !store.runtimeManagers.isEmpty {
                Section("Runtime version managers (coexist; not managed by gimmie)") {
                    ForEach(store.runtimeManagers, id: \.kind) { vm in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: "clock.arrow.2.circlepath")
                                    .foregroundStyle(.purple)
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
            }
        }
        .navigationTitle("By Manager")
        .task { await store.loadAll() }
    }
}

/// One backend's status: icon, name, version (or "not installed"), and a
/// bootstrap button when unavailable.
struct ManagerStatusRow: View {
    let status: Gimme.ManagerStatus
    let onBootstrap: () -> Void

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
            if !status.available {
                Button("Install", action: onBootstrap)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch status.id {
        case .homebrew: return .orange
        case .go:       return .blue
        case .uv:       return .green
        case .cargo:    return .red
        case .bun:      return .pink
        case .npm:      return .teal
        case .pnpm:     return .indigo
        case .yarn:     return .blue
        case .gem:      return .pink
        case .composer: return .purple
        }
    }
}
