import SwiftUI
import GimmeCore

/// Slim banner pinned atop the detail column whenever an update is pending
/// (background launch check or manual check). "Update Now" runs the verified
/// self-update in place; ✕ hides the banner until the next background check
/// (12 h TTL) re-raises it.
struct UpdateBanner: View {
    @EnvironmentObject var store: GimmeStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(GimmeApp.accent)
            if let release = store.pendingUpdate {
                Text("gimme \(release.version) is available")
                    .fontWeight(.medium)
                Text("(you have \(GimmeVersion.current))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isSelfUpdating {
                ProgressView().controlSize(.small)
                Text("Updating…").foregroundStyle(.secondary)
            } else {
                Button("What's New") { store.showUpdateSheet = true }
                Button("Update Now") {
                    if let release = store.pendingUpdate {
                        Task { await store.updateSelf(release) }
                    }
                }
                .buttonStyle(.borderedProminent)
                Button {
                    store.pendingUpdate = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide until the next check")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
