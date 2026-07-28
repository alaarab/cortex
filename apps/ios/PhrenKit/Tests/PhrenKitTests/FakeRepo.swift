import Foundation
@testable import PhrenKit

/// In-memory stand-in for a GitHub repo, driving `SyncEngine` through the same
/// `GitHubAPI` surface the real client implements.
///
/// Models the two behaviors the engine's correctness actually rests on:
/// content-addressed blob shas, and optimistic-concurrency rejection when the
/// sha a caller presents no longer matches the file. Both make the sha-conflict
/// path exercisable without hand-scripting it.
actor FakeRepo: GitHubAPI {
    struct Put: Sendable, Equatable {
        let path: String
        let content: String
        let message: String
        let sha: String?
    }

    /// Injected write failures, consumed one per PUT/DELETE in order.
    enum Failure: Sendable {
        case shaConflict(path: String)
        case rateLimited(reset: Date?)
        case http(status: Int, message: String)
        case network
        /// The write commits remotely but the caller sees a transport failure —
        /// the at-least-once delivery case that a naive replay double-applies.
        case lostResponse
    }

    private(set) var files: [String: String] = [:]
    private(set) var puts: [Put] = []
    private(set) var deletes: [String] = []
    private(set) var treeRequests = 0
    private var scripted: [Failure] = []
    private var beforePutHook: (@Sendable (String) async -> Void)?
    private var head = "head-0"
    private var revision = 0

    // MARK: - Test control

    func seed(_ path: String, _ content: String) {
        files[path] = content
        bump()
    }

    /// Queues write failures, consumed in order, one per PUT/DELETE. Reads are
    /// never affected — a script aimed at a write would otherwise be eaten by
    /// the poll that precedes it.
    func script(_ failures: [Failure]) {
        scripted = failures
    }

    /// Runs before each PUT is applied. Used to interleave a second mutation
    /// while a push is in flight.
    func onBeforePut(_ hook: @escaping @Sendable (String) async -> Void) {
        beforePutHook = hook
    }

    /// Simulates another machine committing to the store between our read and
    /// our write.
    func remoteEdit(_ path: String, _ transform: @Sendable (String) -> String) {
        guard let existing = files[path] else { return }
        files[path] = transform(existing)
        bump()
    }

    func content(_ path: String) -> String? { files[path] }
    func currentHead() -> String { head }
    func putCount(for path: String) -> Int { puts.filter { $0.path == path }.count }
    func totalWrites() -> Int { puts.count + deletes.count }

    private func bump() {
        revision += 1
        head = "head-\(revision)"
    }

    private func nextFailure() -> Failure? {
        scripted.isEmpty ? nil : scripted.removeFirst()
    }

    private func raise(_ failure: Failure) throws {
        switch failure {
        case .shaConflict(let path): throw GitHubError.shaConflict(path: path)
        case .rateLimited(let reset): throw GitHubError.rateLimited(resetAt: reset)
        case .http(let status, let message): throw GitHubError.http(status: status, message: message)
        case .network: throw URLError(.networkConnectionLost)
        case .lostResponse: throw URLError(.networkConnectionLost)
        }
    }

    /// Deterministic and content-addressed. Not a real git blob sha — nothing
    /// outside this fake interprets it — but it holds the property the engine
    /// depends on: identical bytes ⇒ identical sha.
    static func sha(_ content: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(content.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - GitHubAPI

    func headSha(owner: String, repo: String, branch: String) async throws -> String? {
        head
    }

    func tree(owner: String, repo: String, sha: String) async throws -> GitTree {
        treeRequests += 1
        let entries = files.keys.sorted().map { path -> GitTree.Entry in
            let content = files[path] ?? ""
            return GitTree.Entry(path: path, type: "blob", sha: Self.sha(content), size: content.utf8.count)
        }
        return GitTree(sha: sha, truncated: false, tree: entries)
    }

    func blob(owner: String, repo: String, sha: String) async throws -> Data {
        guard let content = files.values.first(where: { Self.sha($0) == sha }) else {
            throw GitHubError.invalidResponse
        }
        return Data(content.utf8)
    }

    func putFile(owner: String, repo: String, path: String, branch: String,
                 content: Data, message: String, sha: String?) async throws -> ContentsPutResponse {
        await beforePutHook?(path)
        let text = String(decoding: content, as: UTF8.self)

        if let failure = nextFailure() {
            if case .lostResponse = failure {
                commit(path, text, message, sha)
            }
            try raise(failure)
        }

        // GitHub's optimistic concurrency: the presented sha must match the
        // file as it stands, and nil means "must not exist yet".
        guard sha == files[path].map(Self.sha) else {
            throw GitHubError.shaConflict(path: path)
        }
        commit(path, text, message, sha)
        return ContentsPutResponse(
            content: .init(sha: Self.sha(text), path: path),
            commit: .init(sha: head)
        )
    }

    func deleteFile(owner: String, repo: String, path: String, branch: String,
                    message: String, sha: String) async throws {
        if let failure = nextFailure() { try raise(failure) }
        guard sha == files[path].map(Self.sha) else {
            throw GitHubError.shaConflict(path: path)
        }
        files.removeValue(forKey: path)
        deletes.append(path)
        bump()
    }

    private func commit(_ path: String, _ text: String, _ message: String, _ sha: String?) {
        files[path] = text
        puts.append(Put(path: path, content: text, message: message, sha: sha))
        bump()
    }
}
