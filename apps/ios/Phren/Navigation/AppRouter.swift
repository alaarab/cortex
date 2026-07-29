import SwiftUI
import PhrenKit

enum AppTab: Int, Hashable {
    case projects, review, tasks, search, settings
}

/// The one route grammar for every push in the app. Views push `Route` values;
/// `phrenRoutes()` maps them to destinations.
///
/// Rule: destination views must resolve their data through AppModel's
/// *per-store* accessors (`findings(storeId:project:)` …), never the merged
/// ones — `mergedProjects` is narrowed by the global store filter, so a route
/// into a filtered-out store would silently fail to resolve.
enum Route: Hashable {
    case project(storeId: String, project: String,
                 section: ProjectDetailView.Tab = .findings, scrollTo: String? = nil)
    case finding(storeId: String, project: String, ref: String)
    case task(storeId: String, project: String, ref: String)

    /// Parses the SearchIndex result-id grammar: `f:<store>:<project>:<ref>`,
    /// and likewise `t:` (task), `n:` (note), `s:` (summary), `u:` (truth),
    /// `r:` (review). Splitting on ":" is safe — store ids are `owner/name`
    /// and contain "/", never ":".
    ///
    /// Kinds without their own detail surface map onto the project route:
    /// notes scroll to the note, summary/truth open the Docs section.
    init?(resultId: String) {
        let parts = resultId.split(separator: ":", maxSplits: 3).map(String.init)
        guard parts.count == 4 else { return nil }
        let (kind, store, project, ref) = (parts[0], parts[1], parts[2], parts[3])
        switch kind {
        case "f": self = .finding(storeId: store, project: project, ref: ref)
        case "t": self = .task(storeId: store, project: project, ref: ref)
        case "n": self = .project(storeId: store, project: project, section: .notes, scrollTo: ref)
        case "s", "u": self = .project(storeId: store, project: project, section: .docs)
        default: return nil
        }
    }

    /// The project this route lives in, used to seed a sensible Back stack.
    var projectRoute: Route {
        switch self {
        case .project(let storeId, let project, _, _),
             .finding(let storeId, let project, _),
             .task(let storeId, let project, _):
            return .project(storeId: storeId, project: project)
        }
    }
}

/// App-level navigation state: the selected tab plus one NavigationPath per
/// tab. Deliberately separate from AppModel — routes carry ids; destinations
/// resolve data through AppModel, so neither needs the other.
@Observable @MainActor
final class AppRouter {
    var selectedTab: AppTab
    var projectsPath: [Route] = []
    var reviewPath: [Route] = []
    var tasksPath: [Route] = []
    var searchPath: [Route] = []

    /// `-phren-tab <projects|review|tasks|search|settings>` opens a tab;
    /// `-phren-route <resultId>` opens straight onto an item (screenshot
    /// automation, and the shape Spotlight/quick actions will reuse).
    init(launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        var tab = AppTab.projects
        if let i = launchArguments.firstIndex(of: "-phren-tab"), i + 1 < launchArguments.count {
            switch launchArguments[i + 1].lowercased() {
            case "review": tab = .review
            case "tasks": tab = .tasks
            case "search": tab = .search
            case "settings": tab = .settings
            default: break
            }
        }
        selectedTab = tab
        if let i = launchArguments.firstIndex(of: "-phren-route"), i + 1 < launchArguments.count,
           let route = Route(resultId: launchArguments[i + 1]) {
            selectedTab = .projects
            projectsPath = Self.stack(for: route)
        }
    }

    /// Switches tab and replaces that tab's stack with the route (item routes
    /// get their project pushed underneath, so Back lands on the project).
    func open(_ route: Route, in tab: AppTab = .projects) {
        selectedTab = tab
        let stack = Self.stack(for: route)
        switch tab {
        case .projects: projectsPath = stack
        case .review: reviewPath = stack
        case .tasks: tasksPath = stack
        case .search: searchPath = stack
        case .settings: break
        }
    }

    private static func stack(for route: Route) -> [Route] {
        if case .project = route { return [route] }
        return [route.projectRoute, route]
    }
}

/// Resolves a pushed `Route` to its destination view.
struct RouteDestinationView: View {
    let route: Route

    var body: some View {
        switch route {
        case .project(let storeId, let project, let section, let scrollTo):
            ProjectDetailView(storeId: storeId, project: project,
                              initialSection: section, scrollTo: scrollTo)
        case .finding(let storeId, let project, let ref):
            FindingDetailView(storeId: storeId, project: project, ref: ref)
        case .task(let storeId, let project, let ref):
            TaskDetailView(storeId: storeId, project: project, ref: ref)
        }
    }
}

/// The item a route pointed at no longer exists (deleted remotely between
/// index and tap, or the ref never resolved).
struct RouteUnresolvedView: View {
    var body: some View {
        PhrenEmptyState(
            title: "Not here anymore",
            message: "This item was changed or removed since it was indexed.",
            pose: .concerned
        )
        .phrenScreen()
    }
}

extension View {
    /// Registers the app-wide route table. Apply at the root of each tab's
    /// NavigationStack.
    func phrenRoutes() -> some View {
        navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
    }
}
