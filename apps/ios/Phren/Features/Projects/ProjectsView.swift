import SwiftUI
import PhrenKit

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    private var projects: [StoreProject] {
        guard !filter.isEmpty else { return model.mergedProjects }
        return model.mergedProjects.filter { $0.project.name.localizedCaseInsensitiveContains(filter) }
    }

    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var model = model
        @Bindable var router = router
        NavigationStack(path: $router.projectsPath) {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                List(projects) { item in
                    NavigationLink(value: Route.project(storeId: item.storeId, project: item.project.name)) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.project.name).font(.headline)
                                if model.hasMultipleStores {
                                    TagChip(text: item.storeName, role: .store)
                                }
                            }
                            HStack(spacing: 10) {
                                Label("\(item.project.findingCount)", systemImage: "lightbulb")
                                Label("\(item.project.taskCount)", systemImage: "checklist")
                                Label("\(item.project.noteCount)", systemImage: "note.text")
                                if item.project.reviewCount > 0 {
                                    Label("\(item.project.reviewCount)", systemImage: "checkmark.seal")
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
                    if model.mergedProjects.isEmpty {
                        PhrenEmptyState(title: "No projects yet", message: "Projects appear here once your phren store has content.")
                    }
                }
                .searchable(text: $filter, prompt: "Filter projects")
                .refreshable { await model.pullToRefresh() }
        .phrenScreen()
            }
            .navigationTitle("Projects")
            .toolbar {
                if model.hasMultipleStores {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Store", selection: $model.storeFilter) {
                                Text("All stores").tag(String?.none)
                                ForEach(model.storeDescriptors) { store in
                                    Text(store.displayName).tag(String?.some(store.id))
                                }
                            }
                        } label: {
                            Image(systemName: model.storeFilter == nil
                                  ? "line.3.horizontal.decrease.circle"
                                  : "line.3.horizontal.decrease.circle.fill")
                        }
                    }
                }
            }
            .phrenRoutes()
        }
    }
}

struct ProjectDetailView: View {
    let storeId: String
    let project: String
    /// Deep links land on a specific section, optionally scrolled to an item.
    var initialSection: Tab = .findings
    var scrollTo: String?

    @Environment(AppModel.self) private var model
    @State private var tab: Tab

    enum Tab: String, CaseIterable {
        case findings = "Findings"
        case notes = "Notes"
        case tasks = "Tasks"
        case docs = "Docs"
    }

    init(storeId: String, project: String, initialSection: Tab = .findings, scrollTo: String? = nil) {
        self.storeId = storeId
        self.project = project
        self.initialSection = initialSection
        self.scrollTo = scrollTo
        _tab = State(initialValue: initialSection)
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
            case .findings: FindingsTab(storeId: storeId, project: project, scrollTo: scrollTo)
            case .notes: NotesTab(storeId: storeId, project: project, scrollTo: scrollTo)
            case .tasks: TaskListView(scope: .project(storeId: storeId, project: project))
            case .docs: SummaryTab(storeId: storeId, project: project)
            }
        }
        .navigationTitle(model.hasMultipleStores ? "\(project) · \(model.storeName(for: storeId))" : project)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Findings

struct FindingsTab: View {
    let storeId: String
    let project: String
    var scrollTo: String?

    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var editing: Finding?
    @State private var highlighted: String?

    private var findings: [Finding] {
        // The snapshot now carries archived findings too (flagged); this tab
        // shows the live set. The archived toggle arrives with the detail-view
        // phase.
        model.findings(storeId: storeId, project: project).filter { !$0.archived }
    }

    /// Deep-link landing: scroll to the target row and flash a highlight.
    private func jumpToTarget(_ proxy: ScrollViewProxy) {
        guard let scrollTo else { return }
        withAnimation { proxy.scrollTo(scrollTo, anchor: .center) }
        highlighted = scrollTo
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { highlighted = nil }
        }
    }

    private var groupedByDate: [(date: String, items: [Finding])] {
        let groups = Dictionary(grouping: findings, by: \.date)
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(groupedByDate, id: \.date) { group in
                Section(group.date) {
                    ForEach(group.items) { finding in
                        FindingRow(finding: finding)
                            .id(finding.stableId ?? finding.id)
                            .listRowBackground(
                                (finding.stableId ?? finding.id) == highlighted
                                    ? PhrenTheme.accent.opacity(0.18) : nil
                            )
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
                PhrenEmptyState(title: "No findings", message: "Capture your first finding with the + button.")
            }
        }
        .refreshable { await model.pullToRefresh() }
        .phrenScreen()
        .onAppear { jumpToTarget(proxy) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add finding")
            }
        }
        .sheet(isPresented: $showAdd) {
            TextEntrySheet(title: "Add finding", showsTypePicker: true, confirmLabel: "Add") { text, type in
                await model.perform(.addFinding(project: project, text: text, type: type?.rawValue), in: storeId)
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
                ), in: storeId)
            }
        }
    }

    private func remove(_ finding: Finding) async {
        await model.perform(.removeFinding(
            project: project,
            match: finding.stableId.map { "fid:\($0)" } ?? finding.text
        ), in: storeId)
    }
}

// MARK: - Notes

struct NotesTab: View {
    let storeId: String
    let project: String
    var scrollTo: String?

    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var editing: Note?
    @State private var promoting: Note?
    @State private var highlighted: String?

    private var notes: [Note] {
        model.notes(storeId: storeId, project: project)
    }

    /// Deep-link landing: scroll to the target note and flash a highlight.
    private func jumpToTarget(_ proxy: ScrollViewProxy) {
        guard let scrollTo else { return }
        withAnimation { proxy.scrollTo(scrollTo, anchor: .center) }
        highlighted = scrollTo
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { highlighted = nil }
        }
    }

    private var groupedByDay: [(date: String, items: [Note])] {
        let groups = Dictionary(grouping: notes, by: \.date)
        return groups.keys.sorted(by: >).map { date in
            (date, groups[date]!.sorted { $0.time > $1.time })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
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
                                    TagChip(text: "promoted", role: .good)
                                }
                            }
                        }
                        .id(note.stableId)
                        .listRowBackground(
                            note.stableId == highlighted ? PhrenTheme.accent.opacity(0.18) : nil
                        )
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task {
                                    await model.perform(.removeNote(
                                        project: project, date: note.date, stableId: note.stableId
                                    ), in: storeId)
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
                PhrenEmptyState(title: "No notes", message: "Jot down a note with the + button. Promote the good ones to findings.")
            }
        }
        .refreshable { await model.pullToRefresh() }
        .phrenScreen()
        .onAppear { jumpToTarget(proxy) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add note")
            }
        }
        .sheet(isPresented: $showAdd) {
            TextEntrySheet(title: "Add note", confirmLabel: "Add") { text, _ in
                let now = model.nowNoteTimestamp()
                await model.perform(.addNote(project: project, date: now.date, time: now.time, text: text), in: storeId)
            }
        }
        .sheet(item: $editing) { note in
            TextEntrySheet(title: "Edit note", initialText: note.text) { text, _ in
                await model.perform(.editNote(
                    project: project, date: note.date, stableId: note.stableId, text: text
                ), in: storeId)
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
                ), in: storeId)
            }
        }
    }
}

// MARK: - Summary

struct SummaryTab: View {
    let storeId: String
    let project: String

    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let summary = model.summary(storeId: storeId, project: project) {
                Text(summary)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            } else {
                PhrenEmptyState(title: "No summary", message: "This project has no summary.md yet.", pose: .resting)
                .padding(.top, 60)
            }
        }
        .refreshable { await model.pullToRefresh() }
        .phrenScreen()
    }
}
