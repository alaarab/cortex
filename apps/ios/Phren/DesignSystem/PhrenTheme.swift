import SwiftUI

/// The phren visual identity, blending the two canonical sources:
/// - the `phren web-ui` deep-void theme (packages/cli/src/ui/deep-void.ts) —
///   near-black navy base, violet accent, lavender-tinted borders, glows
/// - the site (docs/style.css) — cyan highlights, monospace data, pixel mascot
/// The brand is dark-only.
enum PhrenTheme {
    // Surfaces — deep-void.ts:19-23
    static let bg = Color(hex: 0x0A0A1A)            // --bg
    static let bgSunken = Color(hex: 0x0D0D22)      // --surface-sunken
    static let surface = Color(hex: 0x12122A)       // --surface-solid
    static let surfaceRaised = Color(hex: 0x1A1A3E) // site --bg-2 (cards)

    // Ink — deep-void.ts:25-27
    static let text = Color(hex: 0xECE9F5)          // --ink
    static let textSecondary = Color(hex: 0xC8C3E3) // --ink-secondary
    static let textMuted = Color(hex: 0xECE9F5).opacity(0.55) // --muted
    static let textDim = Color(hex: 0x7A7570)       // site --text-dim

    // Accents — violet is THE interactive accent (deep-void.ts:29-40),
    // cyan is the live/glow highlight shared by both sources.
    static let accent = Color(hex: 0x9058F0)        // --accent
    static let accentHover = Color(hex: 0xB07AFF)   // --accent-hover
    static let accentSolid = Color(hex: 0x7C3AED)   // --accent-solid
    static let cyan = Color(hex: 0x28D3F2)          // --cyan
    static let lavender = Color(hex: 0x9B8DC8)      // site --copper

    // Borders — deep-void.ts:42-44 (lavender-tinted)
    static let border = Color(hex: 0x9C8FF8).opacity(0.18)
    static let borderStrong = Color(hex: 0x9C8FF8).opacity(0.32)

    // Status — deep-void.ts:46-51
    static let success = Color(hex: 0x4ADE80)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    // Aliases kept for call-site readability
    static let green = success
    static let amber = warning
    static let red = danger
    static let violet = Color(hex: 0x7C3AED)

    /// Chip color roles, mapped to the deep-void conventions.
    static func chipColor(_ role: ChipRole) -> Color {
        switch role {
        case .project: return cyan
        case .store: return lavender
        case .type: return accent
        case .status: return warning
        case .scope: return accentHover
        case .good: return success
        case .warn: return warning
        case .bad: return danger
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
    /// Deep-void screen background behind system list/scroll content.
    func phrenScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(PhrenTheme.bg)
    }

    /// Web-UI card: solid navy surface, lavender border, soft violet shadow
    /// (deep-void --surface + --border + --shadow).
    func phrenCard() -> some View {
        self
            .background(PhrenTheme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(PhrenTheme.border, lineWidth: 1))
            .shadow(color: PhrenTheme.accentSolid.opacity(0.18), radius: 10, y: 4)
    }
}

/// List row background matching the web UI's raised surface.
struct PhrenRowBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.listRowBackground(PhrenTheme.surface)
    }
}

extension View {
    func phrenRow() -> some View {
        modifier(PhrenRowBackground())
    }
}

// MARK: - Mascot + cute pieces

/// The pixel-art phren, optionally bobbing like the site's animated poses.
struct PhrenMascotView: View {
    var size: CGFloat = 140
    var bobbing = true
    var glow = true

    @State private var up = false

    var body: some View {
        Image("PhrenMascot")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: glow ? PhrenTheme.cyan.opacity(0.25) : .clear, radius: size / 6)
            .offset(y: up ? -6 : 0)
            .animation(
                bobbing ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : nil,
                value: up
            )
            .onAppear { if bobbing { up = true } }
            .accessibilityHidden(true)
    }
}

/// The site's tilted white "finding card" with a typewriter line
/// (docs/index.html .mini-card / .mini-line) — the cute signature moment
/// on the sign-in screen.
struct TypewriterFindingCard: View {
    private static let lines = [
        "[pattern] always validate JWT expiry before refresh",
        "[decision] chose FTS5 over embeddings for v1 search",
        "[pitfall] session hooks fire twice in mixed mode",
        "[architecture] git is the sync layer — no server",
    ]

    @State private var lineIndex = 0
    @State private var visibleCount = 0
    @State private var caretOn = true

    private let typeTimer = Timer.publish(every: 0.055, on: .main, in: .common).autoconnect()
    private let caretTimer = Timer.publish(every: 0.7, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FINDING")
                .font(.system(size: 9, design: .monospaced).weight(.bold))
                .tracking(1.5)
                .foregroundStyle(PhrenTheme.accentSolid)
            HStack(spacing: 0) {
                Text(typedText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(hex: 0x12122A))
                    .lineLimit(1)
                Rectangle()
                    .fill(caretOn ? Color(hex: 0x12122A) : .clear)
                    .frame(width: 2, height: 12)
            }
            Text("~/.phren · synced")
                .font(.system(size: 9, design: .monospaced))
                .tracking(1)
                .foregroundStyle(Color(hex: 0x5A4A7A))
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(width: 260, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0x12122A), lineWidth: 1))
        // The site's hard offset shadow (box-shadow: 4px 4px 0)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(.black.opacity(0.35))
                .offset(x: 4, y: 4)
        )
        .rotationEffect(.degrees(-1.2))
        .onReceive(typeTimer) { _ in advance() }
        .onReceive(caretTimer) { _ in caretOn.toggle() }
        .accessibilityHidden(true)
    }

    private var currentLine: String { Self.lines[lineIndex] }

    private var typedText: String {
        String(currentLine.prefix(visibleCount))
    }

    private func advance() {
        if visibleCount < currentLine.count {
            visibleCount += 1
        } else {
            // Pause at the full line, then move to the next one.
            visibleCount += 1
            if visibleCount > currentLine.count + 24 {
                visibleCount = 0
                lineIndex = (lineIndex + 1) % Self.lines.count
            }
        }
    }
}
