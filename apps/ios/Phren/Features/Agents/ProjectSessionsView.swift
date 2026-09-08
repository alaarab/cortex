import PhrenKit
import PhrenLive
import SwiftUI

extension AppModel {
    /// Session matching includes every attached store, independent of list filters.
    var sessionProjects: [SessionProject] {
        storeDescriptors.flatMap { store in
            snapshot(for: store.id).projects.filter { $0.name != "global" }
                .map { SessionProject(storeID: store.id, name: $0.name) }
        }
    }
}

@Observable @MainActor
private final class ProjectSessionDiscovery {
    var sessions: [DiscoveredMoshiSession] = []
    var problems: [String] = []
    var refreshing = false
    var updated: Date?
    private var generation = UUID()

    func refresh(hosts: [LiveHost]) async {
        let run = UUID()
        generation = run
        refreshing = true
        defer { if generation == run { refreshing = false } }
        var found: [DiscoveredMoshiSession] = []
        var failures: [String] = []
        await withTaskGroup(of: HostResult.self) { group in
            for host in hosts {
                group.addTask {
                    guard host.fingerprint != nil else {
                        return HostResult(sessions: [], problem: "\(host.name): finish verifying the computer in Agents.")
                    }
                    do {
                        let snapshot = try await LiveHostMonitor.fetch(host)
                        return HostResult(sessions: snapshot.sessions(on: host), problem: nil)
                    } catch {
                        let message = (error as? LiveConnectionError)?.localizedDescription
                            ?? (error as? PhrenKitError)?.localizedDescription ?? "Couldn't read sessions."
                        return HostResult(sessions: [], problem: "\(host.name): \(message)")
                    }
                }
            }
            for await result in group {
                found += result.sessions
                if let problem = result.problem { failures.append(problem) }
            }
        }
        guard !Task.isCancelled, generation == run else { return }
        sessions = found.sorted { ($0.host.name, $0.workspaceName, $0.tab.label, $0.tab.id) < ($1.host.name, $1.workspaceName, $1.tab.label, $1.tab.id) }
        problems = failures.sorted()
        updated = .now
    }

    private struct HostResult: Sendable {
        let sessions: [DiscoveredMoshiSession]
        let problem: String?
    }
}

/// Opened by an explicit request to resume a project's session. Resolve once
/// before offering a handoff. Discovery cannot establish which computer Moshi
/// will use, so neither the first result nor later polls open another app.
struct ProjectSessionsView: View {
    let storeID: String
    let project: String
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var discovery = ProjectSessionDiscovery()
    @State private var checkingComputer = false
    @State private var pending: Handoff?
    @State private var visible = false
    @State private var refreshID = UUID()
    @State private var error: String?

    private var preferences: LiveSessionPreferences? { try? LiveSessionPreferences.read(data) }
    private var target: SessionProject { SessionProject(storeID: storeID, name: project) }
    private var matches: [DiscoveredMoshiSession] {
        discovery.sessions.filter {
            preferences?.projectMatch(hostID: $0.host.id, cwd: $0.tab.cwd, projects: model.sessionProjects)?.project == target
        }
    }

    var body: some View {
        NavigationStack {
            PhrenList {
                Section {
                    Text("\(project) · \(storeID)").font(.caption).foregroundStyle(.secondary)
                    if discovery.refreshing { ProgressView("Finding project sessions…") }
                    if preferences == nil {
                        Text("Saved connections couldn't be read. They have been preserved.").foregroundStyle(.orange)
                    } else if preferences?.hosts.isEmpty == true {
                        Text("Connect your computer once in Agents. Phren can then find this project's sessions for you.")
                    } else if discovery.updated != nil {
                        Text(matches.isEmpty ? "No session matched this project's directory. You can choose one below."
                             : matches.count == 1 ? "Found this project's session."
                             : "Several sessions are working in this project. Choose the one you want.")
                    }
                    ForEach(discovery.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    NavigationLink("Manage computers") { LiveSessionsView() }
                }
                if !matches.isEmpty {
                    Section("Project sessions") {
                        ForEach(matches) { session in sessionRow(session, assign: false) }
                    }
                }
                if matches.isEmpty && !discovery.sessions.isEmpty {
                    Section {
                        ForEach(discovery.sessions) { session in sessionRow(session, assign: true) }
                    } header: { Text("Choose a session") } footer: {
                        Text("Opening a chosen session remembers its directory for this project on this iPhone.")
                    }
                }
                if discovery.updated != nil && discovery.sessions.isEmpty && discovery.problems.isEmpty {
                    Text("No Herdr sessions are running on the connected computers.").foregroundStyle(.secondary)
                }
                Section {
                    Text("Phren found the computer and workspace. Moshi's public links cannot select that computer; choose it in Moshi before opening a workspace link.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Project sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh sessions", systemImage: "arrow.clockwise") { refreshID = UUID() }
                        .disabled(discovery.refreshing)
                }
            }
            .phrenScreen()
            .modifier(MoshiLaunchAlert(error: $error))
            .modifier(MoshiComputerCheck(host: pending?.session.host, destination: try? pending?.session.link().url(), isPresented: $checkingComputer) { requestedURL in
                guard let pending else { return }
                open(pending.session, assign: pending.assign, requestedURL: requestedURL)
            })
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: DiscoveryIdentity(data: data, active: visible && scenePhase == .active, refresh: refreshID)) {
                guard visible, scenePhase == .active, let preferences, !preferences.hosts.isEmpty else { return }
                while !Task.isCancelled {
                    await discovery.refresh(hosts: preferences.hosts)
                    guard !Task.isCancelled else { return }
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                }
            }
        }
    }

    private func sessionRow(_ session: DiscoveredMoshiSession, assign: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh = discovery.updated.map { context.date.timeIntervalSince($0) < 25 } == true
            Button {
                pending = Handoff(session: session, assign: assign)
                checkingComputer = true
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.tab.displayTitle).font(.headline).lineLimit(2)
                    Text("\(session.host.name) · \(session.workspaceName)").font(.caption).lineLimit(1)
                    Text("\(session.tab.agent ?? "Terminal") · \(session.tab.status)\(fresh ? "" : " · refresh needed")").font(.caption)
                    if let cwd = session.tab.cwd { Text(cwd).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if session.hasHostCollision(in: discovery.sessions) {
                        Text("Switch to \(session.host.name) in Moshi first. Moshi's links cannot distinguish these computers.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Label(assign ? "Use for \(project) and open in Moshi" : "Open in Moshi", systemImage: "arrow.up.forward.app")
                        .font(.callout).foregroundStyle(PhrenTheme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!fresh || (try? session.link()) == nil || (assign && session.tab.cwd == nil))
            .accessibilityIdentifier("discovered-session:\(session.host.id):\(session.workspaceID):\(session.tab.id)")
        }
    }

    private func open(_ session: DiscoveredMoshiSession, assign: Bool, requestedURL: URL) {
        do {
            guard scenePhase == .active, visible,
                  discovery.updated.map({ Date().timeIntervalSince($0) < 25 }) == true,
                  let current = discovery.sessions.first(where: { $0.id == session.id }),
                  current.host == session.host, current.tab.cwd == session.tab.cwd,
                  model.sessionProjects.contains(target) else {
                error = "This session changed or needs a refresh. Choose it again from the current list."
                return
            }
            let url = try current.link().url()
            guard url == requestedURL else {
                error = "This session's destination changed. Choose it again from the current list."
                return
            }
            if assign, let cwd = current.tab.cwd {
                data = try LiveSessionPreferences.assigning(hostID: session.host.id, directory: cwd,
                                                            storeID: storeID, project: project, in: data)
            }
            openURL(url) { accepted in
                if accepted { dismiss() }
                else { error = "Moshi couldn't be opened on this iPhone. Install it and open this computer's session there first." }
            }
        } catch { self.error = error.localizedDescription }
    }

    private struct Handoff {
        let session: DiscoveredMoshiSession
        let assign: Bool
    }

    private struct DiscoveryIdentity: Equatable {
        let data: Data
        let active: Bool
        let refresh: UUID
    }
}
