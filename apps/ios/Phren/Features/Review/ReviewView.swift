import SwiftUI
import PhrenKit

/// Cross-project review queue: approve / reject / edit pending findings.
/// Mirrors the web UI's Review tab (batch select, risky tint) with the exact
/// approve/reject/edit semantics of access.ts:700-749.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var projectFilter: String?
    @State private var flaggedOnly = false
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var editing: ProjectQueueItem?

    private var items: [ProjectQueueItem] {
        model.snapshot.reviewQueue.filter { item in
            if let projectFilter, item.project != projectFilter { return false }
            if flaggedOnly, !item.item.risky { return false }
            return true
        }
    }

    private var projectNames: [String] {
        Array(Set(model.snapshot.reviewQueue.map(\.project))).sorted()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveStatusBar()
                ActionErrorBanner()
                List(selection: $selection) {
                    ForEach(QueueItem.Section.allCases, id: \.self) { section in
                        let sectionItems = items.filter { $0.item.section == section }
                        if !sectionItems.isEmpty {
                            Section(section.rawValue) {
                                ForEach(sectionItems) { entry in
                                    ReviewRow(entry: entry)
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
                        ContentUnavailableView(
                            "Review queue is clear",
                            systemImage: "checkmark.seal",
                            description: Text("Auto-captured findings land here for approval.")
                        )
                    }
                }
                .refreshable { await model.pullToRefresh() }

                if editMode == .active && !selection.isEmpty {
                    batchBar
                }
            }
            .navigationTitle("Review")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Project", selection: $projectFilter) {
                            Text("All projects").tag(String?.none)
                            ForEach(projectNames, id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        Toggle("Flagged only", isOn: $flaggedOnly)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
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
                    initialText: entry.item.text,
                    confirmLabel: "Save"
                ) { text, _ in
                    await model.perform(.editQueue(project: entry.project, line: entry.item.line, newText: text))
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

    private func selectedEntries() -> [ProjectQueueItem] {
        items.filter { selection.contains($0.id) }
    }

    private func approve(_ entries: [ProjectQueueItem]) async {
        for entry in entries {
            await model.perform(.approveQueue(project: entry.project, line: entry.item.line))
        }
        selection.removeAll()
    }

    private func reject(_ entries: [ProjectQueueItem]) async {
        for entry in entries {
            await model.perform(.rejectQueue(project: entry.project, line: entry.item.line))
        }
        selection.removeAll()
    }
}

struct ReviewRow: View {
    let entry: ProjectQueueItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.item.text)
                .font(.callout)
            HStack(spacing: 6) {
                TagChip(text: entry.project, color: .blue)
                if let confidence = entry.item.confidence {
                    TagChip(
                        text: String(format: "%.0f%%", confidence * 100),
                        color: confidence < 0.7 ? .orange : .green
                    )
                }
                if let machine = entry.item.machine {
                    Text(machine).font(.caption2).foregroundStyle(.secondary)
                }
                if let model = entry.item.model {
                    Text(model).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.item.date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(entry.item.risky ? Color.orange.opacity(0.08) : nil)
    }
}
