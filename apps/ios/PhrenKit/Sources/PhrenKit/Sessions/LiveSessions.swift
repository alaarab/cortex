import Foundation

/// The observed Moshi hook 0.3.19 workspace contract. A child is a tab;
/// it can aggregate several agent panes and is never claimed to be one agent.
public struct MoshiWorkspaces: Decodable, Equatable, Sendable {
    public struct Tab: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let title: String?
        public let agentStatus: String?
        public let agent: String?
        public let cwd: String?
        public let agentPaneCount: Int?
        public let paneCount: Int?

        public var displayTitle: String {
            let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? label : value
        }

        public enum Activity: String, CaseIterable, Sendable {
            case error = "Error", waiting = "Waiting", working = "Working"
            case idle = "Idle", done = "Done", unknown = "Unknown"
        }

        public var activity: Activity {
            switch agentStatus {
            case "working": return .working
            case "idle": return .idle
            case "done": return .done
            case "error": return .error
            case "blocked", "waiting": return .waiting
            default: return .unknown
            }
        }
        public var status: String { activity.rawValue }
    }
    public struct Group: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let children: [Tab]
    }
    public let kind: String
    public let groups: [Group]

    public static func read(_ data: Data) throws -> Self {
        guard data.count <= 1_048_576 else { throw PhrenKitError.validation("The session response is too large.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.kind == "herdr" else {
            throw PhrenKitError.validation("Live sessions currently support the Moshi hook's default Herdr server.")
        }
        var groupIDs: Set<String> = []
        for group in result.groups {
            guard !group.id.isEmpty, groupIDs.insert(group.id).inserted else {
                throw PhrenKitError.validation("The hook returned repeated or empty workspace IDs.")
            }
            var tabIDs: Set<String> = []
            for tab in group.children {
                guard !tab.id.isEmpty, tabIDs.insert(tab.id).inserted else {
                    throw PhrenKitError.validation("The hook returned repeated or empty tab IDs.")
                }
            }
        }
        return result
    }
}

public struct LiveHost: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let address: String
    public let port: Int
    public let username: String
    public var fingerprint: String?

    public init(id: UUID = UUID(), name: String, address: String, port: Int = 22,
                username: String, fingerprint: String? = nil) throws {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fingerprint = fingerprint
        try validate()
    }

    public func validate() throws {
        guard !name.isEmpty, name.count <= 100, !address.isEmpty, address.count <= 253,
              !username.isEmpty, username.count <= 100, (1...65535).contains(port),
              !address.contains("/"), !address.contains("@"),
              address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              [name, address, username].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw PhrenKitError.validation("Enter a name, SSH hostname or IP address, port from 1–65535, and username.")
        }
        if let fingerprint, fingerprint.range(of: #"^SHA256:[A-Za-z0-9+/]{43}$"#, options: .regularExpression) == nil {
            throw PhrenKitError.validation("The saved SSH host fingerprint is invalid.")
        }
    }
}

/// Device-local host settings and explicit directory → store/project mappings.
/// Credentials and observed session data do not belong in this document.
public struct LiveSessionPreferences: Codable, Equatable, Sendable {
    public struct Mapping: Codable, Equatable, Sendable {
        public let hostID: UUID
        public let directory: String
        public let storeID: String
        public let project: String
    }
    public private(set) var schemaVersion = 1
    public private(set) var hosts: [LiveHost] = []
    public private(set) var mappings: [Mapping] = []

    public static func read(_ data: Data) throws -> Self {
        if data.isEmpty { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw PhrenKitError.validation("Update phren to read these live connections.") }
        var ids: Set<UUID> = []
        for host in value.hosts {
            try host.validate()
            guard ids.insert(host.id).inserted else { throw PhrenKitError.validation("Repeated live connection.") }
        }
        var paths: Set<String> = []
        for mapping in value.mappings {
            guard ids.contains(mapping.hostID), !mapping.storeID.isEmpty, !mapping.project.isEmpty,
                  try normalizedDirectory(mapping.directory) == mapping.directory,
                  paths.insert(mapping.hostID.uuidString + mapping.directory).inserted else {
                throw PhrenKitError.validation("Invalid live project mapping.")
            }
        }
        return value
    }

    public static func saving(_ host: LiveHost, in data: Data) throws -> Data {
        var value = try read(data)
        try host.validate()
        value.hosts.removeAll { $0.id == host.id }
        value.hosts.append(host)
        return try JSONEncoder().encode(value)
    }

    public static func removing(_ hostID: UUID, from data: Data) throws -> Data {
        var value = try read(data)
        value.hosts.removeAll { $0.id == hostID }
        value.mappings.removeAll { $0.hostID == hostID }
        return try JSONEncoder().encode(value)
    }

    public static func assigning(hostID: UUID, directory: String, storeID: String?, project: String?, in data: Data) throws -> Data {
        var value = try read(data)
        guard value.hosts.contains(where: { $0.id == hostID }) else { throw PhrenKitError.validation("Connection no longer exists.") }
        let path = try normalizedDirectory(directory)
        value.mappings.removeAll { $0.hostID == hostID && $0.directory == path }
        if let storeID, let project {
            guard !storeID.isEmpty, !project.isEmpty else { throw PhrenKitError.validation("Choose a store and project.") }
            value.mappings.append(Mapping(hostID: hostID, directory: path, storeID: storeID, project: project))
        }
        return try JSONEncoder().encode(value)
    }

    public func mapping(hostID: UUID, cwd: String?) -> Mapping? {
        guard let cwd, let path = try? Self.normalizedDirectory(cwd) else { return nil }
        return mappings.filter {
            $0.hostID == hostID && (path == $0.directory || path.hasPrefix($0.directory + "/"))
        }.max { $0.directory.count < $1.directory.count }
    }

    static func normalizedDirectory(_ directory: String) throws -> String {
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true)
        guard directory.hasPrefix("/"), !parts.isEmpty, !parts.contains(".."),
              !parts.contains("."), directory.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PhrenKitError.validation("Choose an absolute project directory without . or .. components.")
        }
        return "/" + parts.joined(separator: "/")
    }
}
