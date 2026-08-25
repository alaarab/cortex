import Foundation

/// The slice of the REST client the sync engine drives.
///
/// Extracted so `SyncEngine` can be exercised against an in-memory double —
/// coalescing, ordering and conflict recovery are all about *which* requests
/// are issued, which is untestable against a real `URLSession`. `GitHubClient`
/// is the only production conformer, and `SyncEngine.init(client:)` still
/// accepts it unchanged.
public protocol GitHubAPI: Sendable {
    func headSha(owner: String, repo: String, branch: String) async throws -> String?
    func tree(owner: String, repo: String, sha: String) async throws -> GitTree
    func blob(owner: String, repo: String, sha: String) async throws -> Data
    func putFile(owner: String, repo: String, path: String, branch: String,
                 content: Data, message: String, sha: String?) async throws -> ContentsPutResponse
    func deleteFile(owner: String, repo: String, path: String, branch: String,
                    message: String, sha: String) async throws
}

extension GitHubClient: GitHubAPI {}
