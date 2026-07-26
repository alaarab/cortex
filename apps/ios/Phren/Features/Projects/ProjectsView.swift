import SwiftUI
import PhrenKit

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var projects: [Project] {
        guard !filter.isEmpty else { return model.snapshot.projects }
        return model.snapshot.projects.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                List(projects) { project in
                    NavigationLink(value: project.name) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name).font(.headline)
                            HStack(spacing: 10) {
                                Label("\(project.findingCount)", systemImage: "lightbulb")
                                Label("\(project.taskCount)", systemImage: "checklist")
                                Label("\(project.noteCount)", systemImage: "note.text")
                                if project.reviewCount > 0 {
                                    Label("\(project.reviewCount)", systemImage: "checkmark.seal")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .overlay {
                    if model.snapshot.projects.isEmpty {
                        ContentUnavailableView(
                            "No projects yet",
                            systemImage: "square.grid.2x2",
                            description: Text("Projects appear here once your phren store has content.")
                        )
                    }
                }
                .searchable(text: $filter, prompt: "Filter projects")
                .refreshable { await model.pullToRefresh() }
            }
            .navigationTitle("Projects")
            .navigationDestination(for: String.self) { project in
                ProjectDetailView(project: project)
            }
        }
    }
}

struct ProjectDetailView: View {
    let project: String

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .findings

    enum Tab: String, CaseIterable {
        case findings = "Findings"
        case notes = "Notes"
        case tasks = "Tasks"
        case summary = "Summary"
    }

    var body: some View {
        VStack(spacing: 0) {
            LiveStatusBar()
            ActionErrorBanner()
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 4)

            switch tab {
            case .findings: FindingsTab(project: project)
            case .notes: NotesTab(project: project)
            case .tasks: ProjectTasksTab(project: project)
            case .summary: SummaryTab(project: project)
            }
        }
        .navigationTitle(project)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Findings

struct FindingsTab: View {
    let project: String

    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var editing: Finding?

    private var findings: [Finding] {
        model.snapshot.findings[project] ?? []
    }

    private var groupedByDate: [(date: String, items: [Finding])] {
        let groups = Dictionary(grouping: findings, by: \.date)
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        List {
            ForEach(groupedByDate, id: \.date) { group in
                Section(group.date) {
                    ForEach(group.items) { finding in
                        FindingRow(finding: finding)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await remove(finding) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editing = finding
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }
        }
        .overlay {
            if findings.isEmpty {
                ContentUnavailableView(
                    "No findings",
                    systemImage: "lightbulb",
                    description: Text("Capture your first finding with the + button.")
                )
            }
        }
        .refreshable { await model.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            TextEntrySheet(title: "Add finding", showsTypePicker: true, confirmLabel: "Add") { text, type in
                await model.perform(.addFinding(project: project, text: text, type: type?.rawValue))
            }
        }
        .sheet(item: $editing) { finding in
            TextEntrySheet(
                title: "Edit finding",
                initialText: finding.text,
                confirmLabel: "Save"
            ) { text, _ in
                await model.perform(.editFinding(
                    project: project,
                    match: finding.stableId.map { "fid:\($0)" } ?? finding.text,
                    newText: text
                ))
            }
        }
    }

    private func remove(_ finding: Finding) async {
        await model.perform(.removeFinding(
            project: project,
            match: finding.stableId.map { "fid:\($0)" } ?? finding.text
        ))
    }
}

// MARK: - Notes

struct NotesTab: View {
    let project: String

    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var editing: Note?
    @State private var promoting: Note?

    private var notes: [Note] {
        model.snapshot.notes[project] ?? []
    }

    private var groupedByDay: [(date: String, items: [Note])] {
        let groups = Dictionary(grouping: notes, by: \.date)
        return groups.keys.sorted(by: >).map { date in
            (date, groups[date]!.sorted { $0.time > $1.time })
        }
    }

    var body: some View {
        List {
            ForEach(groupedByDay, id: \.date) { group in
                Section(group.date) {
                    ForEach(group.items) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text).font(.callout)
                            HStack {
                                Text(note.time)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                if note.promoted {
                                    TagChip(text: "promoted", color: .green)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await model.perform(.removeNote(
                                        project: project, date: note.date, stableId: note.stableId
                                    ))
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { editing = note } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            if !note.promoted {
                                Button { promoting = note } label: {
                                    Label("Promote", systemImage: "arrow.up.circle")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView(
                    "No notes",
                    systemImage: "note.text",
                    description: Text("Jot down a note with the + button. Promote the good ones to findings.")
                )
            }
        }
        .refreshable { await model.pullToRefresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            TextEntrySheet(title: "Add note", confirmLabel: "Add") { text, _ in
                let now = model.nowNoteTimestamp()
                await model.perform(.addNote(project: project, date: now.date, time: now.time, text: text))
            }
        }
        .sheet(item: $editing) { note in
            TextEntrySheet(title: "Edit note", initialText: note.text) { text, _ in
                await model.perform(.editNote(
                    project: project, date: note.date, stableId: note.stableId, text: text
                ))
            }
        }
        .sheet(item: $promoting) { note in
            TextEntrySheet(
                title: "Promote to finding",
                initialText: note.text,
                showsTypePicker: true,
                confirmLabel: "Promote"
            ) { _, type in
                // promoteNote uses the note's text verbatim (core/note.ts:24);
                // only the type is chosen here.
                await model.perform(.promoteNote(
                    project: project, date: note.date,
                    stableId: note.stableId, findingType: type?.rawValue
                ))
            }
        }
    }
}

// MARK: - Project tasks + summary

struct ProjectTasksTab: View {
    let project: String
    @Environment(AppModel.self) private var model

    var body: some View {
        TaskListView(projectFilter: project)
    }
}

struct SummaryTab: View {
    let project: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let summary = model.snapshot.summaries[project] {
                Text(summary)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            } else {
                ContentUnavailableView(
                    "No summary",
                    systemImage: "doc.text",
                    description: Text("This project has no summary.md yet.")
                )
                .padding(.top, 60)
            }
        }
        .refreshable { await model.pullToRefresh() }
    }
}
