import SwiftUI
import PhrenKit

/// Everything the parser knows about one finding — the citation, provenance,
/// lifecycle, and graph payload that list rows have no room for.
struct FindingDetailView: View {
    let storeId: String
    let project: String
    /// stableId (fid) or positional id.
    let ref: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var confirmDelete = false

    private var finding: Finding? {
        model.findings(storeId: storeId, project: project)
            .first { $0.stableId == ref || $0.id == ref }
    }

    var body: some View {
        if let finding {
            content(finding)
        } else {
            RouteUnresolvedView()
        }
    }

    private func content(_ finding: Finding) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(FindingRow.displayText(finding))
                        .font(.callout)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        if let tag = finding.typeTag {
                            TagChip(text: tag, role: .type)
                        }
                        if finding.status != .active {
                            TagChip(text: finding.status.rawValue, role: .status)
                        }
                        if finding.archived {
                            TagChip(text: "archived", role: .status)
                        }
                        if let confidence = finding.confidence {
                            TagChip(text: String(format: "%.0f%%", confidence * 100),
                                    color: confidence < 0.7 ? PhrenTheme.amber : PhrenTheme.green)
                        }
                        Spacer()
                        Text(finding.date)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }

            if hasLifecycle(finding) {
                Section("Lifecycle") {
                    if finding.status != .active {
                        CopyableRow(label: "Status", value: finding.status.rawValue, monospaced: false)
                    }
                    if let reason = finding.statusReason {
                        CopyableRow(label: "Reason", value: reason, monospaced: false)
                    }
                    if let updated = finding.statusUpdated {
                        CopyableRow(label: "Updated", value: updated)
                    }
                    if let supersedes = finding.supersedes {
                        FindingRefLink(label: "Supersedes", ref: supersedes,
                                       storeId: storeId, project: project)
                    }
                    if let supersededBy = finding.supersededBy {
                        FindingRefLink(label: "Superseded by", ref: supersededBy,
                                       storeId: storeId, project: project)
                    }
                    ForEach(finding.contradicts ?? [], id: \.self) { ref in
                        FindingRefLink(label: "Contradicts", ref: ref,
                                       storeId: storeId, project: project)
                    }
                    if let statusRef = finding.statusRef {
                        FindingRefLink(label: "Status ref", ref: statusRef,
                                       storeId: storeId, project: project)
                    }
                }
            }

            if let citation = finding.citationData {
                // Citation repos are local filesystem paths from the writing
                // machine — an honest render is copyable monospace, not a
                // fabricated GitHub link.
                Section("Citation") {
                    if let file = citation.file {
                        CopyableRow(label: "File",
                                    value: citation.line.map { "\(file):\($0)" } ?? file)
                    }
                    if let repo = citation.repo {
                        CopyableRow(label: "Repo", value: repo)
                    }
                    if let commit = citation.commit {
                        CopyableRow(label: "Commit", value: String(commit.prefix(12)))
                    }
                    CopyableRow(label: "Created", value: citation.createdAt)
                    if let taskItem = citation.taskItem {
                        if let bid = taskItem.split(separator: ":").last,
                           taskItem.hasPrefix("bid:") {
                            NavigationLink(value: Route.task(
                                storeId: storeId, project: project, ref: String(bid))) {
                                LabeledContent("Task") {
                                    Text(taskItem).font(.caption.monospaced())
                                }
                                .font(.caption)
                            }
                        } else {
                            CopyableRow(label: "Task", value: taskItem)
                        }
                    }
                }
            }

            if let provenance = finding.provenance, !provenance.isEmpty {
                Section("Provenance") {
                    if let source = provenance.source {
                        CopyableRow(label: "Source", value: source, monospaced: false)
                    }
                    if let actor = provenance.actor {
                        CopyableRow(label: "Actor", value: actor)
                    }
                    if let machine = provenance.machine {
                        CopyableRow(label: "Machine", value: machine)
                    }
                    if let tool = provenance.tool {
                        CopyableRow(label: "Tool", value: tool)
                    }
                    if let model = provenance.model {
                        CopyableRow(label: "Model", value: model)
                    }
                    if let sessionId = provenance.sessionId {
                        CopyableRow(label: "Session", value: sessionId)
                    }
                    if let scope = provenance.scope {
                        CopyableRow(label: "Scope", value: scope)
                    }
                }
            }

            Section("Raw") {
                Text(finding.rawLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(PhrenTheme.textMuted)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = finding.rawLine
                        } label: {
                            Label("Copy raw line", systemImage: "doc.on.doc")
                        }
                    }
            }
        }
        .phrenScreen()
        .navigationTitle("Finding")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Archived findings are read-only by contract (the kit throws
            // archivedReadOnly); read-only stores can't push at all.
            if !finding.archived, model.canPush(storeId: storeId) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showEdit = true } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("Finding actions")
                    }
                }
            }
        }
        .sheet(isPresented: $showEdit) {
            TextEntrySheet(title: "Edit finding", initialText: finding.text,
                           confirmLabel: "Save") { text, _ in
                await model.perform(.editFinding(
                    project: project,
                    match: finding.stableId ?? finding.text,
                    newText: text
                ), in: storeId)
            }
        }
        .confirmationDialog("Delete this finding?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.perform(.removeFinding(
                        project: project,
                        match: finding.stableId ?? finding.text
                    ), in: storeId)
                    dismiss()
                }
            }
        }
    }

    private func hasLifecycle(_ finding: Finding) -> Bool {
        finding.status != .active || finding.supersedes != nil
            || finding.supersededBy != nil || finding.statusRef != nil
            || !(finding.contradicts ?? []).isEmpty
    }
}
