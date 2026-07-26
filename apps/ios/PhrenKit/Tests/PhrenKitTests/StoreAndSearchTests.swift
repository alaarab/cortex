import XCTest
@testable import PhrenKit

final class StoreAndSearchTests: XCTestCase {
    func testWritablePathWhitelist() {
        XCTAssertTrue(LocalStore.isWritablePath("myproj/FINDINGS.md"))
        XCTAssertTrue(LocalStore.isWritablePath("myproj/tasks.md"))
        XCTAssertTrue(LocalStore.isWritablePath("myproj/review.md"))
        XCTAssertTrue(LocalStore.isWritablePath("myproj/notes/2026-07-26.md"))

        XCTAssertFalse(LocalStore.isWritablePath("phren.root.yaml"))
        XCTAssertFalse(LocalStore.isWritablePath("stores.yaml"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/CLAUDE.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/summary.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/reference/topic.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/journal/2026-07-26-actor.md"))
        XCTAssertFalse(LocalStore.isWritablePath(".config/access-control.json"))
        XCTAssertFalse(LocalStore.isWritablePath("global/FINDINGS.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj.archived/FINDINGS.md"))
    }

    func testSnapshotParsesFixtureStore() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")

        try await store.write("myproj/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: "sha1")
        try await store.write("myproj/tasks.md",
                              content: try Fixtures.text("tasks-after-update.md"), blobSha: "sha2")
        try await store.write("myproj/review.md",
                              content: try Fixtures.text("review-seeded.md"), blobSha: "sha3")
        try await store.write("myproj/notes/2026-07-25.md",
                              content: try Fixtures.text("notes-after-edit-promote.md"), blobSha: "sha4")

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.projects.map(\.name), ["myproj"])
        XCTAssertEqual(snapshot.findings["myproj"]?.count, 2)
        XCTAssertEqual(snapshot.tasks["myproj"]?.active.count, 1)
        XCTAssertEqual(snapshot.notes["myproj"]?.count, 2)
        XCTAssertEqual(snapshot.reviewQueue.count, 3)
        // Review section sorts before Stale (access.ts:797).
        XCTAssertEqual(snapshot.reviewQueue.first?.item.section, .review)
        XCTAssertEqual(snapshot.reviewQueue.last?.item.section, .stale)
        // Manifest sha bookkeeping survives.
        let sha = await store.blobSha(for: "myproj/FINDINGS.md")
        XCTAssertEqual(sha, "sha1")
    }

    func testSearchIndex() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")
        try await store.write("myproj/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: nil)
        try await store.write("myproj/tasks.md",
                              content: try Fixtures.text("tasks-after-update.md"), blobSha: nil)

        let index = SearchIndex(snapshot: await store.snapshot())
        let jwt = index.search("jwt expiry")
        XCTAssertEqual(jwt.first?.kind, .finding)
        XCTAssertTrue(jwt.first?.text.contains("JWT expiry") ?? false)

        // Prefix match on the trailing token while typing.
        XCTAssertFalse(index.search("valida").isEmpty)

        // Kind + project filters.
        XCTAssertTrue(index.search("flaky", kind: .task).allSatisfy { $0.kind == .task })
        XCTAssertTrue(index.search("jwt", project: "other-project").isEmpty)
    }
}
