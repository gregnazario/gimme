import SwiftUI
import GimmeCore

/// "Report an Issue" sheet (Help menu). The user types what happened and
/// what they expected; gimme attaches an auto-collected context snapshot
/// (version, OS, manager statuses, recent activity) and opens the prefilled
/// GitHub issue in the browser for review and submission.
struct ReportIssueView: View {
    @EnvironmentObject var store: GimmeStore
    @Environment(\.dismiss) var dismiss

    @State private var title = ""
    @State private var happened = ""
    @State private var expected = ""
    @State private var showContext = false
    /// Captured when the sheet opens, so later activity doesn't leak in.
    @State private var context = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section("Issue") {
                    TextField("One-line summary", text: $title)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What happened?").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $happened)
                            .font(.body)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .overlay(
                                Group { if happened.isEmpty {
                                    Text("Describe what you did and what went wrong…")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }}
                            )
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What did you expect?").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $expected)
                            .font(.body)
                            .frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .overlay(
                                Group { if expected.isEmpty {
                                    Text("Describe the behavior you expected instead…")
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .allowsHitTesting(false)
                                }}
                            )
                    }
                }
                Section {
                    DisclosureGroup("Attached context (auto-collected)", isExpanded: $showContext) {
                        ScrollView {
                            Text(context)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 140)
                    }
                    Text("The issue opens in your browser for review before you submit it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 520, height: 480)
        .onAppear { context = Self.contextSnapshot(from: store) }
    }

    private var header: some View {
        HStack {
            Text("Report an Issue")
                .font(.title2).fontWeight(.semibold)
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
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                openIssue()
                dismiss()
            } label: {
                Label("Create Issue", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func openIssue() {
        guard let url = IssueReporter.issueURL(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            happened: happened,
            expected: expected,
            context: context
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Version + OS + manager statuses + recent activity. The IssueReporter
    /// caps the total length, so this can be generous.
    static func contextSnapshot(from store: GimmeStore) -> String {
        var lines: [String] = []
        lines.append("gimme \(GimmeVersion.current)")
        let os = ProcessInfo.processInfo
        lines.append("macOS \(os.operatingSystemVersionString), \(machineArchitecture())")

        if !store.managerStatuses.isEmpty {
            lines.append("")
            lines.append("Managers:")
            for s in store.managerStatuses {
                let state = s.available ? "available\(s.version.map { " \($0)" } ?? "")" : "not installed"
                lines.append("- \(s.displayName): \(state)\(s.enabled ? "" : " (disabled)")")
            }
        }

        if !store.activity.isEmpty {
            lines.append("")
            lines.append("Recent activity:")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for entry in store.activity.prefix(30) {
                lines.append("- [\(formatter.string(from: entry.time))] \(entry.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func machineArchitecture() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
