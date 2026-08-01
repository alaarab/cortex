import XCTest
@testable import PhrenKit

/// In-memory stand-in for the REST client. Records every write so tests can
/// assert on request count, order and commit message, and serves the
/// ref/tree/blob reads that sha-conflict recovery pulls.
actor FakeGitHubClient: GitHubAPI {
    struct Write: Sendable, Equatable {
        let path: String
        let message: String
        let content: String
        let deleted: Bool
    }

    private(set) var writes: [Write] = []
    /// Paths whose blob was actually downloaded, in order. The cold tier's
    /// central claim — that cataloguing the archive costs no extra requests —
    /// is only checkable against this.
    private(set) var blobFetches: [String] = []
    private var files: [String: String] = [:]
    private var shas: [String: String] = [:]
    private var head = "head-0"
    private var revision = 0
    private var conflictOnce: Set<String> = []
    private var conflictAlways: Set<String> = []

    init(remote: [String: String] = [:]) {
        for path in remote.keys.sorted() {
            revision += 1
            files[path] = remote[path] ?? ""
            shas[path] = "blob-\(revision)"
            head = "head-\(revision)"
        }
    }

    /// Publishes remote content, minting a new blob sha + head so a forced
    /// pull sees a change.
    func setRemote(_ path: String, _ content: String) {
        revision += 1
        files[path] = content
        shas[path] = "blob-\(revision)"
        head = "head-\(revision)"
    }

    /// The next PUT to each path answers 409 (as GitHub does when the blob sha
    /// no longer matches). The attempt is still recorded.
    func failNextPut(on paths: [String]) {
        conflictOnce.formUnion(paths)
    }

    /// Every PUT to these paths answers 409 — a remote that keeps changing
    /// under the flush, exhausting the retry budget.
    func failEveryPut(on paths: [String]) {
        conflictAlways.formUnion(paths)
    }

    func remoteContent(_ path: String) -> String? { files[path] }

    func writes(to path: String) -> [Write] { writes.filter { $0.path == path } }

    // MARK: - GitHubAPI

    func headSha(owner: String, repo: String, branch: String) async throws -> String? { head }

    func tree(owner: String, repo: String, sha: String) async throws -> GitTree {
        // Real trees carry `size` on every blob; the cold tier's catalogue is
        // built entirely from what this response already contains.
        GitTree(sha: sha, truncated: false, tree: files.keys.sorted().map { path in
            GitTree.Entry(path: path, type: "blob", sha: shas[path], size: files[path]?.utf8.count)
        })
    }

    func blob(owner: String, repo: String, sha: String) async throws -> Data {
        guard let path = shas.first(where: { $0.value == sha })?.key,
              let content = files[path] else { throw GitHubError.invalidResponse }
        blobFetches.append(path)
        return Data(content.utf8)
    }

    func putFile(owner: String, repo: String, path: String, branch: String,
                 content: Data, message: String, sha: String?) async throws -> ContentsPutResponse {
        let text = String(decoding: content, as: UTF8.self)
        writes.append(Write(path: path, message: message, content: text, deleted: false))
        if conflictAlways.contains(path) { throw GitHubError.shaConflict(path: path) }
        if conflictOnce.remove(path) != nil { throw GitHubError.shaConflict(path: path) }
        setRemote(path, text)
        return ContentsPutResponse(
            content: .init(sha: shas[path] ?? "", path: path),
            commit: .init(sha: head)
        )
    }

    func deleteFile(owner: String, repo: String, path: String, branch: String,
                    message: String, sha: String) async throws {
        writes.append(Write(path: path, message: message, content: "", deleted: true))
        if conflictOnce.remove(path) != nil { throw GitHubError.shaConflict(path: path) }
        files.removeValue(forKey: path)
        shas.removeValue(forKey: path)
        revision += 1
        head = "head-\(revision)"
    }
}

/// Covers the write half of the sync engine: consecutive ops on one file
/// become one commit, ops on different files never merge or reorder, and a
/// conflicted group is re-applied whole.
final class SyncEngineCoalescingTests: XCTestCase {
    private var directory: URL!

    private static let reviewSeed = """
    # myproj Review Queue

    ## Review

    - [2026-07-26] First queued finding
    - [2026-07-26] Second queued finding
    - [2026-07-26] Third queued finding

    ## Stale

    ## Conflicts

    """

    /// review.md as another machine left it while the batch was queued: a
    /// fourth item arrived, so every queued approve now targets a stale sha.
    private static let reviewRemote = """
    # myproj Review Queue

    ## Review

    - [2026-07-26] First queued finding
    - [2026-07-26] Second queued finding
    - [2026-07-26] Third queued finding
    - [2026-07-26] Fourth queued finding

    ## Stale

    ## Conflicts

    """

    private static let tasksSeed = """
    # myproj tasks

    ## Active

    - [ ] Investigate flaky sync test on CI [medium] <!-- bid:013d708f rank:3 -->
    - [ ] Ship the iOS app [high] <!-- bid:aa853063 rank:1 -->

    ## Queue

    ## Done

    """

    private static let firstLine = "- [2026-07-26] First queued finding"
    private static let secondLine = "- [2026-07-26] Second queued finding"
    private static let thirdLine = "- [2026-07-26] Third queued finding"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Seeds the local cache with `local` (stale blob shas, as if pulled
    /// earlier) and the fake remote with `remote`, then hands back an engine
    /// whose background flush is disabled so the test drives `flushNow()`.
    private func makeEngine(local: [String: String],
                            remote: [String: String] = [:]) async throws -> (SyncEngine, FakeGitHubClient) {
        let store = try LocalStore(rootDirectory: directory, owner: "o", repo: "r", branch: "main")
        for (path, content) in local {
            try await store.write(path, content: content, blobSha: "stale-\(path)")
        }
        let client = FakeGitHubClient(remote: remote)
        let engine = SyncEngine(client: client, store: store, stateDirectory: directory)
        await engine.setAutoFlush(false)
        return (engine, client)
    }

    // MARK: - Grouping

    func testConsecutiveSameFileOpsCoalesceIntoOneCommit() async throws {
        let (engine, client) = try await makeEngine(local: ["myproj/review.md": Self.reviewSeed])

        for line in [Self.firstLine, Self.secondLine, Self.thirdLine] {
            try await engine.enqueue(.approveQueue(project: "myproj", line: line))
        }
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.count, 1, "three approves on one review.md must be one commit")
        XCTAssertEqual(writes[0].path, "myproj/review.md")
        XCTAssertEqual(writes[0].message, "phren: myproj(update x3) via ios")
        // All three ops are in the single serialization.
        XCTAssertFalse(writes[0].content.contains("First queued finding"))
        XCTAssertFalse(writes[0].content.contains("Second queued finding"))
        XCTAssertFalse(writes[0].content.contains("Third queued finding"))

        let status = await engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
    }

    func testSingleOpKeepsThePlainCommitMessage() async throws {
        let (engine, client) = try await makeEngine(local: ["myproj/review.md": Self.reviewSeed])

        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.firstLine))
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].message, "phren: myproj(update) via ios")
        let failed = await engine.failedOps()
        XCTAssertTrue(failed.isEmpty, "an op applied locally must still push, not park")
    }

    func testOpsOnDifferentFilesAreNotGrouped() async throws {
        let (engine, client) = try await makeEngine(local: [
            "myproj/review.md": Self.reviewSeed,
            "myproj/tasks.md": Self.tasksSeed,
        ])

        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.firstLine))
        try await engine.enqueue(.completeTask(project: "myproj", match: "flaky sync test"))
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.map(\.path), ["myproj/review.md", "myproj/tasks.md"])
        XCTAssertEqual(writes.map(\.message), [
            "phren: myproj(update) via ios",
            "phren: myproj(task) via ios",
        ])
    }

    func testDifferentProjectsSameFileNameAreNotGrouped() async throws {
        let (engine, client) = try await makeEngine(local: [
            "myproj/review.md": Self.reviewSeed,
            "other/review.md": Self.reviewSeed,
        ])

        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.firstLine))
        try await engine.enqueue(.approveQueue(project: "other", line: Self.firstLine))
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.map(\.path), ["myproj/review.md", "other/review.md"])
        XCTAssertEqual(writes.map(\.message), [
            "phren: myproj(update) via ios",
            "phren: other(update) via ios",
        ])
    }

    /// Coalescing must never reorder: interleaved files split into contiguous
    /// groups, so review → tasks → review stays review → tasks → review.
    func testGroupingPreservesFifoOrderAcrossFiles() async throws {
        let (engine, client) = try await makeEngine(local: [
            "myproj/review.md": Self.reviewSeed,
            "myproj/tasks.md": Self.tasksSeed,
        ])

        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.firstLine))
        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.secondLine))
        try await engine.enqueue(.completeTask(project: "myproj", match: "flaky sync test"))
        try await engine.enqueue(.approveQueue(project: "myproj", line: Self.thirdLine))
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.map(\.path),
                       ["myproj/review.md", "myproj/tasks.md", "myproj/review.md"])
        XCTAssertEqual(writes.map(\.message), [
            "phren: myproj(update x2) via ios",
            "phren: myproj(task) via ios",
            "phren: myproj(update) via ios",
        ])
        // The second review.md commit builds on the first, not on the seed.
        XCTAssertFalse(writes[2].content.contains("First queued finding"))
        XCTAssertFalse(writes[2].content.contains("Third queued finding"))
    }

    // MARK: - Conflict recovery

    func testShaConflictReappliesTheWholeGroup() async throws {
        let (engine, client) = try await makeEngine(
            local: ["myproj/review.md": Self.reviewSeed],
            remote: ["myproj/review.md": Self.reviewRemote]
        )
        await client.failNextPut(on: ["myproj/review.md"])

        for line in [Self.firstLine, Self.secondLine, Self.thirdLine] {
            try await engine.enqueue(.approveQueue(project: "myproj", line: line))
        }
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.count, 2, "one conflicted attempt, then one retry — still one commit per attempt")
        XCTAssertEqual(writes[1].message, "phren: myproj(update x3) via ios",
                       "the retry re-applies all three ops, not just the conflicting one")

        let content = await client.remoteContent("myproj/review.md")
        let final = try XCTUnwrap(content)
        XCTAssertFalse(final.contains("First queued finding"))
        XCTAssertFalse(final.contains("Second queued finding"))
        XCTAssertFalse(final.contains("Third queued finding"))
        // The remote change the conflict was about survives the re-apply.
        XCTAssertTrue(final.contains("Fourth queued finding"))

        let status = await engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
    }

    /// Parking stays per-op: when the refetch reveals one item already gone,
    /// that op alone lands in "Needs attention" and the rest still commit.
    func testReapplyParksOnlyTheOpWhoseTargetVanished() async throws {
        let remote = Self.reviewRemote.replacingOccurrences(
            of: "- [2026-07-26] Second queued finding\n", with: "")
        let (engine, client) = try await makeEngine(
            local: ["myproj/review.md": Self.reviewSeed],
            remote: ["myproj/review.md": remote]
        )
        await client.failNextPut(on: ["myproj/review.md"])

        for line in [Self.firstLine, Self.secondLine, Self.thirdLine] {
            try await engine.enqueue(.approveQueue(project: "myproj", line: line))
        }
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[1].message, "phren: myproj(update x2) via ios")

        let failed = await engine.failedOps()
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.op, .approveQueue(project: "myproj", line: Self.secondLine))
        XCTAssertEqual(failed.first?.op.label, "Approve review item")

        let status = await engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 1)

        // Retrying re-applies it (its edit never reached the document) and
        // parks it again rather than pushing a commit that contains nothing.
        await engine.retryFailed()
        await engine.flushNow()
        let stillFailed = await engine.failedOps()
        XCTAssertEqual(stillFailed.count, 1)
        let afterRetry = await client.writes
        XCTAssertEqual(afterRetry.count, 2, "a no-op retry must not manufacture a commit")
    }

    func testUnresolvedConflictParksEachOpIndividually() async throws {
        let (engine, client) = try await makeEngine(
            local: ["myproj/review.md": Self.reviewSeed],
            remote: ["myproj/review.md": Self.reviewRemote]
        )
        // Every attempt conflicts — three tries, then park.
        await client.failEveryPut(on: ["myproj/review.md"])

        for line in [Self.firstLine, Self.secondLine] {
            try await engine.enqueue(.approveQueue(project: "myproj", line: line))
        }
        await engine.flushNow()

        let writes = await client.writes
        XCTAssertEqual(writes.count, 3, "maxWriteAttempts tries, each still a single commit")
        let failed = await engine.failedOps()
        XCTAssertEqual(failed.count, 2, "the group parks as individual entries, not one blob")
        XCTAssertEqual(failed.map(\.op), [
            .approveQueue(project: "myproj", line: Self.firstLine),
            .approveQueue(project: "myproj", line: Self.secondLine),
        ])
        let status = await engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
    }

    // MARK: - Op metadata

    func testCommitMessageAndGroupingKeys() {
        let approve = PendingOp.approveQueue(project: "myproj", line: "- x")
        let reject = PendingOp.rejectQueue(project: "myproj", line: "- x")
        let complete = PendingOp.completeTask(project: "myproj", match: "x")
        let note = PendingOp.addNote(project: "myproj", date: "2026-07-26", time: "09:00", text: "hi")

        XCTAssertEqual(approve.primaryPath, "myproj/review.md")
        XCTAssertEqual(reject.primaryPath, "myproj/review.md")
        XCTAssertEqual(complete.primaryPath, "myproj/tasks.md")
        XCTAssertEqual(note.primaryPath, "myproj/notes/2026-07-26.md")
        XCTAssertEqual(reject.editablePaths, ["myproj/review.md", "myproj/FINDINGS.md"])

        XCTAssertEqual(PendingOp.commitMessage(for: [approve]), "phren: myproj(update) via ios")
        XCTAssertEqual(PendingOp.commitMessage(for: [approve, reject]),
                       "phren: myproj(update x2) via ios")
        XCTAssertEqual(PendingOp.commitMessage(for: Array(repeating: complete, count: 12)),
                       "phren: myproj(task x12) via ios")
    }
}
