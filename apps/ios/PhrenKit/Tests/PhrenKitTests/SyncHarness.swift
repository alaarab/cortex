import Foundation
import XCTest
@testable import PhrenKit

/// A `SyncEngine` wired to a `FakeRepo` and a temp-directory `LocalStore`,
/// seeded into the state that follows a clean pull: identical content on both
/// sides, matching blob shas, manifest head current.
struct SyncHarness {
    let dir: URL
    let store: LocalStore
    let engine: SyncEngine
    let repo: FakeRepo

    static func make(seed: [String: String] = [:]) async throws -> SyncHarness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let repo = FakeRepo()
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")
        for (path, content) in seed {
            await repo.seed(path, content)
            try await store.write(path, content: content, blobSha: FakeRepo.sha(content))
        }
        let head = await repo.currentHead()
        try await store.updateManifest { $0.headSha = head }

        let engine = SyncEngine(client: repo, store: store, stateDirectory: dir)
        await engine.setWriteContext(.init(actor: "tester", machine: "test-machine"))
        // Flushes are driven explicitly. Otherwise `enqueue`'s detached flush
        // races whatever the test sets up next, and failures land on whichever
        // side won.
        await engine.setAutoFlush(false)
        return SyncHarness(dir: dir, store: store, engine: engine, repo: repo)
    }

    func teardown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func remote(_ path: String) async -> String? { await repo.content(path) }
    func local(_ path: String) async -> String? { await store.readIfAvailable(path) }

    /// Asserts the op drained rather than parking, and that local and remote
    /// agree — the pair of properties every successful write must leave behind.
    func assertDrained(_ path: String, file: StaticString = #filePath, line: UInt = #line) async {
        let status = await engine.currentStatus()
        XCTAssertEqual(status.failedCount, 0, "op was parked instead of pushed", file: file, line: line)
        XCTAssertEqual(status.pendingCount, 0, "op never drained from the queue", file: file, line: line)

        let remoteContent = await remote(path)
        let localContent = await local(path)
        XCTAssertEqual(remoteContent, localContent,
                       "local and remote diverged for \(path)", file: file, line: line)
    }
}

/// Counts non-overlapping occurrences — the duplicate-write assertions turn on
/// "exactly once", which a `contains` check cannot express.
func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var index = haystack.startIndex
    while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
        count += 1
        index = found.upperBound
    }
    return count
}
