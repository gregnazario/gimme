import SwiftUI
import GimmeCore

/// What's New + Update Now confirmation for a pending release (navigation
/// policy §1: sheet with a visible ✕, Esc to dismiss; Later dismisses
/// without acting; Update Now acts then relaunches).
struct UpdateSheet: View {
    @EnvironmentObject var store: GimmeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Update gimme?").font(.title2).fontWeight(.semibold)
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
            Divider()
            if let release = store.pendingUpdate {
                content(release)
            } else {
                Text("No update information is available.")
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
        }
        .frame(width: 460, height: 420)
    }

    private func content(_ release: SelfUpdate.Release) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("gimme \(release.version) is available — you have \(GimmeVersion.current). The app downloads, verifies, and relaunches itself.")
                .foregroundStyle(.secondary)
            Text("What's New").font(.headline)
            notesBody(release)
            Spacer()
            HStack {
                Spacer()
                Button("Later") { dismiss() }
                if store.isSelfUpdating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating…")
                    }
                    .padding(.horizontal, 8)
                } else {
                    Button("Update Now") {
                        Task { await store.updateSelf(release) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
    }

    /// Tag-message notes rendered as inline markdown (whitespace preserved).
    /// Empty/missing notes (old cache entry, pre-notes release) fall back to
    /// a link to the releases page.
    @ViewBuilder
    private func notesBody(_ release: SelfUpdate.Release) -> some View {
        let trimmed = release.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Release notes are on GitHub.")
                    .foregroundStyle(.secondary)
                Link("github.com/gregnazario/gimme/releases",
                     destination: URL(string: "https://github.com/gregnazario/gimme/releases")!)
            }
        } else {
            ScrollView {
                if let attributed = try? AttributedString(
                    markdown: trimmed,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(attributed).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(trimmed).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
        }
    }
}
