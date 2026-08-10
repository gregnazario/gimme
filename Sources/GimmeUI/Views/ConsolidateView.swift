import SwiftUI
import GimmeCore

struct ConsolidateView: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        Group {
            if let report = store.consolidationReport {
                if report.hasDuplicates {
                    duplicatesList(report)
                } else {
                    cleanState
                }
            } else {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Consolidate")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await store.loadConsolidationReport(refresh: true) } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task { await store.loadConsolidationReport() }
    }

    private var cleanState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40)).foregroundStyle(.green)
            Text("No duplicates found").font(.title3).fontWeight(.medium)
            Text("Every package lives in just one manager within its ecosystem.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            ForEach(Ecosystem.allCases.filter { !$0.managers.isEmpty }, id: \.self) { eco in
                Text("\(eco.displayName): clean").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func duplicatesList(_ report: ConsolidationReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(report.duplicates.count) duplicate\(report.duplicates.count == 1 ? "" : "s") found")
                    .font(.headline)
                Spacer()
            }.padding(.horizontal).padding(.top, 8)
            List {
                ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                    DuplicateCard(step: step)
                }
                if !report.cleanEcosystems.isEmpty {
                    Section("Clean ecosystems") {
                        ForEach(report.cleanEcosystems.filter { !$0.managers.isEmpty }, id: \.self) { eco in
                            Text("\(eco.displayName): clean").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("No changes are made automatically. Copy the commands and run them in Terminal.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }
}

/// One duplicate as a card: name, managers that have it, recommendation, and
/// copyable migration commands.
struct DuplicateCard: View {
    let step: MigrationStep
    @State private var copied = false

    private var commandsText: String {
        ([step.installCommand].compactMap { $0 } + step.uninstallCommands).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.duplicate.name).fontWeight(.semibold)
                Spacer()
                Text(step.duplicate.ecosystem.displayName)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(step.duplicate.installed, id: \.id) { p in
                    ManagerBadge(manager: p.manager)
                        .opacity(p.manager == step.duplicate.recommendedManager ? 1 : 0.5)
                }
                Spacer()
                Label(step.duplicate.recommendedManager.rawValue, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
            // The exact commands to run, selectable + copyable.
            VStack(alignment: .leading, spacing: 2) {
                ForEach([step.installCommand].compactMap { $0 } + step.uninstallCommands, id: \.self) { cmd in
                    Text(cmd).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(6)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commandsText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy commands", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}
