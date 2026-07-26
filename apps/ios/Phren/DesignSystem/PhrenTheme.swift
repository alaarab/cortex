import SwiftUI

/// The phren visual identity, transcribed from the site's design tokens
/// (docs/style.css `:root` and docs/index.html). The brand is dark-only:
/// deep navy surfaces, electric cyan accents, lavender secondary, warm
/// off-white text, and monospace for data.
enum PhrenTheme {
    // docs/style.css :root
    static let bg = Color(hex: 0x12122A)          // --bg
    static let bg1 = Color(hex: 0x161635)         // --bg-1
    static let bg2 = Color(hex: 0x1A1A3E)         // --bg-2 (cards)
    static let cyan = Color(hex: 0x00E5FF)        // --indigo (primary accent)
    static let cyanDark = Color(hex: 0x00B8D4)    // --indigo-dark
    static let lavender = Color(hex: 0x9B8DC8)    // --copper
    static let lavenderMid = Color(hex: 0x7B68AE) // --copper-mid
    static let purpleDeep = Color(hex: 0x2D2255)  // --copper-dark
    static let text = Color(hex: 0xE8E4D9)        // --text
    static let textMuted = Color(hex: 0xA09A94)   // --text-muted
    static let textDim = Color(hex: 0x7A7570)     // --text-dim
    static let border = Color(hex: 0x2A2A50)      // --border

    // Status colors used across the site + web UI
    static let green = Color(hex: 0x8EF0A8)
    static let amber = Color(hex: 0xFFE066)
    static let red = Color(hex: 0xFF6672)
    static let violet = Color(hex: 0x7C3AED)      // finding-type tag color
    static let orange = Color(hex: 0xD4692A)

    /// Chip color roles, mapped to the brand palette.
    static func chipColor(_ role: ChipRole) -> Color {
        switch role {
        case .project: return cyan
        case .store: return lavender
        case .type: return violet
        case .status: return orange
        case .scope: return lavenderMid
        case .good: return green
        case .warn: return amber
        case .bad: return red
        }
    }

    enum ChipRole {
        case project, store, type, status, scope, good, warn, bad
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Screen scaffolding

extension View {
    /// Navy screen background behind system list/scroll content.
    func phrenScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(PhrenTheme.bg)
    }
}

/// List row background matching the site's card surface.
struct PhrenRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(PhrenTheme.bg2)
    }
}

extension View {
    func phrenRow() -> some View {
        modifier(PhrenRowBackground())
    }
}
