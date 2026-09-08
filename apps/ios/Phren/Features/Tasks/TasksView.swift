import SwiftUI
import PhrenKit

struct TasksView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                TaskListView(scope: .all)
            }
            .navigationTitle("Tasks")
        }
    }
}

struct TaskListRow: Identifiable {
    let storeId: String
    let storeName: String
    let project: String
    let task: PhrenTask
    var id: String { "\(storeId)/\(project)/\(task.stableId ?? task.id)" }
}

/// Task list: cross-store + cross-project in the Tasks tab, or scoped to one
/// store's project inside project detail.
struct TaskListView: View {
    enum Scope {
        case all
        case project(storeId: String, project: String)
    }

    let scope: Scope

    @Environment(AppModel.self) private var model
    @State private var selectedProject: String?
    @State private var showAdd = false
    @State private var editing: TaskListRow?
    @State private var reading: TaskListRow?
    @State private var section: PhrenTask.Section = .active
    @State private var query = ""

    private var isProjectScoped: Bool {
        if case .project = scope { return true }
        return false
    }

    /// Scoped to a project phren never lets the phone write (`global`). The +
    /// is hidden rather than disabled: a read-only tier has no "fix your
    /// token" story, so a greyed control would only pose a question with no
    /// answer.
    private var isReadOnlyScope: Bool {
        guard case .project(_, let project) = scope else { return false }
        return LocalStore.isReadOnlyProject(project)
    }

    private func rows(in section: PhrenTask.Section) -> [TaskListRow] {
        var result: [TaskListRow] = []
        if case .project(let scopeStore, let scopeProject) = scope {
            // Project scope reads the store's snapshot directly — the global
            // store filter must not blank out a project-detail tab.
            if let doc = model.snapshot(for: scopeStore).tasks[scopeProject] {
                for task in doc.items(in: section) {
                    result.append(TaskListRow(storeId: scopeStore, storeName: model.storeName(for: scopeStore),
                                              project: scopeProject, task: task))
                }
            }
        } else {
            for (storeId, storeName, doc) in model.mergedTaskDocs {
                if let selectedProject, doc.project != selectedProject { continue }
                for task in doc.items(in: section) {
                    result.append(TaskListRow(storeId: storeId, storeName: storeName,
                                              project: doc.project, task: task))
                }
            }
        }
        // Pinned first, then rank (tasks.ts display order).
        return result.filter {
            query.isEmpty || $0.task.line.localizedCaseInsensitiveContains(query)
                || ($0.task.context?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.project.localizedCaseInsensitiveContains(query)
        }.sorted {
            if ($0.task.pinned ?? false) != ($1.task.pinned ?? false) { return $0.task.pinned ?? false }
            return ($0.task.rank ?? Int.max) < ($1.task.rank ?? Int.max)
        }
    }

    private var queueRows: [TaskListRow] { rows(in: .queue) }
    private var visibleRows: [TaskListRow] { rows(in: section) }

    private var projectNames: [String] {
        // Key paths can't traverse tuple elements — use a closure.
        Array(Set(model.mergedTaskDocs.map { $0.doc.project })).sorted()
    }

    /// Add targets: every writable (store, project) pair. Derived from the
    /// project list (not just existing task docs) so a project can receive
    /// its first task — the write path creates tasks.md if missing.
    private var addTargets: [(storeId: String, storeName: String, project: String)] {
        model.writableProjects.map { ($0.storeId, $0.storeName, $0.project.name) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Task status", selection: $section) {
                Text("Active").tag(PhrenTask.Section.active)
                Text("Backlog").tag(PhrenTask.Section.queue)
                Text("Done").tag(PhrenTask.Section.done)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            PhrenList {
                if !visibleRows.isEmpty {
                    Section("\(section == .queue ? "Backlog" : section.rawValue) · \(visibleRows.count)") {
                        taskRows(visibleRows)
                    }
                } else if section == .active && query.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "checkmark.circle")
                                .font(.title2).foregroundStyle(PhrenTheme.success)
                                .accessibilityHidden(true)
                            Text("No tasks marked active").font(.headline)
                            Text("Check Agents for live sessions, or browse the backlog for planned work.")
                                .font(.subheadline).foregroundStyle(PhrenTheme.textMuted)
                        }
                        .padding(.vertical, 10)
                        if !queueRows.isEmpty {
                            Button("View backlog (\(queueRows.count))") { section = .queue }
                        }
                        if !isProjectScoped {
                            Button("View agents") { model.selectedTab = .agents }
                        }
                    }
                }
            }
            .overlay {
                if visibleRows.isEmpty && (section != .active || !query.isEmpty) {
                    PhrenEmptyState(title: query.isEmpty ? "No \(section == .queue ? "backlog" : "completed") tasks" : "No matching tasks",
                                    message: query.isEmpty ? emptyMessage : "Try another search or task status.")
                }
            }
            .searchable(text: $query, prompt: "Search tasks")
            .refreshable { await model.pullToRefresh() }
            .phrenScreen()
        }
        .background(PhrenTheme.bg)
        .toolbar {
            if !isProjectScoped {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Project", selection: $selectedProject) {
                            Text("All projects").tag(String?.none)
                            ForEach(projectNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        if model.hasMultipleStores {
                            Picker("Store", selection: $model.storeFilter) {
                                Text("All stores").tag(String?.none)
                                ForEach(model.storeDescriptors) { store in
                                    Text(store.displayName).tag(String?.some(store.id))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                }
            }
            if !isReadOnlyScope {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .disabled(!isProjectScoped && addTargets.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddTaskSheet(scope: scope, targets: addTargets)
        }
        .sheet(item: $editing) { row in
            TaskEditSheet(row: row)
        }
        .sheet(item: $reading) { row in
            TaskDetailsSheet(row: row)
        }
    }

    /// The + button is disabled cross-store when no (store, project) pair is
    /// writable — explain why, rather than leaving the empty state silent
    /// about a control the user can see but can't press.
    private var emptyMessage: String {
        if !isProjectScoped && addTargets.isEmpty {
            return "No writable store yet — your GitHub token needs Contents: Read and write on the store repo before you can add tasks."
        }
        return "Add a task with the + button."
    }

    @ViewBuilder
    private func taskRows(_ items: [TaskListRow]) -> some View {
        ForEach(items) { row in
            TaskRow(
                row: row,
                showProject: !isProjectScoped,
                showStore: !isProjectScoped && model.hasMultipleStores,
                canWrite: model.canWrite(storeId: row.storeId, project: row.project),
                onRead: { reading = row }
            ) {
                toggle(row)
            }
            .swipeActions(edge: .leading) {
                Button {
                    toggle(row)
                } label: {
                    row.task.checked
                        ? Label("Reopen", systemImage: "arrow.uturn.backward")
                        : Label("Complete", systemImage: "checkmark")
                }
                .tint(row.task.checked ? .blue : .green)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    delete(row)
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
            .contextMenu {
                Button {
                    toggle(row)
                } label: {
                    row.task.checked
                        ? Label("Reopen", systemImage: "arrow.uturn.backward")
                        : Label("Complete", systemImage: "checkmark")
                }
                Button {
                    editing = row
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    delete(row)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Checking a Done row un-checks it back into Active — TasksFile.update
    /// already un-checks on section move, so this is just a section change,
    /// not a fresh completeTask.
    private func toggle(_ row: TaskListRow) {
        Task {
            if row.task.checked {
                await model.perform(.updateTask(
                    project: row.project,
                    match: row.task.stableId ?? row.task.line,
                    text: nil,
                    priority: nil,
                    section: PhrenTask.Section.active.rawValue
                ), in: row.storeId)
            } else {
                await model.perform(.completeTask(
                    project: row.project,
                    match: row.task.stableId ?? row.task.line
                ), in: row.storeId)
            }
        }
    }

    private func delete(_ row: TaskListRow) {
        Task {
            await model.perform(.removeTask(
                project: row.project,
                match: row.task.stableId ?? row.task.line
            ), in: row.storeId)
        }
    }
}

/// Task composer with an explicit destination picker when the target is
/// ambiguous (multiple stores/projects).
struct AddTaskSheet: View {
    struct Target: Identifiable, Hashable {
        let storeId: String
        let storeName: String
        let project: String
        var id: String { "\(storeId)|\(project)" }
    }

    let scope: TaskListView.Scope
    let targets: [Target]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selectedTarget: Target?

    init(scope: TaskListView.Scope, targets: [(storeId: String, storeName: String, project: String)]) {
        self.scope = scope
        self.targets = targets.map { Target(storeId: $0.storeId, storeName: $0.storeName, project: $0.project) }
    }

    private var fixedTarget: (storeId: String, project: String)? {
        if case .project(let storeId, let project) = scope { return (storeId, project) }
        if targets.count == 1 { return (targets[0].storeId, targets[0].project) }
        return nil
    }

    private func targetLabel(_ target: Target) -> String {
        model.hasMultipleStores ? "\(target.project) · \(target.storeName)" : target.project
    }

    var body: some View {
        NavigationStack {
            PhrenForm {
                TextField("Task", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                if fixedTarget == nil {
                    Picker("Project", selection: $selectedTarget) {
                        Text("Choose…").tag(Target?.none)
                        ForEach(targets) { target in
                            Text(targetLabel(target)).tag(Target?.some(target))
                        }
                    }
                }
            }
            .navigationTitle("Add to Backlog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        submit()
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || resolvedTarget() == nil)
                }
            }
        }
    }

    private func resolvedTarget() -> (storeId: String, project: String)? {
        if let fixedTarget { return fixedTarget }
        guard let selectedTarget else { return nil }
        return (selectedTarget.storeId, selectedTarget.project)
    }

    private func submit() {
        guard let target = resolvedTarget() else { return }
        let value = text
        Task {
            await model.perform(.addTask(project: target.project, text: value), in: target.storeId)
        }
    }
}

struct TaskRow: View {
    let row: TaskListRow
    let showProject: Bool
    let showStore: Bool
    let canWrite: Bool
    let onRead: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: row.task.checked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.task.checked ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!canWrite)
            .accessibilityLabel(row.task.checked ? "Reopen task" : "Complete task")

            Button(action: onRead) {
              VStack(alignment: .leading, spacing: 5) {
                Text(.init(displayLine))
                    .font(.callout)
                    .strikethrough(row.task.checked)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if showProject {
                        TagChip(text: row.project, role: .project)
                    }
                    if showStore {
                        TagChip(text: row.storeId, role: .store)
                    }
                    if let priority = row.task.priority {
                        TagChip(text: priority.rawValue, color: priorityColor(priority))
                    }
                    if row.task.pinned == true {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if let issue = row.task.githubIssue {
                        Text("#\(issue)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let context = row.task.context {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
              }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("task-detail:\(row.id)")
        }
        .padding(.vertical, 2)
    }

    private var displayLine: String {
        TasksFile.stripPinnedTag(TasksFile.stripPriorityTag(row.task.line))
    }

    private func priorityColor(_ priority: PhrenTask.Priority) -> Color {
        switch priority {
        case .high: return PhrenTheme.red
        case .medium: return PhrenTheme.amber
        case .low: return PhrenTheme.textDim
        }
    }
}

/// Reading a long task never opens a text editor or changes its state.
private struct TaskDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    let row: TaskListRow

    private var currentRow: TaskListRow {
        let task = model.snapshot(for: row.storeId).tasks[row.project]?.allItems.first {
            if let stableID = row.task.stableId { return $0.stableId == stableID }
            return $0.id == row.task.id
        }
        return TaskListRow(storeId: row.storeId, storeName: row.storeName,
                           project: row.project, task: task ?? row.task)
    }

    var body: some View {
        let row = currentRow
        NavigationStack {
            PhrenList {
                Section {
                    Text(.init(TasksFile.stripPinnedTag(TasksFile.stripPriorityTag(row.task.line))))
                        .textSelection(.enabled)
                }
                if let context = row.task.context {
                    Section("Context") { Text(.init(context)).textSelection(.enabled) }
                }
                Section {
                    LabeledContent("Project", value: row.project)
                    LabeledContent("Store", value: row.storeId)
                    LabeledContent("Status", value: row.task.section == .queue ? "Backlog" : row.task.section.rawValue)
                    if let priority = row.task.priority { LabeledContent("Priority", value: priority.rawValue) }
                }
            }
            .navigationTitle("Task details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if model.canWrite(storeId: row.storeId, project: row.project) {
                    ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
                }
            }
            .phrenScreen()
            .sheet(isPresented: $editing) { TaskEditSheet(row: row) }
        }
    }
}

struct TaskEditSheet: View {
    let row: TaskListRow

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var priority: PhrenTask.Priority?
    @State private var section: PhrenTask.Section
    @State private var pinned: Bool

    init(row: TaskListRow) {
        self.row = row
        _text = State(initialValue: TasksFile.stripPinnedTag(TasksFile.stripPriorityTag(row.task.line)))
        _priority = State(initialValue: row.task.priority)
        _section = State(initialValue: row.task.section)
        _pinned = State(initialValue: row.task.pinned ?? false)
    }

    var body: some View {
        NavigationStack {
            PhrenForm {
                TextField("Task", text: $text, axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Pinned", isOn: $pinned)
                Picker("Priority", selection: $priority) {
                    Text("none").tag(PhrenTask.Priority?.none)
                    ForEach(PhrenTask.Priority.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(PhrenTask.Priority?.some(p))
                    }
                }
                Picker("Section", selection: $section) {
                    ForEach(PhrenTask.Section.allCases, id: \.self) { s in
                        Text(s == .queue ? "Backlog" : s.rawValue).tag(s)
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
                        // TasksFile.update recomputes `pinned` from the text
                        // it's given, so the tag has to be re-appended here —
                        // otherwise saving silently unpins the task.
                        var newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if pinned {
                            newText += " [pinned]"
                        }
                        let newPriority = priority
                        let newSection = section != row.task.section ? section : nil
                        Task {
                            await model.perform(.updateTask(
                                project: row.project,
                                match: row.task.stableId ?? row.task.line,
                                text: newText,
                                priority: newPriority?.rawValue,
                                section: newSection?.rawValue
                            ), in: row.storeId)
                        }
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
