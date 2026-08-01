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
        XCTAssertFalse(LocalStore.isWritablePath("myproj/truths.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/reference/topic.md"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj/journal/2026-07-26-actor.md"))
        XCTAssertFalse(LocalStore.isWritablePath(".config/access-control.json"))
        XCTAssertFalse(LocalStore.isWritablePath("myproj.archived/FINDINGS.md"))

        // `global` became *readable* (it holds the consolidate skill's
        // cross-project findings) without becoming writable. These are the
        // assertions that fail the moment someone "simplifies" the split by
        // relaxing isProjectDirName, which isWritablePath delegates to.
        XCTAssertFalse(LocalStore.isWritablePath("global/FINDINGS.md"))
        XCTAssertFalse(LocalStore.isWritablePath("global/CLAUDE.md"))
        XCTAssertFalse(LocalStore.isWritablePath("global/tasks.md"))
        XCTAssertFalse(LocalStore.isWritablePath("global/review.md"))
        XCTAssertFalse(LocalStore.isWritablePath("global/notes/2026-07-26.md"))

        // The cold tier is read-only everywhere, at every depth.
        for path in [
            "myproj/reference/topics/architecture.md",
            "myproj/reference/topics/general.md",
            "myproj/reference/index.md",
            "global/reference/topics/general.md",
        ] {
            XCTAssertFalse(LocalStore.isWritablePath(path), "\(path) must never be writable")
        }
    }

    /// The reserved-directory set mirrors the CLI's `RESERVED_PROJECT_DIR_NAMES`
    /// (phren-core.ts:32) plus `scripts` (link.ts:202). Nothing under any of
    /// them is a project, so nothing under any of them syncs or writes.
    func testReservedDirectoriesAreNeitherSyncedNorWritable() {
        for reserved in ["profiles", "templates", "scripts", ".config", ".runtime", ".sessions"] {
            for leaf in ["FINDINGS.md", "tasks.md", "review.md", "summary.md", "CLAUDE.md", "truths.md"] {
                let path = "\(reserved)/\(leaf)"
                XCTAssertFalse(LocalStore.isSyncedPath(path), "\(path) must not sync")
                XCTAssertFalse(LocalStore.isWritablePath(path), "\(path) must not be writable")
            }
            let notePath = "\(reserved)/notes/2026-07-26.md"
            XCTAssertFalse(LocalStore.isSyncedPath(notePath), "\(notePath) must not sync")
            XCTAssertFalse(LocalStore.isWritablePath(notePath), "\(notePath) must not be writable")
            XCTAssertFalse(LocalStore.isReadableProjectDirName(reserved), "\(reserved) is not a project")
        }
    }

    func testGlobalSyncsAsAReadOnlyProject() {
        XCTAssertTrue(LocalStore.isSyncedPath("global/FINDINGS.md"))
        XCTAssertTrue(LocalStore.isSyncedPath("global/CLAUDE.md"))
        // Only those two: `global`'s tasks/review/notes are CLI machinery with
        // no phone surface, and paying for them would be paying for nothing.
        XCTAssertFalse(LocalStore.isSyncedPath("global/tasks.md"))
        XCTAssertFalse(LocalStore.isSyncedPath("global/review.md"))
        XCTAssertFalse(LocalStore.isSyncedPath("global/summary.md"))
        XCTAssertFalse(LocalStore.isSyncedPath("global/notes/2026-07-26.md"))
        XCTAssertFalse(LocalStore.isSyncedPath("global/reference/topics/general.md"))

        XCTAssertTrue(LocalStore.isReadableProjectDirName("global"))
        XCTAssertTrue(LocalStore.isReadOnlyProject("global"))
        XCTAssertFalse(LocalStore.isReadOnlyProject("myproj"))
        // A name that isn't a project at all is not "a read-only project".
        XCTAssertFalse(LocalStore.isReadOnlyProject("profiles"))
    }

    func testGlobalFindingsAppearInTheSnapshot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")

        try await store.write("global/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: "sha1")
        try await store.write("myproj/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: "sha2")

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.projects.map(\.name), ["global", "myproj"])
        XCTAssertEqual(snapshot.findings["global"]?.count, 2)
    }

    /// The engine refuses a write to a read-only tier *before* applying it
    /// locally, so the edit is never shown as accepted and then parked.
    func testEnqueueRefusesReadOnlyProject() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")
        try await store.write("global/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: "sha1")
        let engine = SyncEngine(client: FakeGitHubClient(), store: store, stateDirectory: dir)
        await engine.setAutoFlush(false)

        do {
            try await engine.enqueue(.addFinding(project: "global", text: "from the phone", type: nil))
            XCTFail("global must refuse writes")
        } catch let error as PhrenKitError {
            XCTAssertEqual(error, .validation("\"global\" is read-only in the app — edit it with the phren CLI."))
        }

        let status = await engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0, "a refused op must not be queued")
        let content = await store.read("global/FINDINGS.md")
        XCTAssertFalse(content?.contains("from the phone") ?? true, "and must not touch the local cache")
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

    /// `truths.md` has been downloaded since the first release and parsed into
    /// nothing. Shape is `upsertCanonical`'s (learning.ts:269).
    func testTruthsAreParsedAndSearchable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")

        try await store.write("myproj/truths.md", content: """
        # myproj Truths

        ## Truths

        - Postgres is the only datastore; no Redis _(added 2026-07-30)_
        - Every deploy goes through the staging gate _(added 2026-01-04)_
        - A truth someone hand-wrote without the added stamp
        """, blobSha: "sha1")

        let snapshot = await store.snapshot()
        let truths = try XCTUnwrap(snapshot.truths["myproj"])
        XCTAssertEqual(truths.count, 3)
        XCTAssertEqual(truths[0].text, "Postgres is the only datastore; no Redis")
        XCTAssertEqual(truths[0].addedDate, "2026-07-30")
        // The stamp is phren's bookkeeping, not part of the pinned text.
        XCTAssertFalse(truths[0].text.contains("added"))
        XCTAssertNil(truths[2].addedDate)
        XCTAssertEqual(truths[2].text, "A truth someone hand-wrote without the added stamp")

        // Truths are the *most* live knowledge in a store, so unlike archived
        // findings they belong in the index.
        let index = SearchIndex(snapshot: snapshot)
        let hits = index.search("postgres")
        XCTAssertEqual(hits.first?.kind, .truth)
        XCTAssertEqual(hits.first?.date, "2026-07-30")
        XCTAssertTrue(index.search("staging gate", kind: .truth).count == 1)
        XCTAssertTrue(index.search("staging gate", kind: .finding).isEmpty)
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
