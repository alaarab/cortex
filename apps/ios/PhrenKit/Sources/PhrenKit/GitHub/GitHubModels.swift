import Foundation

public struct GitHubUser: Codable, Equatable, Sendable {
    public let login: String
    public let name: String?
    public let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login, name
        case avatarUrl = "avatar_url"
    }
}

public struct GitHubRepo: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let fullName: String
    public let name: String
    public let owner: Owner
    public let isPrivate: Bool
    public let defaultBranch: String
    public let pushedAt: String?
    public let permissions: Permissions?

    public struct Owner: Codable, Equatable, Sendable {
        public let login: String
    }

    public struct Permissions: Codable, Equatable, Sendable {
        public let push: Bool
    }

    enum CodingKeys: String, CodingKey {
        case id, name, owner, permissions
        case fullName = "full_name"
        case isPrivate = "private"
        case defaultBranch = "default_branch"
        case pushedAt = "pushed_at"
    }
}

public struct GitRef: Codable, Sendable {
    public let object: Object
    public struct Object: Codable, Sendable {
        public let sha: String
    }
}

public struct GitTree: Codable, Sendable {
    public let sha: String
    public let truncated: Bool
    public let tree: [Entry]

    public struct Entry: Codable, Sendable {
        public let path: String
        public let type: String
        public let sha: String?
        public let size: Int?
    }
}

public struct GitBlob: Codable, Sendable {
    public let sha: String
    public let content: String?
    public let encoding: String

    public var decoded: Data? {
        guard encoding == "base64", let content else { return nil }
        return Data(base64Encoded: content, options: .ignoreUnknownCharacters)
    }
}

public struct ContentsPutResponse: Codable, Sendable {
    public let content: ContentInfo?
    public let commit: CommitInfo

    public struct ContentInfo: Codable, Sendable {
        public let sha: String
        public let path: String
    }

    public struct CommitInfo: Codable, Sendable {
        public let sha: String
    }
}

public struct DeviceCodeResponse: Codable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUri: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

public enum GitHubError: Error, LocalizedError, Sendable {
    case http(status: Int, message: String)
    /// 409/422 sha mismatch on a contents PUT — the file changed remotely.
    case shaConflict(path: String)
    case rateLimited(resetAt: Date?)
    case notAuthenticated
    case invalidResponse
    case treeTruncated

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message):
            return "GitHub API error \(status): \(message)"
        case .shaConflict(let path):
            return "\(path) changed on GitHub while editing."
        case .rateLimited:
            return "GitHub rate limit reached — try again shortly."
        case .notAuthenticated:
            return "Not signed in to GitHub."
        case .invalidResponse:
            return "Unexpected response from GitHub."
        case .treeTruncated:
            return "Repository tree too large to enumerate."
        }
    }
}
