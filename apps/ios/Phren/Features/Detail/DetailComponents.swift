import SwiftUI
import PhrenKit

/// A labeled metadata row whose value can be copied from a context menu.
/// Monospaced by default — most detail payload is ids, paths, and dates.
struct CopyableRow: View {
    let label: String
    let value: String
    var monospaced = true

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(PhrenTheme.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A supersedes/superseded-by/contradicts reference: navigable when the
/// snippet resolves to a finding in the project, a plain monospaced snippet
/// when it doesn't (the target may have been reworded or removed).
struct FindingRefLink: View {
    let label: String
    let ref: String
    let storeId: String
    let project: String

    @Environment(AppModel.self) private var model

    var body: some View {
        let resolved = FindingsFile.resolveFindingRef(
            ref, in: model.findings(storeId: storeId, project: project))
        if let resolved {
            NavigationLink(value: Route.finding(
                storeId: storeId, project: project,
                ref: resolved.stableId ?? resolved.id
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(PhrenTheme.textMuted)
                        .textCase(.uppercase)
                    Text(resolved.text)
                        .font(.caption)
                        .foregroundStyle(PhrenTheme.textSecondary)
                        .lineLimit(2)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(PhrenTheme.textMuted)
                    .textCase(.uppercase)
                Text(ref)
                    .font(.caption.monospaced())
                    .foregroundStyle(PhrenTheme.textMuted)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
