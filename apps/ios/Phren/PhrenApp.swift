import SwiftUI
import PhrenKit

@main
struct PhrenApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.applyPhrenChrome()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
    @State private var selection = MainTabView.initialTab

    /// `-phren-tab <projects|review|tasks|search|settings>` opens straight to a
    /// tab. Used alongside `-phren-demo` for automated UI screenshots.
    static var initialTab: Int {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-phren-tab"), i + 1 < args.count else { return 0 }
        switch args[i + 1].lowercased() {
        case "review": return 1
        case "tasks": return 2
        case "search": return 3
        case "settings": return 4
        default: return 0
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "square.grid.2x2") }
                .tag(0)
            ReviewView()
                .tabItem { Label("Review", systemImage: "checkmark.seal") }
                .badge(model.totalReviewCount)
                .tag(1)
            TasksView()
                .tabItem { Label("Tasks", systemImage: "checklist") }
                .tag(2)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(4)
        }
    }
}
