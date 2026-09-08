import SwiftUI

/// Lighter warm charcoal surfaces with small, purposeful touches of Phren color.
enum PhrenTheme {
    static let bg = Color(hex: 0x29282A)
    static let bgSunken = Color(hex: 0x232225)
    static let surface = Color(hex: 0x383638)
    static let surfaceRaised = Color(hex: 0x494648)

    static let text = Color(hex: 0xF7F4EF)
    static let textSecondary = Color(hex: 0xDCD5CF)
    static let textMuted = Color(hex: 0xC0B9B3)
    static let textDim = Color(hex: 0xB0AAA4)

    // Navigation stays neutral; lavender marks selected controls and actions.
    static let navigation = Color(hex: 0xECE7E1)
    static let accent = Color(hex: 0xB5AFE3)
    static let accentHover = Color(hex: 0xCBC6EF)
    static let accentSolid = Color(hex: 0x655A99)
    static let cyan = Color(hex: 0x8ECBD0)
    static let lavender = Color(hex: 0xB0A8CE)

    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)

    static let success = Color(hex: 0x8AC8AC)
    static let warning = Color(hex: 0xE0BC7F)
    static let danger = Color(hex: 0xEF9898)

    // Aliases kept for call-site readability
    static let green = success
    static let amber = warning
    static let red = danger
    static let violet = accentSolid

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
    func phrenScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(PhrenTheme.bg)
    }

    func phrenCard() -> some View {
        self
            .background(PhrenTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PhrenTheme.border, lineWidth: 1))
    }

    func phrenRow() -> some View {
        self.listRowBackground(PhrenTheme.surface)
            .listRowSeparatorTint(PhrenTheme.borderStrong)
    }
}

/// Apply row styling inside the builder: a background on List alone leaves
/// the system gray cells in place. Keep native scrolling, selection and forms.
struct PhrenList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List { content.phrenRow() }
            .listStyle(.insetGrouped)
            .phrenScreen()
    }
}

struct PhrenForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content.phrenRow() }
            .phrenScreen()
    }
}

/// A shared silhouette makes menus feel related without coloring every row.
struct PhrenMenuRow: View {
    let title: String
    var subtitle: String? = nil
    let icon: String
    var color: Color = PhrenTheme.textSecondary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(PhrenTheme.text)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(PhrenTheme.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// Counts are metadata, so avoid the full-size icon column used by list rows.
struct PhrenMetadataLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Mascot + cute pieces

/// The pixel-art phren, optionally bobbing like the site's animated poses.
struct PhrenMascotView: View {
    var size: CGFloat = 140
    var bobbing = true
    var glow = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        Image("PhrenMascot")
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: glow ? PhrenTheme.cyan.opacity(0.25) : .clear, radius: size / 6)
            .offset(y: up && !reduceMotion ? -6 : 0)
            .animation(
                bobbing && !reduceMotion ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : nil,
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
