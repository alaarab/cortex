import SwiftUI
import PhrenKit

/// Cross-store, cross-project review queue: approve / reject / edit pending
/// findings with the exact semantics of access.ts:700-749, routed to the
/// store each item came from.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var projectFilter: String?
    @State private var flaggedOnly = false
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var editing: StoreQueueEntry?

    private var items: [StoreQueueEntry] {
        model.mergedReviewQueue.filter { item in
            if let projectFilter, item.entry.project != projectFilter { return false }
            if flaggedOnly, !item.entry.item.risky { return false }
            return true
        }
    }

    private var projectNames: [String] {
        Array(Set(model.mergedReviewQueue.map(\.entry.project))).sorted()
    }

    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var model = model
        @Bindable var router = router
        NavigationStack(path: $router.reviewPath) {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                List(selection: $selection) {
                    ForEach(QueueItem.Section.allCases, id: \.self) { section in
                        let sectionItems = items.filter { $0.entry.item.section == section }
                        if !sectionItems.isEmpty {
                            Section(section.rawValue) {
                                ForEach(sectionItems) { entry in
                                    ReviewRow(entry: entry, showStore: model.hasMultipleStores)
                                        .tag(entry.id)
                                        .swipeActions(edge: .leading) {
                                            Button {
                                                Task { await approve([entry]) }
                                            } label: {
                                                Label("Approve", systemImage: "checkmark")
                                            }
                                            .tint(.green)
                                        }
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                Task { await reject([entry]) }
                                            } label: {
                                                Label("Reject", systemImage: "xmark")
                                            }
                                            Button { editing = entry } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            .tint(.blue)
                                        }
                                }
                            }
                        }
                    }
                }
                .environment(\.editMode, $editMode)
                .overlay {
                    if items.isEmpty {
                        PhrenEmptyState(title: "Review queue is clear", message: "Auto-captured findings land here for approval.", pose: .celebrate)
                    }
                }
                .refreshable { await model.pullToRefresh() }
        .phrenScreen()

                if editMode == .active && !selection.isEmpty {
                    batchBar
                }
            }
            .navigationTitle("Review")
            .phrenRoutes()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Project", selection: $projectFilter) {
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
                        Toggle("Flagged only", isOn: $flaggedOnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .accessibilityLabel("Filter review queue")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                            if editMode == .inactive { selection.removeAll() }
                        }
                    }
                }
            }
            .sheet(item: $editing) { entry in
                TextEntrySheet(
                    title: "Edit before approving",
                    initialText: entry.entry.item.text,
                    confirmLabel: "Save"
                ) { text, _ in
                    await model.perform(
                        .editQueue(project: entry.entry.project, line: entry.entry.item.line, newText: text),
                        in: entry.storeId
                    )
                }
            }
        }
    }

    private var batchBar: some View {
        HStack {
            Text("\(selection.count) selected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reject", role: .destructive) {
                Task { await reject(selectedEntries()) }
            }
            Button("Approve") {
                Task { await approve(selectedEntries()) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.bar)
    }

    private func selectedEntries() -> [StoreQueueEntry] {
        items.filter { selection.contains($0.id) }
    }

    private func approve(_ entries: [StoreQueueEntry]) async {
        for entry in entries {
            await model.perform(
                .approveQueue(project: entry.entry.project, line: entry.entry.item.line),
                in: entry.storeId
            )
        }
        selection.removeAll()
    }

    private func reject(_ entries: [StoreQueueEntry]) async {
        for entry in entries {
            await model.perform(
                .rejectQueue(project: entry.entry.project, line: entry.entry.item.line),
                in: entry.storeId
            )
        }
        selection.removeAll()
    }
}

struct ReviewRow: View {
    let entry: StoreQueueEntry
    let showStore: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.entry.item.text)
                .font(.callout)
            HStack(spacing: 6) {
                TagChip(text: entry.entry.project, role: .project)
                if showStore {
                    TagChip(text: entry.storeName, role: .store)
                }
                if let confidence = entry.entry.item.confidence {
                    TagChip(
                        text: String(format: "%.0f%%", confidence * 100),
                        color: confidence < 0.7 ? PhrenTheme.amber : PhrenTheme.green
                    )
                }
                if let machine = entry.entry.item.machine {
                    Text(machine).font(.caption2).foregroundStyle(.secondary)
                }
                if let model = entry.entry.item.model {
                    Text(model).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.entry.item.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(entry.entry.item.risky ? PhrenTheme.amber.opacity(0.08) : nil)
    }
}
