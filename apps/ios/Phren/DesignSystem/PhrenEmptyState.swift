import SwiftUI

/// Mascot-led empty state replacing the system ContentUnavailableView —
/// the little phren keeps the empty screens on-brand.
struct PhrenEmptyState: View {
    let title: String
    let message: String
    /// A screen that means something specific passes its pose (celebrate on a
    /// cleared review queue, searching on the search tab). Left nil, the state
    /// draws a random character from the ambient cast instead, so the mascot
    /// isn't the same dude on every screen every time.
    var pose: PhrenSprite.Pose? = nil

    /// Ambient cast for empty states with nothing particular to say.
    private static let ambientCast: [PhrenSprite.Pose] = [.idle, .skating, .walking, .resting]

    @State private var chosen: PhrenSprite.Pose = .idle

    var body: some View {
        VStack(spacing: 12) {
            PhrenMascotView(size: 76, bobbing: false, glow: false, pose: pose ?? chosen)
                .opacity(0.8)
                .onAppear {
                    if pose == nil {
                        chosen = Self.ambientCast.randomElement() ?? .idle
                    }
                }
            Text(title)
                .font(.headline.monospaced())
                .foregroundStyle(PhrenTheme.text)
            Text(message)
                .font(.footnote)
                .foregroundStyle(PhrenTheme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(32)
    }
}
