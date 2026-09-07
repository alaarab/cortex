import PhrenKit
import PhrenLive
import SwiftUI

struct LiveSessionsView: View {
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var adding = false

    var body: some View {
        List {
            Section {
                Text("See Herdr session status from your computer's Moshi hook over SSH. Connect Tailscale on both devices when away from home.")
                    .foregroundStyle(.secondary)
            }
            Section("Computers") {
                if let preferences = try? LiveSessionPreferences.read(data) {
                    ForEach(preferences.hosts) { host in
                        NavigationLink { LiveHostView(hostID: host.id) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name)
                                    Text(host.address).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "desktopcomputer") }
                        }
                    }
                    Button("Add computer", systemImage: "plus") { adding = true }
                } else {
                    Text("Saved connections couldn't be read. They have been preserved; update phren before editing them.")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Phren reads status while a computer's session screen is visible. Moshi is optional for opening sessions. This first connection supports the hook's default Herdr server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Live sessions")
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
    let hostID: UUID

    private var preferences: LiveSessionPreferences? { try? LiveSessionPreferences.read(data) }
    private var host: LiveHost? { preferences?.hosts.first { $0.id == hostID } }

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let fresh = monitor.polling && monitor.message == nil
                        && monitor.lastUpdated.map { context.date.timeIntervalSince($0) < 25 } == true
                    Label(fresh ? "Live · refreshes every 10 seconds" : monitor.refreshing ? "Connecting…" : "Disconnected",
                          systemImage: fresh ? "circle.fill" : "wifi.slash")
                        .foregroundStyle(fresh ? .green : .secondary)
                    if let date = monitor.lastUpdated {
                        Text("Last received \(date, style: .relative) ago\(fresh ? "" : " · showing previous status")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = monitor.message { Text(message).foregroundStyle(.orange) }
                if let localError { Text(localError).foregroundStyle(.orange) }
                if let fingerprint = monitor.fingerprint, host?.fingerprint == nil {
                    Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Compare this fingerprint with the computer's SSH host key before trusting it. On the computer, run ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub (or the matching ECDSA host key).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Trust verified fingerprint") { trust(fingerprint) }
                }
                Button("Refresh now", systemImage: "arrow.clockwise") { refreshID = UUID() }
                    .disabled(monitor.refreshing)
            }
            if let snapshot = monitor.snapshot, let host {
                ForEach(snapshot.groups) { group in
                    Section(group.label) {
                        ForEach(group.children) { tab in
                            LiveTabRow(session: DiscoveredMoshiSession(host: host, workspaceID: group.id,
                                                                      workspaceName: group.label, tab: tab,
                                                                      workspaceTabCount: group.children.count),
                                       stale: monitor.message != nil || !monitor.polling, lastUpdated: monitor.lastUpdated)
                        }
                    }
                }
                if snapshot.groups.isEmpty {
                    Text("No Herdr workspaces are running on this computer.").foregroundStyle(.secondary)
                }
            }
            if (preferences?.hosts.count ?? 0) > 1 {
                Section {
                    Text("If Moshi has sessions on several computers, make this computer's session active there first. Moshi's links cannot select a computer directly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(host?.name ?? "Computer removed")
        .navigationBarTitleDisplayMode(.inline)
        .phrenScreen()
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
        .task(id: PollIdentity(host: host, active: scenePhase == .active && !editing, refresh: refreshID)) {
            guard scenePhase == .active, !editing, let host else { return }
            await monitor.run(host: host)
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

private struct LiveTabRow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("sessions.live.preferences.v1") private var data = Data()
    @State private var assigning = false
    let session: DiscoveredMoshiSession
    let stale: Bool
    let lastUpdated: Date?
    private var hostID: UUID { session.host.id }
    private var tab: MoshiWorkspaces.Tab { session.tab }
    private var preferences: LiveSessionPreferences? { try? LiveSessionPreferences.read(data) }
    private var mapping: LiveSessionPreferences.Mapping? { preferences?.mapping(hostID: hostID, cwd: tab.cwd) }
    private var match: SessionProjectMatch? {
        preferences?.projectMatch(hostID: hostID, cwd: tab.cwd, projects: model.sessionProjects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tab.label).font(.headline).lineLimit(2)
                Spacer()
                Text(tab.status + (stale ? " · stale" : "")).font(.caption)
                    .foregroundStyle(!stale && tab.status == "Working" ? .green : .secondary)
            }
            if let agent = tab.agent {
                Text(agent + ((tab.agentPaneCount ?? 0) > 1 ? " · \(tab.agentPaneCount!) agent panes in this tab" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let cwd = tab.cwd { Text(cwd).font(.caption.monospaced()).foregroundStyle(.secondary) }
            if let match {
                let project = match.project
                if model.sessionProjects.contains(project) {
                    NavigationLink {
                        GraphView(focusProject: project.name, initialStoreId: project.storeID)
                    } label: {
                        Label("\(project.name) · \(project.storeID)", systemImage: "circle.hexagongrid")
                    }
                    .accessibilityIdentifier("live-graph:\(project.storeID):\(project.name)")
                } else {
                    Text("Linked project is unavailable: \(project.storeID)/\(project.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let destination = try? session.link().url() {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    MoshiSessionOpenLink(destination: destination, workspaceName: session.workspaceName)
                        .accessibilityIdentifier("live-open:\(session.workspaceID):\(tab.id)")
                        .disabled(stale || lastUpdated.map { context.date.timeIntervalSince($0) >= 25 } != false)
                }
            }
            if tab.cwd != nil {
                Button(match == nil ? "Link to project" : "Change project link") { assigning = true }
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $assigning) {
            NavigationStack { LiveProjectPicker(hostID: hostID, cwd: tab.cwd ?? "", existing: mapping) }
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
        List {
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
