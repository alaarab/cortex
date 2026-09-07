import Foundation

/// A handoff to Moshi on this iPhone, using its public session URL grammar.
/// This describes a destination, not an observed or running agent.
public struct MoshiSessionLink: Codable, Equatable, Sendable {
    public enum Multiplexer: String, Codable, CaseIterable, Sendable {
        case tmux
        case herdr
        public var title: String { self == .tmux ? "tmux" : "Herdr" }
    }

    public let multiplexer: Multiplexer
    public let session: String
    public let workspace: String
    public let window: String
    public let tab: String
    public let pane: String

    public init(multiplexer: Multiplexer, session: String, workspace: String = "",
                window: String = "", tab: String = "", pane: String = "") throws {
        self.multiplexer = multiplexer
        self.session = session.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        self.window = window.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tab = tab.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pane = pane.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try url()
    }

    public var summary: String {
        let name = session.isEmpty ? "default" : session
        return "\(multiplexer.title) · \(name)" + (workspace.isEmpty ? "" : " · \(workspace)")
    }

    /// Encode every query value independently, including literal + and %.
    /// Revalidate on use because Codable can load an older or malformed entry.
    public func url() throws -> URL {
        for value in [session, workspace, window, tab, pane] {
            guard value.count <= 512, value.rangeOfCharacter(from: .controlCharacters) == nil,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw PhrenKitError.validation("Session names and IDs must be at most 512 characters and contain no line breaks.")
            }
        }
        var items: [(String, String)] = []
        switch multiplexer {
        case .tmux:
            guard !session.isEmpty else { throw PhrenKitError.validation("Enter the tmux session name shown in Moshi.") }
            guard workspace.isEmpty, tab.isEmpty else { throw PhrenKitError.validation("Workspace and tab IDs apply to Herdr sessions.") }
            guard window.isEmpty || window.range(of: #"^[0-9]$"#, options: .regularExpression) != nil else {
                throw PhrenKitError.validation("A tmux window must be a single number from 0 to 9.")
            }
            guard pane.isEmpty || pane.range(of: #"^%?[0-9]+$"#, options: .regularExpression) != nil else {
                throw PhrenKitError.validation("Enter a tmux pane ID such as %5, or leave it empty.")
            }
            items = [("session", session), ("window", window), ("pane", pane)]
        case .herdr:
            guard window.isEmpty else { throw PhrenKitError.validation("Window numbers apply to tmux sessions.") }
            // An omitted session selects Herdr's default server. Preserve an
            // explicitly named server, including older saved "default" links.
            items = [("session", session), ("workspace", workspace), ("tab", tab), ("pane", pane)]
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var components = URLComponents()
        components.scheme = "moshi"
        components.host = multiplexer.rawValue
        components.percentEncodedQuery = try items.filter { !$0.1.isEmpty }.map { key, value in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else {
                throw PhrenKitError.validation("This session name couldn't be encoded as a link.")
            }
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        guard let url = components.url else { throw PhrenKitError.validation("This session link couldn't be created.") }
        return url
    }
}

/// Optional, device-local destinations. Full store identity prevents the same
/// project name in a personal and team store from sharing a session by accident.
public struct ProjectSessionLinks: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let storeID: String
        public let project: String
        public let link: MoshiSessionLink
    }

    public private(set) var schemaVersion = 1
    public private(set) var entries: [Entry] = []

    public static func read(_ data: Data) throws -> ProjectSessionLinks {
        if data.isEmpty { return ProjectSessionLinks() }
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.schemaVersion == 1 else {
            throw PhrenKitError.validation("Update phren to read these saved session links.")
        }
        var identities: Set<[String]> = []
        for entry in document.entries {
            guard !entry.storeID.isEmpty, !entry.project.isEmpty,
                  identities.insert([entry.storeID, entry.project]).inserted else {
                throw PhrenKitError.validation("Saved session links contain an invalid or repeated project.")
            }
            _ = try entry.link.url()
        }
        return document
    }

    public func link(storeID: String, project: String) -> MoshiSessionLink? {
        entries.first { $0.storeID == storeID && $0.project == project }?.link
    }

    /// Always read current data before changing a single project's destination.
    /// An unreadable/future document throws; callers must retain the original.
    public static func setting(_ link: MoshiSessionLink?, storeID: String, project: String, in data: Data) throws -> Data {
        guard !storeID.isEmpty, !project.isEmpty else { throw PhrenKitError.validation("Choose a store and project for this link.") }
        var document = try read(data)
        if let link { _ = try link.url() }
        document.entries.removeAll { $0.storeID == storeID && $0.project == project }
        if let link { document.entries.append(Entry(storeID: storeID, project: project, link: link)) }
        return try JSONEncoder().encode(document)
    }
}
