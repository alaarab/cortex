import Foundation
import XCTest
@testable import PhrenKit

/// The fix removes recomputation from `push` but must *preserve* it after a
/// pull: ops are fid/text-addressed precisely so they can be re-applied onto
/// content another machine changed. These tests pin that half.
final class SyncEngineConflictTests: XCTestCase {

    /// A conflict means the remote moved, which is the one case where the op
    /// genuinely should be re-derived — the retry must carry both changes.
    func testShaConflictRefetchesAndReapplies() async throws {
        let seed = try Fixtures.text("findings-after-remove.md")
        let harness = try await SyncHarness.make(seed: ["myproj/FINDINGS.md": seed])
        defer { harness.teardown() }

        // Another machine commits while our op is queued, and the first PUT is
        // rejected on sha.
        await harness.repo.remoteEdit("myproj/FINDINGS.md") { content in
            content + "\n- Finding written by another machine <!-- fid:11112222 --> <!-- created: 2026-07-26 -->\n"
        }
        await harness.repo.script([.shaConflict(path: "myproj/FINDINGS.md")])

        let mine = "Finding written on the phone"
        try await harness.engine.enqueue(.addFinding(project: "myproj", text: mine, type: nil))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/FINDINGS.md")
        let remote = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertEqual(occurrences(of: mine, in: remote), 1, "our finding should survive the rebase, once")
        XCTAssertTrue(remote.contains("fid:11112222"), "the other machine's finding was clobbered")
    }

    /// The remote deleted the finding a free-text edit targets. That op can
    /// never succeed, and the user must be told rather than have it silently
    /// dropped — text-addressed ops are deliberately fail-visible.
    func testRebaseParksOpWhoseTargetVanishedRemotely() async throws {
        let seed = try Fixtures.text("findings-after-remove.md")
        let harness = try await SyncHarness.make(seed: ["myproj/FINDINGS.md": seed])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.editFinding(
            project: "myproj",
            match: "Always validate JWT expiry before refresh",
            newText: "Edited on the phone"))

        // The target line disappears remotely before we flush.
        await harness.repo.remoteEdit("myproj/FINDINGS.md") { content in
            content
                .components(separatedBy: "\n")
                .filter { !$0.contains("fid:6957f9f8") }
                .joined(separator: "\n")
        }
        await harness.engine.pull(force: true)

        let status = await harness.engine.currentStatus()
        XCTAssertEqual(status.failedCount, 1, "an impossible op must surface, not vanish")
        XCTAssertEqual(status.pendingCount, 0)

        // And it must not leave a phantom edit in local content.
        let local = await harness.local("myproj/FINDINGS.md") ?? ""
        XCTAssertFalse(local.contains("Edited on the phone"),
                       "parked op left its mutation showing in the UI")
    }

    /// A PUT that commits but whose response is lost. The op stays queued, so
    /// the retry must recognise its own work rather than duplicating it or
    /// parking a write that actually succeeded.
    func testLostPutResponseDoesNotDuplicate() async throws {
        let seed = try Fixtures.text("findings-after-remove.md")
        let harness = try await SyncHarness.make(seed: ["myproj/FINDINGS.md": seed])
        defer { harness.teardown() }

        await harness.repo.script([.lostResponse])

        let text = "Finding whose response went missing"
        try await harness.engine.enqueue(.addFinding(project: "myproj", text: text, type: nil))
        await harness.engine.flushForTesting()

        // The write landed; the client saw a transport error and kept the op.
        let afterFirst = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: afterFirst), 1)

        // Pull picks up our own commit, replay recognises it, the op drains.
        // (The transport failure set a retry deadline; skip the wait, not the
        // behavior — the backoff itself is asserted in the durability tests.)
        await harness.engine.pull(force: true)
        await harness.engine.clearBackoffForTesting()
        await harness.engine.flushForTesting()

        let remote = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: remote), 1, "replay duplicated a write that had landed")
        let status = await harness.engine.currentStatus()
        XCTAssertEqual(status.failedCount, 0, "a successful write was parked as failed")
        XCTAssertEqual(status.pendingCount, 0)
    }

    /// A pull that changes an unrelated file must not disturb a queued op.
    func testPullKeepsPendingLocalEditsAndPushesBoth() async throws {
        let harness = try await SyncHarness.make(seed: [
            "myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md"),
            "myproj/tasks.md": try Fixtures.text("tasks-after-update.md"),
        ])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.addTask(project: "myproj", text: "Queued while offline"))

        await harness.repo.remoteEdit("myproj/FINDINGS.md") { $0 + "\n- Remote addition <!-- fid:33334444 -->\n" }
        await harness.engine.pull(force: true)
        await harness.engine.flushForTesting()

        let tasks = await harness.remote("myproj/tasks.md") ?? ""
        XCTAssertEqual(occurrences(of: "Queued while offline", in: tasks), 1)
        let findings = await harness.local("myproj/FINDINGS.md") ?? ""
        XCTAssertTrue(findings.contains("fid:33334444"), "remote change did not land locally")
        await harness.assertDrained("myproj/tasks.md")
    }

    /// Two ops on one file coalesce: the first push uploads content already
    /// carrying both, so the second has nothing dirty left to send.
    func testTwoOpsOnOneFileProduceOneCommit() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/tasks.md": try Fixtures.text("tasks-after-update.md")])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.addTask(project: "myproj", text: "First queued task"))
        try await harness.engine.enqueue(.addTask(project: "myproj", text: "Second queued task"))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/tasks.md")
        let remote = await harness.remote("myproj/tasks.md") ?? ""
        XCTAssertEqual(occurrences(of: "First queued task", in: remote), 1)
        XCTAssertEqual(occurrences(of: "Second queued task", in: remote), 1)
        let commits = await harness.repo.putCount(for: "myproj/tasks.md")
        XCTAssertEqual(commits, 1, "both edits were already in the first upload")
    }
}
