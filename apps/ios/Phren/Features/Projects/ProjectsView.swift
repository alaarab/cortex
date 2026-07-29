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
                                        .foregroundStyle(PhrenTheme.orange)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .phrenRow()
                }
                .overlay {
                    if model.mergedProjects.isEmpty {
                        if model.syncStatus.lastError != nil {
                            // Empty AND failing to sync is a problem, not a
                            // blank slate — say so.
                            PhrenEmptyState(title: "Can't reach your store",
                                            message: "Sync is failing — check the status bar above. Your projects will appear once a sync succeeds.",
                                            pose: .concerned)
                        } else {
                            PhrenEmptyState(title: "No projects yet", message: "Projects appear here once your phren store has content.")
                        }
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
            case .docs: DocsTab(storeId: storeId, project: project)
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
    @State private var showArchived = false

    private var findings: [Finding] {
        let all = model.findings(storeId: storeId, project: project)
        return showArchived ? all : all.filter { !$0.archived }
    }

    private var hasArchived: Bool {
        model.findings(storeId: storeId, project: project).contains(where: \.archived)
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
                        NavigationLink(value: Route.finding(
                            storeId: storeId, project: project,
                            ref: finding.stableId ?? finding.id
                        )) {
                            FindingRow(finding: finding)
                                .opacity(finding.archived ? 0.55 : 1)
                        }
                            .id(finding.stableId ?? finding.id)
                            .listRowBackground(
                                (finding.stableId ?? finding.id) == highlighted
                                    ? PhrenTheme.accent.opacity(0.18) : PhrenTheme.surface
                            )
                            .listRowSeparatorTint(PhrenTheme.border)
                            .swipeActions(edge: .trailing) {
                                // The kit throws archivedReadOnly on archived
                                // mutations; don't offer what can't succeed.
                                if !finding.archived {
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
                            // Swipes are invisible to VoiceOver; expose the
                            // same verbs on the rotor.
                            .accessibilityAction(named: "Edit") {
                                if !finding.archived { editing = finding }
                            }
                            .accessibilityAction(named: "Delete") {
                                if !finding.archived { Task { await remove(finding) } }
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
            if hasArchived {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showArchived.toggle() }
                    } label: {
                        Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                    }
                    .accessibilityLabel(showArchived ? "Hide archived findings" : "Show archived findings")
                }
            }
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
                        NoteRow(note: note)
                        .id(note.stableId)
                        .listRowBackground(
                            note.stableId == highlighted ? PhrenTheme.accent.opacity(0.18) : PhrenTheme.surface
                        )
                        .listRowSeparatorTint(PhrenTheme.border)
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
                        .accessibilityAction(named: "Edit") { editing = note }
                        .accessibilityAction(named: "Delete") {
                            Task {
                                await model.perform(.removeNote(
                                    project: project, date: note.date, stableId: note.stableId
                                ), in: storeId)
                            }
                        }
                        .accessibilityAction(named: "Promote to finding") {
                            if !note.promoted { promoting = note }
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

/// The project's prose: summary.md, truths.md, and CLAUDE.md behind one
/// segment — six top-level segments don't fit an iPhone, and all three are
/// read-only renders of the same shape.
struct DocsTab: View {
    enum Doc: String, CaseIterable {
        case summary = "Summary"
        case truths = "Truths"
        case claude = "CLAUDE.md"
    }

    let storeId: String
    let project: String

    @Environment(AppModel.self) private var model
    @State private var doc: Doc = .summary

    private func content(of doc: Doc) -> String? {
        switch doc {
        case .summary: return model.summary(storeId: storeId, project: project)
        case .truths: return model.truths(storeId: storeId, project: project)
        case .claude: return model.claudeDoc(storeId: storeId, project: project)
        }
    }

    /// Only docs that exist get a menu entry; an empty menu means no docs.
    private var available: [Doc] {
        Doc.allCases.filter { content(of: $0) != nil }
    }

    var body: some View {
        ScrollView {
            if let text = content(of: doc) {
                Text(text)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            } else {
                PhrenEmptyState(title: "No docs yet",
                                message: "summary.md, truths.md, and CLAUDE.md appear here once the store has them.",
                                pose: .resting)
                .padding(.top, 60)
            }
        }
        .refreshable { await model.pullToRefresh() }
        .phrenScreen()
        .toolbar {
            if available.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Document", selection: $doc) {
                            ForEach(available, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(doc.rawValue).font(.caption)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }
                    .accessibilityLabel("Choose document")
                }
            }
        }
        .onAppear {
            // Land on the first doc that exists rather than an empty Summary.
            if content(of: doc) == nil, let first = available.first { doc = first }
        }
    }
}
