import SwiftUI
import GimmeCore

struct ManagerFilterChip: View {
    let manager: ManagerID
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(manager.rawValue)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
