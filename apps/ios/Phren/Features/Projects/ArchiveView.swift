import SwiftUI
import PhrenKit

/// The cold tier's table of contents for one project: every
/// `reference/topics/*.md` the CLI's consolidation wrote, listed from the
/// catalogue the recursive tree already paid for. Opening a row is the only
/// thing in the app that fetches an archived document.
struct ArchiveBrowserView: View {
    let storeId: String
    let project: String

    @Environment(AppModel.self) private var model
    @State private var topics: [ColdDocRef] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(topics) { topic in
                    NavigationLink(value: topic) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.displayName).font(.headline)
                            Text(subtitle(for: topic))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } footer: {
                // Say plainly what the tier is, so "why isn't this in search?"
                // has an answer on the screen where it comes up.
                Text("Consolidated findings the phren CLI moved out of FINDINGS.md. Read-only, downloaded one topic at a time, and left out of search so a search returns live knowledge.")
            }
        }
        .overlay {
            if loaded && topics.isEmpty {
                PhrenEmptyState(title: "Nothing archived",
                                message: "\(project) hasn't passed its findings cap yet, so nothing has been consolidated.")
            }
        }
        .phrenScreen()
        .navigationTitle("Archive")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ColdDocRef.self) { topic in
            ArchiveTopicView(storeId: storeId, topic: topic)
        }
        .task {
            topics = await model.coldTopics(storeId: storeId, project: project)
            loaded = true
        }
    }

    private func subtitle(for topic: ColdDocRef) -> String {
        guard let size = topic.size else { return "archived findings" }
        return "\(ArchiveFormat.size(size)) of archived findings"
    }
}

/// One hydrated topic document. Every entry is marked archived and has no edit
/// affordance — archived findings are read-only everywhere else in phren
/// (`FindingsFile.matchBullet` refuses them outright), and they are read-only
/// here too.
struct ArchiveTopicView: View {
    let storeId: String
    let topic: ColdDocRef

    @Environment(AppModel.self) private var model
    @State private var document: TopicDocument?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        Group {
            if let document {
                List {
                    ForEach(document.groupedByDate, id: \.date) { group in
                        Section("Archived \(group.date)") {
                            ForEach(group.entries) { entry in
                                ArchivedFindingRow(finding: entry)
                            }
                        }
                    }
                }
            } else if loading {
                ProgressView("Fetching \(topic.displayName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhrenEmptyState(
                    title: "Couldn't open this topic",
                    message: error ?? "The archive document is no longer in this store."
                )
            }
        }
        .phrenScreen()
        .navigationTitle(topic.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A cached copy still goes through here: `coldDocument` compares
            // the cached sha against the tree's before serving it, so a topic
            // the CLI has re-consolidated since is refetched rather than
            // rendered stale.
            do {
                document = try await model.coldDocument(storeId: storeId, path: topic.path)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

/// A read-only archived finding: same layout as the live rows, plus an
/// unmissable "archived" chip and no swipe actions at all.
private struct ArchivedFindingRow: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                TagChip(text: "archived", role: .status)
                if let tag = finding.typeTag {
                    TagChip(text: tag, role: .type)
                }
                if let scope = finding.scope {
                    TagChip(text: scope, role: .scope)
                }
                Spacer()
                Text(finding.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // Mirrors Components.swift FindingRow.displayText: the [tag] prefix is
    // dropped because the type chip already carries it.
    private var displayText: String {
        guard let tag = finding.typeTag else { return finding.text }
        let prefix = "[\(tag)] "
        return finding.text.lowercased().hasPrefix(prefix.lowercased())
            ? String(finding.text.dropFirst(prefix.count))
            : finding.text
    }
}

/// Byte counts as a person reads them. Local to the archive surfaces — this is
/// the only place in the app that has a size to show.
enum ArchiveFormat {
    static func size(_ bytes: Int) -> String {
        bytes < 1024
            ? "\(bytes) B"
            : (bytes < 1_048_576
                ? String(format: "%.0f KB", Double(bytes) / 1024)
                : String(format: "%.1f MB", Double(bytes) / 1_048_576))
    }
}
