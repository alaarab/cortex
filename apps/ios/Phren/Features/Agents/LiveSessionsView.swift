import PhrenKit
import PhrenLive
import SwiftUI

struct LiveSessionsView: View {
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var adding = false

    var body: some View {
        PhrenList {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "waveform.path")
                        .font(.title2).foregroundStyle(PhrenTheme.cyan)
                        .accessibilityHidden(true)
                    Text("Your agents, within reach")
                        .font(.title2.weight(.semibold))
                    Text("See what's running on your computers and continue a session in Moshi.")
                        .font(.subheadline).foregroundStyle(PhrenTheme.textMuted)
                        .accessibilityIdentifier("agents-introduction")
                }
                .padding(.vertical, 12)
            }
            Section {
                if let preferences = try? LiveSessionPreferences.read(data) {
                    ForEach(preferences.hosts) { host in
                        NavigationLink { LiveHostView(hostID: host.id) } label: {
                            PhrenMenuRow(title: host.name, subtitle: host.address, icon: "desktopcomputer")
                        }
                        .accessibilityIdentifier("live-host:\(host.id)")
                    }
                    Button("Add computer", systemImage: "plus") { adding = true }
                } else {
                    Text("Saved connections couldn't be read. They have been preserved; update phren before editing them.")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Computers")
            } footer: {
                Text("Keep Tailscale connected on both devices when you're away. Moshi is optional.")
            }
            Section("Agent setup") {
                NavigationLink { SkillsView() } label: {
                    PhrenMenuRow(title: "Skills", icon: "wand.and.stars", color: PhrenTheme.lavender)
                }
                NavigationLink { AgentsView() } label: {
                    PhrenMenuRow(title: "Agent instructions", icon: "person.crop.rectangle.stack")
                }
            }
        }
        .navigationTitle("Live sessions")
        // Keep the title in the navigation bar rather than the collapsible
        // large-title region when this list is hosted directly by a tab.
        .navigationBarTitleDisplayMode(.inline)
        .phrenScreen()
        .sheet(isPresented: $adding) { NavigationStack { LiveHostEditor() } }
    }
}

@Observable @MainActor
final class LiveHostMonitor {
    var snapshot: MoshiWorkspaces?
    var lastUpdated: Date?
    var message: String?
    var fingerprint: String?
    var refreshing = false
    var polling = false
    private var generation = UUID()

    func run(host: LiveHost) async {
        let run = UUID()
        generation = run
        polling = true
        defer { if generation == run { polling = false; refreshing = false } }
        while !Task.isCancelled {
            refreshing = true
            do {
                let value = try await Self.fetch(host, previousUpdate: lastUpdated)
                try Task.checkCancellation()
                guard generation == run else { return }
                snapshot = value
                lastUpdated = Date()
                message = nil
                fingerprint = nil
            } catch {
                guard !Task.isCancelled, generation == run else { return }
                message = (error as? LiveConnectionError)?.localizedDescription
                    ?? (error as? PhrenKitError)?.localizedDescription
                    ?? "Couldn't reach the computer. Check the address, Tailscale, SSH, and moshi-hook."
                if case LiveConnectionError.untrustedHost(let key) = error { fingerprint = key }
            }
            refreshing = false
            if fingerprint != nil { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }

    static func fetch(_ host: LiveHost, previousUpdate: Date? = nil) async throws -> MoshiWorkspaces {
        #if DEBUG && targetEnvironment(simulator)
        if AppModel.isUITesting && ProcessInfo.processInfo.arguments.contains("--automatic-sessions-fixture") {
            if ProcessInfo.processInfo.arguments.contains("--session-discovery-offline") { throw LiveConnectionError.disconnected }
            if ProcessInfo.processInfo.arguments.contains("--session-details-fixture") {
                if previousUpdate != nil && ProcessInfo.processInfo.arguments.contains("--session-details-removed") {
                    return try MoshiWorkspaces.read(Data(#"{"kind":"herdr","groups":[]}"#.utf8))
                }
                return try MoshiWorkspaces.read(Data(#"{"kind":"herdr","groups":[{"id":"w7","label":"Phone work","children":[{"id":"w7:t9","label":"1","title":"Polish the phone app","agent":"codex","agentStatus":"working","cwd":"/work/phone/src","agentPaneCount":2,"paneCount":3}]},{"id":"w8","label":"Other work","children":[{"id":"w8:t1","label":"1","title":"Choose the deployment target","agent":"claude","agentStatus":"waiting","cwd":"/work/other"}]},{"id":"w9","label":"Shell","children":[{"id":"w9:t1","label":"1"}]}]}"#.utf8))
            }
            if ProcessInfo.processInfo.arguments.contains("--observed-live-session-ids") {
                // Match the reported shape: every workspace's first tab is
                // labelled "1", IDs include uppercase letters, and order changes.
                var groups = [
                    #"{"id":"w7","label":"Phone work","children":[{"id":"w7:t1","label":"1","cwd":"/work/phone"}]}"#,
                    #"{"id":"wC","label":"Other work","children":[{"id":"wC:t1","label":"1","cwd":"/work/other"}]}"#,
                    #"{"id":"w2","label":"Third work","children":[{"id":"w2:t1","label":"1","cwd":"/work/third"}]}"#,
                ]
                if previousUpdate != nil { groups.reverse() }
                return try MoshiWorkspaces.read(Data((#"{"kind":"herdr","groups":["# + groups.joined(separator: ",") + "]}").utf8))
            }
            let extra = ProcessInfo.processInfo.arguments.contains("--multiple-project-sessions")
                ? #",{"id":"w7:t10","label":"Review phone changes","agent":"claude","agentStatus":"waiting","cwd":"/work/phone"}"# : ""
            return try MoshiWorkspaces.read(Data((#"{"kind":"herdr","groups":[{"id":"w7","label":"Phone work","children":[{"id":"w7:t9","label":"Build phone app","agent":"codex","agentStatus":"working","cwd":"/work/phone/src","sessionId":"not-a-server"}"# + extra + #"]},{"id":"w8","label":"Other work","children":[{"id":"w8:t1","label":"Unrelated session","cwd":"/work/other"}]}]}"#).utf8))
        }
        if AppModel.isUITesting && ProcessInfo.processInfo.arguments.contains("--live-sessions-fixture") {
            if previousUpdate != nil && ProcessInfo.processInfo.arguments.contains("--live-sessions-offline") {
                throw LiveConnectionError.disconnected
            }
            return try MoshiWorkspaces.read(Data(#"{"kind":"herdr","groups":[{"id":"w1","label":"Phone project","children":[{"id":"w1:t1","label":"Build graph","agent":"codex","agentStatus":"working","cwd":"/work/demo","agentPaneCount":1}]}]}"#.utf8))
        }
        #endif
        return try await MoshiConnection.fetch(host: host, privateKey: DeviceSSHKey.load(host.id))
    }
}

private struct LiveHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var monitor = LiveHostMonitor()
    @State private var editing = false
    @State private var refreshID = UUID()
    @State private var localError: String?
    @State private var query = ""
    @State private var mode: SessionViewMode = .workspaces
    @State private var selected: DiscoveredMoshiSession?
    let hostID: UUID

    private enum SessionViewMode: String, CaseIterable {
        case workspaces = "Workspaces", activity = "Activity"
    }
    private var preferences: LiveSessionPreferences? { try? LiveSessionPreferences.read(data) }
    private var host: LiveHost? { preferences?.hosts.first { $0.id == hostID } }
    private var sessions: [DiscoveredMoshiSession] {
        guard let host else { return [] }
        return monitor.snapshot?.sessions(on: host) ?? []
    }
    private var visible: [DiscoveredMoshiSession] {
        sessions.filter { session in
            let project = preferences?.projectMatch(hostID: hostID, cwd: session.tab.cwd, projects: model.sessionProjects)
            return session.matches(query, projectName: project?.project.name)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                connectionCard
                if monitor.snapshot != nil && host != nil {
                    Picker("Session view", selection: $mode) {
                        ForEach(SessionViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)

                    if visible.isEmpty {
                        PhrenEmptyState(title: sessions.isEmpty ? "No sessions running" : "No matching sessions",
                                        message: sessions.isEmpty ? "Open a workspace on this computer to see it here." : "Try a title, project, agent, or folder name.")
                            .frame(maxWidth: .infinity)
                    } else {
                        switch mode {
                        case .workspaces:
                            ForEach(monitor.snapshot?.groups ?? []) { group in
                                let entries = visible.filter { $0.workspaceID == group.id }
                                if !entries.isEmpty {
                                    sectionHeading(group.label, count: entries.count)
                                    sessionCards(entries)
                                }
                            }
                        case .activity:
                            ForEach(MoshiWorkspaces.Tab.Activity.allCases, id: \.self) { activity in
                                let entries = visible.filter { $0.tab.activity == activity }
                                if !entries.isEmpty {
                                    sectionHeading(activity.rawValue, count: entries.count)
                                    sessionCards(entries)
                                }
                            }
                        }
                    }
                }
                if (preferences?.hosts.count ?? 0) > 1 {
                    Text("If Moshi has sessions on several computers, make this computer's session active there first. Moshi's links cannot select a computer directly.")
                        .font(.caption).foregroundStyle(PhrenTheme.textMuted)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 18)
        }
        .background(PhrenTheme.bg)
        .navigationTitle(host?.name ?? "Computer removed")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar { Button("Connection settings", systemImage: "gearshape") { editing = true }.disabled(host == nil) }
        .onChange(of: host) { _, value in
            if value == nil {
                monitor.snapshot = nil
                monitor.lastUpdated = nil
                monitor.message = nil
                monitor.fingerprint = nil
            }
        }
        .sheet(isPresented: $editing) {
            if let host { NavigationStack { LiveHostEditor(existing: host) } }
        }
        .sheet(item: $selected) { selection in
            LiveSessionDetailView(sessionID: selection.id, monitor: monitor)
        }
        .task(id: PollIdentity(host: host, active: scenePhase == .active && !editing, refresh: refreshID)) {
            guard scenePhase == .active, !editing, let host else { return }
            await monitor.run(host: host)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = monitor.isFresh(at: context.date)
                    VStack(alignment: .leading, spacing: 5) {
                        Label(fresh ? "Live" : monitor.refreshing ? "Connecting…" : "Disconnected",
                              systemImage: fresh ? "dot.radiowaves.left.and.right" : "wifi.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(fresh ? PhrenTheme.cyan : PhrenTheme.textMuted)
                        if let date = monitor.lastUpdated {
                            Text("Last received \(date, style: .relative) ago\(fresh ? "" : " · showing previous status")")
                                .font(.caption).foregroundStyle(PhrenTheme.textMuted)
                        }
                    }
                }
                Spacer(minLength: 8)
                Button { refreshID = UUID() } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                        .background(PhrenTheme.surfaceRaised, in: Circle())
                }
                .accessibilityLabel("Refresh now").disabled(monitor.refreshing)
            }
            if monitor.snapshot != nil {
                Text("\(sessions.count) \(sessions.count == 1 ? "tab" : "tabs") · \(sessions.filter { $0.tab.activity == .working }.count) working · \(sessions.filter { $0.tab.activity == .waiting }.count) waiting")
                    .font(.caption).foregroundStyle(PhrenTheme.textMuted)
            }
            if let message = monitor.message { Text(message).font(.footnote).foregroundStyle(PhrenTheme.warning) }
            if let localError { Text(localError).font(.footnote).foregroundStyle(PhrenTheme.warning) }
            if let fingerprint = monitor.fingerprint, host?.fingerprint == nil {
                Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                Text("Compare this fingerprint with the computer's SSH host key before trusting it. On the computer, run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub (or the matching ECDSA host key).")
                    .font(.caption).foregroundStyle(PhrenTheme.textMuted)
                Button("Trust verified fingerprint") { trust(fingerprint) }
            }
        }
        .padding(16).phrenCard()
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(PhrenTheme.textMuted)
        .padding(.horizontal, 4).padding(.top, 10)
        .accessibilityAddTraits(.isHeader)
    }

    private func sessionCards(_ entries: [DiscoveredMoshiSession]) -> some View {
        ForEach(entries) { session in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                LiveSessionCard(session: session, fresh: monitor.isFresh(at: context.date)) { selected = session }
            }
        }
    }

    private func trust(_ fingerprint: String) {
        guard var host, host.fingerprint == nil else { return }
        do {
            host.fingerprint = fingerprint
            data = try LiveSessionPreferences.saving(host, in: data)
            monitor.fingerprint = nil
        } catch { localError = error.localizedDescription }
    }

    private struct PollIdentity: Equatable {
        let host: LiveHost?
        let active: Bool
        let refresh: UUID
    }
}

private extension LiveHostMonitor {
    func isFresh(at date: Date) -> Bool {
        polling && message == nil && lastUpdated.map { date.timeIntervalSince($0) < 25 } == true
    }
}

private extension MoshiWorkspaces.Tab.Activity {
    var color: Color {
        switch self {
        case .working: PhrenTheme.cyan
        case .waiting: PhrenTheme.warning
        case .error: PhrenTheme.danger
        case .done: PhrenTheme.success
        case .idle, .unknown: PhrenTheme.textMuted
        }
    }
    var icon: String {
        switch self {
        case .working: "bolt.fill"
        case .waiting: "pause.fill"
        case .error: "exclamationmark"
        case .done: "checkmark"
        case .idle: "moon"
        case .unknown: "questionmark"
        }
    }
}

private struct SessionStatusIcon: View {
    let activity: MoshiWorkspaces.Tab.Activity
    let fresh: Bool
    private var color: Color { fresh ? activity.color : PhrenTheme.textMuted }
    var body: some View {
        Image(systemName: activity.icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

private struct LiveSessionCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    let session: DiscoveredMoshiSession
    let fresh: Bool
    let onDetails: () -> Void
    private var match: SessionProjectMatch? {
        (try? LiveSessionPreferences.read(data))?.projectMatch(hostID: session.host.id, cwd: session.tab.cwd,
                                                            projects: model.sessionProjects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onDetails) {
                HStack(alignment: .top, spacing: 12) {
                    SessionStatusIcon(activity: session.tab.activity, fresh: fresh)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.tab.displayTitle).font(.headline).foregroundStyle(PhrenTheme.text).lineLimit(2)
                        Text([match?.project.name ?? session.workspaceName, session.tab.agent].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(PhrenTheme.textMuted).lineLimit(2)
                        Text(session.tab.status + (fresh ? "" : " · stale"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(fresh ? session.tab.activity.color : PhrenTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(PhrenTheme.textMuted)
                        .padding(.top, 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("live-detail:\(session.workspaceID):\(session.tab.id)")

            HStack(spacing: 12) {
                if let destination = try? session.link().url() {
                    MoshiSessionOpenLink(destination: destination, workspaceName: session.workspaceName)
                        .font(.subheadline.weight(.medium))
                        .tint(PhrenTheme.cyan)
                        .accessibilityIdentifier("live-open:\(session.workspaceID):\(session.tab.id)")
                        .disabled(!fresh)
                }
                Spacer(minLength: 0)
                if let project = match?.project, model.sessionProjects.contains(project) {
                    NavigationLink { GraphView(focusProject: project.name, initialStoreId: project.storeID) } label: {
                        Image(systemName: "circle.hexagongrid").frame(width: 44, height: 44)
                            .background(PhrenTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("Graph for \(project.name)")
                    .accessibilityIdentifier("live-graph:\(project.storeID):\(project.name)")
                }
            }
        }
        .padding(16)
        .phrenCard()
    }
}

private struct LiveSessionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var assigning = false
    @State private var copiedFolder = false
    let sessionID: DiscoveredMoshiSession.ID
    let monitor: LiveHostMonitor

    private var preferences: LiveSessionPreferences? { try? LiveSessionPreferences.read(data) }
    private var host: LiveHost? { preferences?.hosts.first { $0.id == sessionID.hostID } }
    private var session: DiscoveredMoshiSession? {
        guard let host else { return nil }
        return monitor.snapshot?.sessions(on: host).first { $0.id == sessionID }
    }
    private var match: SessionProjectMatch? {
        preferences?.projectMatch(hostID: sessionID.hostID, cwd: session?.tab.cwd, projects: model.sessionProjects)
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let fresh = monitor.isFresh(at: context.date)
                if let session {
                    PhrenList {
                        Section {
                            VStack(alignment: .leading, spacing: 14) {
                                SessionStatusIcon(activity: session.tab.activity, fresh: fresh)
                                Text(session.tab.displayTitle).font(.title2.weight(.semibold))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(session.tab.status + (fresh ? "" : " · stale"))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(fresh ? session.tab.activity.color : PhrenTheme.textMuted)
                                if let date = monitor.lastUpdated {
                                    Text("Last received \(date, style: .relative) ago")
                                        .font(.caption).foregroundStyle(PhrenTheme.textMuted)
                                }
                            }.padding(.vertical, 10)
                        }
                        .listRowBackground(session.tab.activity.color.opacity(0.10))
                        Section {
                            if let destination = try? session.link().url() {
                                MoshiSessionOpenLink(destination: destination, workspaceName: session.workspaceName)
                                    .accessibilityIdentifier("session-detail-open")
                                    .disabled(!fresh)
                            }
                        } footer: {
                            Text(fresh ? "In Moshi, tap the agent icon to switch between the terminal and Chat View when available."
                                 : "Reconnect this computer before opening its session in Moshi.")
                        }
                        Section("Project memory") {
                            if let project = match?.project, model.sessionProjects.contains(project) {
                                NavigationLink { ProjectDetailView(storeId: project.storeID, project: project.name) } label: {
                                    Label("Open \(project.name)", systemImage: "folder")
                                }.accessibilityIdentifier("session-detail-project")
                                NavigationLink { GraphView(focusProject: project.name, initialStoreId: project.storeID) } label: {
                                    Label("Explore graph", systemImage: "circle.hexagongrid")
                                }
                                Text(project.storeID).font(.caption).foregroundStyle(PhrenTheme.textMuted)
                            } else {
                                Text("Choose a project to connect this session to its findings, tasks, and graph.")
                                    .font(.subheadline).foregroundStyle(PhrenTheme.textMuted)
                            }
                            if session.tab.cwd != nil {
                                Button(match == nil ? "Link to project" : "Change project link") { assigning = true }
                            }
                        }
                        Section("Session") {
                            LabeledContent("Computer", value: session.host.name)
                            LabeledContent("Workspace", value: session.workspaceName)
                            LabeledContent("Tab", value: session.tab.label)
                            if let agent = session.tab.agent { LabeledContent("Agent", value: agent) }
                            if let count = session.tab.agentPaneCount, count >= 0 {
                                LabeledContent("Agent panes", value: "\(count)")
                            }
                            if let count = session.tab.paneCount, count >= 0 {
                                LabeledContent("Total panes", value: "\(count)")
                            }
                        }
                        if let cwd = session.tab.cwd {
                            Section("Folder") {
                                Text(cwd).font(.footnote.monospaced()).textSelection(.enabled)
                                Button(copiedFolder ? "Folder copied" : "Copy folder", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = cwd
                                    copiedFolder = true
                                }
                            }
                        }
                    }
                } else {
                    PhrenEmptyState(title: "Session no longer available", message: "It was closed or its computer was removed. Return to the list for current sessions.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(PhrenTheme.bg)
                }
            }
            .navigationTitle("Session details")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ArchiveRoute.self) { route in
                ArchiveBrowserView(storeId: route.storeId, project: route.project)
            }
            .navigationDestination(for: ArchiveTopicRoute.self) { route in
                ArchiveTopicView(storeId: route.storeId, topic: route.topic)
            }
            .onChange(of: session?.tab.cwd) { _, _ in
                copiedFolder = false
                assigning = false
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $assigning) {
                NavigationStack {
                    LiveProjectPicker(hostID: sessionID.hostID, cwd: session?.tab.cwd ?? "",
                                      existing: preferences?.mapping(hostID: sessionID.hostID, cwd: session?.tab.cwd))
                }
            }
        }
    }
}

private struct LiveProjectPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var error: String?
    let hostID: UUID
    let cwd: String
    let existing: LiveSessionPreferences.Mapping?

    var body: some View {
        PhrenList {
            Section {
                Text(cwd).font(.caption.monospaced())
                Text("Link this directory and its subdirectories to a project on this iPhone.").foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            ForEach(model.storeDescriptors) { store in
                Section(store.id) {
                    ForEach(model.snapshot(for: store.id).projects.filter { $0.name != "global" }, id: \.name) { project in
                        Button(project.name) { assign(storeID: store.id, project: project.name, directory: cwd) }
                            .accessibilityIdentifier("live-project:\(store.id):\(project.name)")
                    }
                }
            }
            if let existing {
                Button("Remove directory link", role: .destructive) {
                    assign(storeID: nil, project: nil, directory: existing.directory)
                }
            }
        }
        .navigationTitle("Link project")
        .toolbar { Button("Cancel") { dismiss() } }
        .phrenScreen()
    }
    private func assign(storeID: String?, project: String?, directory: String) {
        do {
            data = try LiveSessionPreferences.assigning(hostID: hostID, directory: directory,
                                                       storeID: storeID, project: project, in: data)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
