import SwiftUI
import PhrenKit

@main
struct PhrenApp: App {
    @State private var model = AppModel()
    @State private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.applyPhrenChrome()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .tint(PhrenTheme.accent)
                // The phren identity is dark-only (docs/style.css).
                .preferredColorScheme(.dark)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Live sync runs only while the app is visible; returning
                    // to the foreground triggers an immediate catch-up pull.
                    switch phase {
                    case .active: Task { await model.enterForeground() }
                    case .background, .inactive: Task { await model.enterBackground() }
                    @unknown default: break
                    }
                }
        }
    }

    /// Navy navigation + tab chrome matching the site's --bg/--bg-1 surfaces.
    private static func applyPhrenChrome() {
        let navy = UIColor(PhrenTheme.bg)
        let text = UIColor(PhrenTheme.text)

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = navy
        nav.titleTextAttributes = [.foregroundColor: text]
        nav.largeTitleTextAttributes = [.foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = navy
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhrenTheme.bg)
        case .signedOut, .pickingRepo, .initialSync:
            OnboardingFlow()
        case .ready:
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    // Tab selection and per-tab paths live on AppRouter so search results,
    // launch args (-phren-tab / -phren-route), and future Spotlight/quick
    // actions can all navigate programmatically.
    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(AppTab.projects)
            ReviewView()
                .tabItem { Label("Review", systemImage: "checkmark.seal") }
                .badge(model.totalReviewCount)
                .tag(AppTab.review)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(AppTab.tasks)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
