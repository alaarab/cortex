import Foundation

/// The slice of the GitHub REST surface `SyncEngine` depends on.
///
/// Extracted as a seam so the engine's ordering and replay logic can be driven
/// against an in-memory repo. A `URLProtocol` stub can exercise `GitHubClient`'s
/// wire behavior but not the cases that matter here — suspending inside a PUT to
/// interleave a second mutation, or committing a write while returning a network
/// failure — and `URLProtocol` is ignored by swift-corelibs-foundation, which
/// the package's "PhrenKit builds anywhere Swift runs" claim depends on.
///
/// `GitHubClient` satisfies this as-is; the actor's isolation makes every
/// requirement implicitly `async`.
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
