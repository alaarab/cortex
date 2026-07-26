import SwiftUI
import PhrenKit

struct TasksView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                TaskListView(projectFilter: nil)
            }
            .navigationTitle("Tasks")
        }
    }
}

struct TaskListRow: Identifiable {
    let project: String
    let task: PhrenTask
    var id: String { "\(project)/\(task.stableId ?? task.id)" }
}

/// Cross-project task list, also reused project-scoped inside project detail.
struct TaskListView: View {
    let projectFilter: String?

    @Environment(AppModel.self) private var model
    @State private var section: PhrenTask.Section = .active
    @State private var selectedProject: String?
    @State private var showAdd = false
    @State private var editing: TaskListRow?

    private var effectiveProject: String? {
        projectFilter ?? selectedProject
    }

    private var rows: [TaskListRow] {
        var result: [TaskListRow] = []
        for (project, doc) in model.snapshot.tasks.sorted(by: { $0.key < $1.key }) {
            if let effectiveProject, project != effectiveProject { continue }
            for task in doc.items(in: section) {
                result.append(TaskListRow(project: project, task: task))
            }
        }
        // Pinned first, then rank (tasks.ts display order).
        return result.sorted {
            if ($0.task.pinned ?? false) != ($1.task.pinned ?? false) { return $0.task.pinned ?? false }
            return ($0.task.rank ?? Int.max) < ($1.task.rank ?? Int.max)
        }
    }

    private var projectNames: [String] {
        model.snapshot.tasks.keys.sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(PhrenTask.Section.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 4)

            List {
                ForEach(rows) { row in
                    TaskRow(project: row.project, task: row.task, showProject: projectFilter == nil) {
                        Task {
                            await model.perform(.completeTask(
                                project: row.project,
                                match: row.task.stableId ?? row.task.line
                            ))
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                await model.perform(.removeTask(
                                    project: row.project,
                                    match: row.task.stableId ?? row.task.line
                                ))
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editing = row
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "Nothing in \(section.rawValue)",
                        systemImage: "checklist",
                        description: Text("Add a task with the + button.")
                    )
                }
            }
            .refreshable { await model.pullToRefresh() }
        }
        .toolbar {
            if projectFilter == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Project", selection: $selectedProject) {
                            Text("All projects").tag(String?.none)
                            ForEach(projectNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .disabled(effectiveProject == nil && projectNames.count != 1)
            }
        }
        .sheet(isPresented: $showAdd) {
            TextEntrySheet(title: "Add task", confirmLabel: "Add") { text, _ in
                let target = effectiveProject ?? projectNames.first
                if let target {
                    await model.perform(.addTask(project: target, text: text))
                }
            }
        }
        .sheet(item: $editing) { row in
            TaskEditSheet(project: row.project, task: row.task)
        }
    }
}

struct TaskRow: View {
    let project: String
    let task: PhrenTask
    let showProject: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: task.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.checked ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(task.checked)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayLine)
                    .font(.callout)
                    .strikethrough(task.checked)
                HStack(spacing: 6) {
                    if showProject {
                        TagChip(text: project, color: .blue)
                    }
                    if let priority = task.priority {
                        TagChip(text: priority.rawValue, color: priorityColor(priority))
                    }
                    if task.pinned == true {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if let issue = task.githubIssue {
                        Text("#\(issue)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let context = task.context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var displayLine: String {
        TasksFile.stripPinnedTag(TasksFile.stripPriorityTag(task.line))
    }

    private func priorityColor(_ priority: PhrenTask.Priority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .gray
        }
    }
}

struct TaskEditSheet: View {
    let project: String
    let task: PhrenTask

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var priority: PhrenTask.Priority?
    @State private var section: PhrenTask.Section

    init(project: String, task: PhrenTask) {
        self.project = project
        self.task = task
        _text = State(initialValue: TasksFile.stripPinnedTag(TasksFile.stripPriorityTag(task.line)))
        _priority = State(initialValue: task.priority)
        _section = State(initialValue: task.section)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                Picker("Priority", selection: $priority) {
                    Text("none").tag(PhrenTask.Priority?.none)
                    ForEach(PhrenTask.Priority.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(PhrenTask.Priority?.some(p))
                    }
                }
                Picker("Section", selection: $section) {
                    ForEach(PhrenTask.Section.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let newText = text
                        let newPriority = priority
                        let newSection = section != task.section ? section : nil
                        Task {
                            await model.perform(.updateTask(
                                project: project,
                                match: task.stableId ?? task.line,
                                text: newText,
                                priority: newPriority?.rawValue,
                                section: newSection?.rawValue
                            ))
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
