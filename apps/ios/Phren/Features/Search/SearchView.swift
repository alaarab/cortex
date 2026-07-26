import SwiftUI
import PhrenKit

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    /// Store id (owner/name) — the SearchIndex attribution key.
    @State private var storeIdFilter: String?
    @State private var projectFilter: String?
    @State private var kindFilter: SearchIndex.DocKind?

    private var results: [SearchIndex.Result] {
        model.searchIndex.search(query, store: storeIdFilter, project: projectFilter, kind: kindFilter)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LiveStatusBar()
                List {
                    if !query.isEmpty {
                        ForEach(results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.text)
                                    .font(.callout)
                                    .lineLimit(4)
                                HStack(spacing: 6) {
                                    TagChip(text: result.project, color: .blue)
                                    if model.hasMultipleStores, !result.store.isEmpty {
                                        TagChip(text: model.storeName(for: result.store), color: .indigo)
                                    }
                                    TagChip(text: result.kind.rawValue, color: kindColor(result.kind))
                                    if let tag = result.typeTag {
                                        TagChip(text: tag, color: .purple)
                                    }
                                    Spacer()
                                    if let date = result.date {
                                        Text(date).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .overlay {
                    if query.isEmpty {
                        ContentUnavailableView(
                            "Search your memory",
                            systemImage: "magnifyingglass",
                            description: Text("Findings, notes, tasks, and summaries — all searched on-device.")
                        )
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search findings, notes, tasks…")
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Project", selection: $projectFilter) {
                            Text("All projects").tag(String?.none)
                            ForEach(Array(Set(model.mergedProjects.map(\.project.name))).sorted(), id: \.self) { name in
                                Text(name).tag(String?.some(name))
                            }
                        }
                        if model.hasMultipleStores {
                            Picker("Store", selection: $storeIdFilter) {
                                Text("All stores").tag(String?.none)
                                ForEach(model.storeDescriptors) { store in
                                    Text(store.displayName).tag(String?.some(store.id))
                                }
                            }
                        }
                        Picker("Type", selection: $kindFilter) {
                            Text("Everything").tag(SearchIndex.DocKind?.none)
                            ForEach(SearchIndex.DocKind.allCases, id: \.self) { kind in
                                Text(kind.rawValue).tag(SearchIndex.DocKind?.some(kind))
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
    }

    private func kindColor(_ kind: SearchIndex.DocKind) -> Color {
        switch kind {
        case .finding: return .yellow
        case .note: return .teal
        case .task: return .green
        case .summary: return .gray
        }
    }
}
