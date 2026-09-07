import Foundation

public struct SessionProject: Hashable, Sendable {
    public let storeID: String
    public let name: String
    public init(storeID: String, name: String) { self.storeID = storeID; self.name = name }
}

public struct SessionProjectMatch: Equatable, Sendable {
    public let project: SessionProject
    public let directory: String
    public let automatic: Bool
}

extension LiveSessionPreferences {
    /// Explicit directory choices win, including unavailable projects. Otherwise
    /// use the deepest directory component naming exactly one attached project.
    /// A label or agent conversation ID is never evidence of project identity.
    public func projectMatch(hostID: UUID, cwd: String?, projects: [SessionProject]) -> SessionProjectMatch? {
        guard hosts.contains(where: { $0.id == hostID }),
              let cwd, let directory = try? Self.normalizedDirectory(cwd) else { return nil }
        if let saved = mapping(hostID: hostID, cwd: directory) {
            return SessionProjectMatch(project: SessionProject(storeID: saved.storeID, name: saved.project),
                                       directory: saved.directory, automatic: false)
        }
        var parts = directory.split(separator: "/").map(String.init)
        while !parts.isEmpty {
            let matches = Set(projects.filter { $0.name != "global" && $0.name.caseInsensitiveCompare(parts.last!) == .orderedSame })
            if !matches.isEmpty {
                guard matches.count == 1, let project = matches.first else { return nil }
                return SessionProjectMatch(project: project, directory: "/" + parts.joined(separator: "/"), automatic: true)
            }
            parts.removeLast()
        }
        return nil
    }
}

/// The tab selected on a known computer. Its destination comes from the hook's
/// workspace and (when needed) tab IDs, never the agent `sessionId` or label.
public struct DiscoveredMoshiSession: Equatable, Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let hostID: UUID
        public let workspace: String
        public let tab: String
    }
    public let host: LiveHost
    public let workspaceID: String
    public let workspaceName: String
    public let workspaceTabCount: Int?
    public let tab: MoshiWorkspaces.Tab
    public var id: ID { ID(hostID: host.id, workspace: workspaceID, tab: tab.id) }

    public init(host: LiveHost, workspaceID: String, workspaceName: String, tab: MoshiWorkspaces.Tab,
                workspaceTabCount: Int? = nil) {
        self.host = host; self.workspaceID = workspaceID; self.workspaceName = workspaceName; self.tab = tab
        self.workspaceTabCount = workspaceTabCount
    }

    public func link() throws -> MoshiSessionLink {
        guard !workspaceID.isEmpty, !tab.id.isEmpty,
              workspaceID == workspaceID.trimmingCharacters(in: .whitespacesAndNewlines),
              tab.id == tab.id.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw PhrenKitError.validation("This session has no usable workspace or tab destination.")
        }
        // On a one-tab workspace the workspace identifies the entire target.
        // Avoid Moshi's extra tab-refinement transition after resuming a card.
        // Unknown counts retain exact tab selection; never infer from the label.
        return try MoshiSessionLink(multiplexer: .herdr, session: "", workspace: workspaceID,
                                    tab: workspaceTabCount == 1 ? "" : tab.id)
    }

    /// Moshi's public link has no host selector. Workspace IDs can be reused on
    /// other computers, so a known collision must not trigger an automatic open.
    public func hasHostCollision(in sessions: [Self]) -> Bool {
        sessions.contains { $0.host.id != host.id && $0.workspaceID == workspaceID }
    }
}

extension MoshiWorkspaces {
    public func sessions(on host: LiveHost) -> [DiscoveredMoshiSession] {
        groups.flatMap { group in
            group.children.map { DiscoveredMoshiSession(host: host, workspaceID: group.id, workspaceName: group.label,
                                                       tab: $0, workspaceTabCount: group.children.count) }
        }
    }
}
