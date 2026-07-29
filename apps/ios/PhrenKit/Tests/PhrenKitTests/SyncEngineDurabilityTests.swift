import Foundation
import XCTest
@testable import PhrenKit

/// Durability of queued work: it must survive relaunch, refuse to publish
/// content it could not read, and back off rather than hammer or stall.
final class SyncEngineDurabilityTests: XCTestCase {

    /// The strongest test that identity is carried by the persisted op rather
    /// than regenerated: a second engine over the same state directory replays
    /// the queue and must land the finding exactly once.
    func testQueueSurvivesRelaunchAndPushesOnce() async throws {
        let seed = try Fixtures.text("findings-after-remove.md")
        let harness = try await SyncHarness.make(seed: ["myproj/FINDINGS.md": seed])
        defer { harness.teardown() }

        // Network down: the op applies locally and stays queued.
        await harness.repo.script([.network])
        let text = "Captured with no signal"
        try await harness.engine.enqueue(.addFinding(project: "myproj", text: text, type: nil))
        await harness.engine.flushForTesting()

        let beforeRelaunch = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertFalse(beforeRelaunch.contains(text), "nothing should have reached the remote yet")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.dir.appendingPathComponent("pending-ops.json").path))

        // Relaunch: fresh engine, same store and state directory.
        let revived = SyncEngine(client: harness.repo, store: harness.store, stateDirectory: harness.dir)
        await revived.setAutoFlush(false)
        let revivedStatus = await revived.currentStatus()
        XCTAssertEqual(revivedStatus.pendingCount, 1, "queue did not survive relaunch")

        // The retry deadline persisted with the op; a real relaunch happens
        // well after it, so skip the wait rather than sleep through it.
        await revived.clearBackoffForTesting()
        await revived.flushForTesting()

        let remote = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: remote), 1, "replay wrote the finding twice")
        let status = await revived.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
    }

    /// An unreadable file must never be published as empty. A directory at the
    /// file's path is a deterministic read failure needing no permissions.
    func testUnreadableFileIsNotPublishedAsEmpty() async throws {
        let seed = try Fixtures.text("tasks-after-update.md")
        let harness = try await SyncHarness.make(seed: ["myproj/tasks.md": seed])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.addTask(project: "myproj", text: "Doomed task"))

        // Replace the cached file with a directory, then flush.
        let cached = harness.dir.appendingPathComponent("files/myproj/tasks.md")
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.createDirectory(at: cached, withIntermediateDirectories: true)

        await harness.engine.flushForTesting()

        let remote = await harness.remote("myproj/tasks.md") ?? ""
        XCTAssertEqual(remote, seed, "a read failure overwrote good remote content")
        let writes = await harness.repo.totalWrites()
        XCTAssertEqual(writes, 0, "nothing should have been published")
    }

    /// A permanently failing op must not stall unrelated files behind it.
    func testBlockedLaneDoesNotStallOtherFiles() async throws {
        let harness = try await SyncHarness.make(seed: [
            "myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md"),
            "myproj/tasks.md": try Fixtures.text("tasks-after-update.md"),
        ])
        defer { harness.teardown() }

        // The findings PUT fails on the transport; the tasks PUT is fine.
        await harness.repo.script([.http(status: 403, message: "push access denied")])

        try await harness.engine.enqueue(.addFinding(project: "myproj", text: "Blocked finding", type: nil))
        try await harness.engine.enqueue(.addTask(project: "myproj", text: "Unblocked task"))
        await harness.engine.flushForTesting()

        let tasks = await harness.remote("myproj/tasks.md") ?? ""
        XCTAssertTrue(tasks.contains("Unblocked task"),
                      "a blocked findings op stalled an unrelated tasks op")

        let pending = await harness.engine.pendingOps()
        XCTAssertEqual(pending.count, 1, "the failed op should still be queued for retry")
        XCTAssertEqual(pending.first?.attempts, 1)
        XCTAssertNotNil(pending.first?.nextAttemptAt, "no backoff deadline was set")
    }

    /// Rate limiting schedules the retry at the reset time and does not spin.
    func testRateLimitSchedulesRetryAndDoesNotRetryImmediately() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md")])
        defer { harness.teardown() }

        let reset = Date().addingTimeInterval(900)
        await harness.repo.script([.rateLimited(reset: reset)])

        try await harness.engine.enqueue(.addFinding(project: "myproj", text: "Limited", type: nil))
        await harness.engine.flushForTesting()

        let pending = await harness.engine.pendingOps()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.nextAttemptAt?.timeIntervalSince1970 ?? 0,
                       reset.timeIntervalSince1970, accuracy: 1)

        // A second flush before the deadline must not issue another request.
        await harness.engine.flushForTesting()
        let writes = await harness.repo.totalWrites()
        XCTAssertEqual(writes, 0, "retried while still rate limited")
    }

    /// Deleting the last note removes the file, and that deletion has to reach
    /// GitHub — dropping the blob sha on local delete made it unsendable.
    func testDeletingLastNoteDeletesRemoteFile() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/notes/2026-07-25.md": try Fixtures.text("notes-after-edit-promote.md")])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.removeNote(project: "myproj", date: "2026-07-25", stableId: "688893f1"))
        try await harness.engine.enqueue(.removeNote(project: "myproj", date: "2026-07-25", stableId: "5588c05d"))
        await harness.engine.flushForTesting()

        let remote = await harness.remote("myproj/notes/2026-07-25.md")
        XCTAssertNil(remote, "the emptied notes file was never deleted on GitHub")
        let status = await harness.engine.currentStatus()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(status.failedCount, 0)
    }
}
