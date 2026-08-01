import SwiftUI

/// The receipt a capture leaves behind in Siri and, more importantly, in the
/// Shortcuts app.
///
/// A spoken "Added to alphalens" is easy to miss and impossible to miss *twice*
/// — running a shortcut from its tile speaks nothing at all. Returning a
/// snippet alongside the dialog means every run, voice or tap, puts the
/// destination on screen next to the text that was filed there.
///
/// Deliberately plain: no PhrenTheme, no assets, no PhrenKit. This renders
/// inside the system's own UI, on its background, at whatever size Siri picks.
struct CaptureSnippetView: View {
    let kind: String
    let text: String
    /// Store-qualified whenever more than one store is attached — the same
    /// string the Settings picker and the project list show.
    let destination: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .lineLimit(4)
            Label(destination, systemImage: "folder")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}
