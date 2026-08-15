import SwiftUI
import GimmeCore

/// Single source of truth for manager colors (brand-informed, hue-spaced for
/// distinctness at small badge sizes). Used by ManagerBadge and the Package
/// Managers status rows — do not switch on manager colors anywhere else.
enum ManagerPalette {
    static func color(for manager: ManagerID) -> Color {
        Color(nsHex(for: manager))
    }

    /// Hex values spaced around the hue wheel so adjacent managers in any list
    /// stay distinguishable: red → orange → brown → yellow → lime → green →
    /// teal → light-cyan → deep-sky → blue → indigo → purple → pink → stone.
    static func nsHex(for manager: ManagerID) -> String {
        switch manager {
        case .npm:      return "#DC2626"  // npm red
        case .homebrew: return "#F97316"  // brew orange
        case .cargo:    return "#92400E"  // rust brown
        case .pnpm:     return "#EAB308"  // yellow
        case .pipx:     return "#65A30D"  // lime
        case .uv:       return "#16A34A"  // green
        case .composer: return "#0D9488"  // teal
        case .aqua:     return "#22D3EE"  // light cyan (aqua = water)
        case .go:       return "#0369A1"  // deep sky (Go)
        case .deno:     return "#2563EB"  // blue
        case .yarn:     return "#4F46E5"  // indigo
        case .gem:      return "#7C3AED"  // purple
        case .bun:      return "#DB2777"  // pink
        case .ubi:      return "#78716C"  // stone
        }
    }
}

extension Color {
    /// Init from a hex string like "#DC2626".
    init(_ hex: String) {
        var value: UInt64 = 0
        _ = Scanner(string: hex.replacingOccurrences(of: "#", with: ""))
            .scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
