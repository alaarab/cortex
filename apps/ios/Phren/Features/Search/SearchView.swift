import SwiftUI
import PhrenKit

struct SearchView: View {
    /// Scope bar over the index's doc kinds. "Docs" bundles summary + truth —
    /// they're both prose about the project rather than items in it.
    enum Scope: String, CaseIterable {
        case all = "All"
        case findings = "Findings"
        case notes = "Notes"
        case tasks = "Tasks"
        case review = "Review"
        case docs = "Docs"

        var kind: SearchIndex.DocKind? {
            switch self {
            case .all: return nil
            case .findings: return .finding
            case .notes: return .note
            case .tasks: return .task
            case .review: return .review
            case .docs: return nil  // summary + truth, filtered post-query
            }
        }
    }

    /// Everything a query depends on. Used as the `.task(id:)` key, so results
    /// recompute exactly when one of these changes — including indexGeneration,
    /// which moves only when the index actually rebuilt.
    private struct SearchRequest: Equatable {
        let query: String
        let store: String?
        let project: String?
        let scope: Scope
        let typeTag: String?
        let generation: Int
    }

    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// `-phren-query <text>` seeds the query at launch — search can't be typed
    /// by simctl, and screenshot automation needs populated results.
    @State private var query: String = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-phren-query"), i + 1 < args.count else { return "" }
        return args[i + 1]
    }()
    /// Store id (owner/name) — the SearchIndex attribution key.
    @State private var storeIdFilter: String?
    @State private var projectFilter: String?
    @State private var scope: Scope = .all
    @State private var typeTagFilter: String?
    @State private var results: [SearchIndex.Result] = []

    private var request: SearchRequest {
        SearchRequest(query: query, store: storeIdFilter, project: projectFilter,
                      scope: scope, typeTag: typeTagFilter,
                      generation: model.indexGeneration)
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.searchPath) {
            VStack(spacing: 0) {
                LiveStatusBar()
                List {
                    if !query.isEmpty {
                        ForEach(results) { result in
                            resultRow(result)
                        }
                    }
                }
                .overlay {
                    if query.isEmpty {
                        PhrenEmptyState(title: "Search your memory", message: "Findings, notes, tasks, review items, and docs — all searched on-device.", pose: .searching)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            .phrenScreen()
            .searchable(text: $query, prompt: "Search findings, notes, tasks…")
            .searchScopes($scope, activation: .onSearchPresentation) {
                ForEach(Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            // Debounce: results land in @State via a cancellable task keyed on
            // the full request, so typing cancels stale queries and the view
            // never recomputes results per body pass.
            .task(id: request) {
                guard !query.isEmpty else {
                    results = []
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                results = runSearch()
            }
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
                        Picker("Finding type", selection: $typeTagFilter) {
                            Text("Any type").tag(String?.none)
                            ForEach(FindingType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(String?.some(type.rawValue))
                            }
                        }
                    } label: {
                        Image(systemName: hasMenuFilter
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                            .accessibilityLabel("Filter results")
                    }
                }
            }
            .phrenRoutes()
        }
    }

    private var hasMenuFilter: Bool {
        storeIdFilter != nil || projectFilter != nil || typeTagFilter != nil
    }

    private func runSearch() -> [SearchIndex.Result] {
        var hits = model.searchIndex.search(
            query, store: storeIdFilter, project: projectFilter,
            kind: scope.kind, typeTag: typeTagFilter
        )
        if scope == .docs {
            hits = hits.filter { $0.kind == .summary || $0.kind == .truth }
        }
        return hits
    }

    /// Findings/tasks/notes/docs push in place; review results jump to the
    /// Review tab, where their approve/reject actions live.
    @ViewBuilder
    private func resultRow(_ result: SearchIndex.Result) -> some View {
        if result.kind == .review {
            Button {
                // The queue itself is the destination — its approve/reject
                // actions live there, not on a pushed screen.
                router.selectedTab = .review
            } label: {
                HStack {
                    SearchResultRow(result: result)
                    Image(systemName: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(PhrenTheme.textMuted)
                }
            }
            .buttonStyle(.plain)
        } else if let route = Route(resultId: result.id) {
            NavigationLink(value: route) {
                SearchResultRow(result: result)
            }
        } else {
            SearchResultRow(result: result)
        }
    }
}

struct SearchResultRow: View {
    let result: SearchIndex.Result

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.text)
                .font(.callout)
                .lineLimit(4)
            HStack(spacing: 6) {
                TagChip(text: result.project, role: .project)
                if model.hasMultipleStores, !result.store.isEmpty {
                    TagChip(text: model.storeName(for: result.store), role: .store)
                }
                TagChip(text: result.kind.rawValue, color: Self.kindColor(result.kind))
                if let tag = result.typeTag {
                    TagChip(text: tag, role: .type)
                }
                Spacer()
                if let date = result.date {
                    Text(date).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.kind.rawValue), \(result.project): \(result.text)")
    }

    static func kindColor(_ kind: SearchIndex.DocKind) -> Color {
        switch kind {
        case .finding: return PhrenTheme.amber
        case .note: return PhrenTheme.cyan
        case .task: return PhrenTheme.green
        case .summary: return PhrenTheme.textMuted
        case .review: return PhrenTheme.accentHover
        case .truth: return PhrenTheme.lavender
        }
    }
}
