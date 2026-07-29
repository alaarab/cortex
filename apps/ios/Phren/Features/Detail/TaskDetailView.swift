import SwiftUI
import PhrenKit

/// Everything the parser knows about one task — the GitHub link, activity
/// dates, session, and finding-graph edges the list row has no room for.
struct TaskDetailView: View {
    let storeId: String
    let project: String
    /// stableId (bid) or positional id.
    let ref: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TaskListRow?
    @State private var confirmDelete = false

    private var task: PhrenTask? {
        let doc = model.snapshot(for: storeId).tasks[project]
        return doc?.allItems.first { $0.stableId == ref || $0.id == ref }
    }

    var body: some View {
        if let task {
            content(task)
        } else {
            RouteUnresolvedView()
        }
    }

    private func content(_ task: PhrenTask) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(TasksFile.stripPriorityTag(TasksFile.stripPinnedTag(task.line)))
                        .font(.callout)
                        .textSelection(.enabled)
                        .strikethrough(task.checked)
                    HStack(spacing: 6) {
                        TagChip(text: task.section.rawValue.lowercased(), role: .scope)
                        if let priority = task.priority {
                            TagChip(text: priority.rawValue,
                                    color: priorityColor(priority))
                        }
                        if task.pinned ?? false {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                                .foregroundStyle(PhrenTheme.amber)
                                .accessibilityLabel("Pinned")
                        }
                        if task.speculative ?? false {
                            TagChip(text: "speculative", role: .status)
                        }
                        Spacer()
                    }
                    if let context = task.context {
                        Text(context)
                            .font(.caption)
                            .foregroundStyle(PhrenTheme.textMuted)
                    }
                }
                .padding(.vertical, 2)
            }

            if task.githubIssue != nil || task.githubUrl != nil {
                Section("GitHub") {
                    // The one honest external link in the model.
                    if let urlString = task.githubUrl, let url = URL(string: urlString) {
                        Link(destination: url) {
                            LabeledContent("Issue") {
                                HStack(spacing: 4) {
                                    Text(task.githubIssue.map { "#\($0)" } ?? "open")
                                        .font(.caption.monospaced())
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption2)
                                }
                            }
                            .font(.caption)
                        }
                    } else if let issue = task.githubIssue {
                        CopyableRow(label: "Issue", value: "#\(issue)")
                    }
                }
            }

            if hasActivity(task) {
                Section("Activity") {
                    if let createdAt = task.createdAt {
                        CopyableRow(label: "Created", value: createdAt)
                    }
                    if let lastActivity = task.lastActivity {
                        CopyableRow(label: "Last activity", value: lastActivity)
                    }
                    if let sessionId = task.sessionId {
                        CopyableRow(label: "Session", value: sessionId)
                    }
                    if let scope = task.scope {
                        CopyableRow(label: "Scope", value: scope, monospaced: false)
                    }
                    if let rank = task.rank {
                        CopyableRow(label: "Rank", value: "\(rank)")
                    }
                }
            }

            if task.parentFinding != nil || !(task.childFindings ?? []).isEmpty {
                Section("Findings") {
                    if let parent = task.parentFinding {
                        findingEdge(label: "From finding", ref: parent)
                    }
                    ForEach(task.childFindings ?? [], id: \.self) { child in
                        findingEdge(label: "Produced", ref: child)
                    }
                }
            }
        }
        .phrenScreen()
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canPush(storeId: storeId) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if !task.checked {
                            Button {
                                Task {
                                    await model.perform(.completeTask(
                                        project: project,
                                        match: task.stableId ?? task.id
                                    ), in: storeId)
                                }
                            } label: {
                                Label("Complete", systemImage: "checkmark.circle")
                            }
                        }
                        Button {
                            editing = TaskListRow(storeId: storeId,
                                                  storeName: model.storeName(for: storeId),
                                                  project: project, task: task)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("Task actions")
                    }
                }
            }
        }
        .sheet(item: $editing) { row in
            TaskEditSheet(row: row)
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.perform(.removeTask(
                        project: project,
                        match: task.stableId ?? task.id
                    ), in: storeId)
                    dismiss()
                }
            }
        }
    }

    /// Parent/child refs may be `fid:xxxxxxxx` or a text snippet — both route
    /// through the same resolution the finding detail uses.
    @ViewBuilder
    private func findingEdge(label: String, ref: String) -> some View {
        if ref.hasPrefix("fid:") {
            let fid = String(ref.dropFirst(4))
            NavigationLink(value: Route.finding(storeId: storeId, project: project, ref: fid)) {
                LabeledContent(label) {
                    Text(ref).font(.caption.monospaced())
                }
                .font(.caption)
            }
        } else {
            FindingRefLink(label: label, ref: ref, storeId: storeId, project: project)
        }
    }

    private func hasActivity(_ task: PhrenTask) -> Bool {
        task.createdAt != nil || task.lastActivity != nil
            || task.sessionId != nil || task.scope != nil || task.rank != nil
    }

    private func priorityColor(_ priority: PhrenTask.Priority) -> Color {
        switch priority {
        case .high: return PhrenTheme.red
        case .medium: return PhrenTheme.amber
        case .low: return PhrenTheme.textDim
        }
    }
}
