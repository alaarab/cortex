import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal GitHub REST v3 client covering exactly what the app needs:
/// user/repos discovery, ref + tree + blob reads, and per-file contents
/// PUT/DELETE writes with sha optimistic concurrency.
///
/// Kept deliberately narrow so a future switch to the Git Data API
/// (batched multi-file commits) stays local to this type.
public actor GitHubClient {
    public static let apiBase = URL(string: "https://api.github.com")!

    private let session: URLSession
    private var token: String?
    /// ETag cache for cheap ref polling: conditional requests answered 304
    /// don't count against the REST rate limit.
    private var etags: [String: String] = [:]

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token
    }

    public func setToken(_ token: String?) {
        self.token = token
        etags.removeAll()
    }

    // MARK: - Request plumbing

    private func request(_ path: String, method: String = "GET",
                         accept: String = "application/vnd.github+json",
                         etagKey: String? = nil,
                         body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let token else { throw GitHubError.notAuthenticated }
        // Not appendingPathComponent — several paths carry query strings
        // ("?recursive=1"), which it would percent-encode.
        guard let url = URL(string: path, relativeTo: Self.apiBase.appendingPathComponent("/")) else {
            throw GitHubError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let etagKey, let etag = etags[etagKey] {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }

        if http.statusCode == 403 || http.statusCode == 429 {
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            if remaining == "0" {
                let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(TimeInterval.init)
                    .map { Date(timeIntervalSince1970: $0) }
                throw GitHubError.rateLimited(resetAt: reset)
            }
        }
        if let etagKey, let etag = http.value(forHTTPHeaderField: "Etag") {
            etags[etagKey] = etag
        }
        return (data, http)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, http) = try await request(path)
        try Self.ensureOK(http, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw GitHubError.http(status: http.statusCode, message: message ?? "request failed")
        }
    }

    // MARK: - Identity + repos

    public func currentUser() async throws -> GitHubUser {
        try await get("user", as: GitHubUser.self)
    }

    /// Most recently pushed repos visible to the token (owner + collaborator + org).
    public func listRepos(page: Int = 1, perPage: Int = 100) async throws -> [GitHubRepo] {
        try await get("user/repos?sort=pushed&per_page=\(perPage)&page=\(page)&affiliation=owner,collaborator,organization_member",
                      as: [GitHubRepo].self)
    }

    public func repo(owner: String, name: String) async throws -> GitHubRepo {
        try await get("repos/\(owner)/\(name)", as: GitHubRepo.self)
    }

    /// True when the repo contains `phren.root.yaml` at its root — the marker
    /// of a phren store (packages/cli/src/phren-paths.ts ROOT_MANIFEST_FILENAME).
    public func isPhrenStore(owner: String, name: String) async -> Bool {
        do {
            let (_, http) = try await request("repos/\(owner)/\(name)/contents/phren.root.yaml")
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Git data reads

    /// Head commit SHA for a branch. Returns nil when the cached ETag still
    /// matches (HTTP 304) — nothing changed, and the poll was free.
    public func headSha(owner: String, repo: String, branch: String) async throws -> String? {
        let key = "ref:\(owner)/\(repo)/\(branch)"
        let (data, http) = try await request("repos/\(owner)/\(repo)/git/ref/heads/\(branch)", etagKey: key)
        if http.statusCode == 304 { return nil }
        try Self.ensureOK(http, data: data)
        return try JSONDecoder().decode(GitRef.self, from: data).object.sha
    }

    public func tree(owner: String, repo: String, sha: String) async throws -> GitTree {
        let tree = try await get("repos/\(owner)/\(repo)/git/trees/\(sha)?recursive=1", as: GitTree.self)
        guard !tree.truncated else { throw GitHubError.treeTruncated }
        return tree
    }

    public func blob(owner: String, repo: String, sha: String) async throws -> Data {
        let blob = try await get("repos/\(owner)/\(repo)/git/blobs/\(sha)", as: GitBlob.self)
        guard let data = blob.decoded else { throw GitHubError.invalidResponse }
        return data
    }

    // MARK: - Contents writes

    /// One commit per file, mirroring the granularity of phren's own hook
    /// commits. `sha` is the cached blob SHA; nil creates a new file.
    public func putFile(owner: String, repo: String, path: String, branch: String,
                        content: Data, message: String, sha: String?) async throws -> ContentsPutResponse {
        var payload: [String: Any] = [
            "message": message,
            "content": content.base64EncodedString(),
            "branch": branch,
        ]
        if let sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await request("repos/\(owner)/\(repo)/contents/\(path)", method: "PUT", body: body)
        if http.statusCode == 409 || http.statusCode == 422 {
            throw GitHubError.shaConflict(path: path)
        }
        try Self.ensureOK(http, data: data)
        return try JSONDecoder().decode(ContentsPutResponse.self, from: data)
    }

    public func deleteFile(owner: String, repo: String, path: String, branch: String,
                           message: String, sha: String) async throws {
        let payload: [String: Any] = ["message": message, "sha": sha, "branch": branch]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (data, http) = try await request("repos/\(owner)/\(repo)/contents/\(path)", method: "DELETE", body: body)
        if http.statusCode == 409 || http.statusCode == 422 {
            throw GitHubError.shaConflict(path: path)
        }
        try Self.ensureOK(http, data: data)
    }
}
