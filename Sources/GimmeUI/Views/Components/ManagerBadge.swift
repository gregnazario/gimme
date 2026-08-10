import SwiftUI
import GimmeCore

struct ManagerBadge: View {
    let manager: ManagerID
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.iconName)
            Text(manager.rawValue)
        }
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .clipShape(Capsule())
    }
    private var color: Color {
        switch manager {
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
