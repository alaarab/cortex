import SwiftUI

/// Mascot-led empty state replacing the system ContentUnavailableView —
/// the little phren keeps the empty screens on-brand.
struct PhrenEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            PhrenMascotView(size: 76, bobbing: false, glow: false)
                .opacity(0.8)
            Text(title)
                .font(.headline)
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
