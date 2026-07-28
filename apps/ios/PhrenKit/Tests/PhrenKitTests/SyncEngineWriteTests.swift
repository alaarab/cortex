import Foundation
import XCTest
@testable import PhrenKit

/// Covers the contract every mutation must satisfy: it reaches GitHub, it
/// reaches it exactly once, and local and remote agree afterwards.
///
/// `enqueue` applies the op to local content, then `push` re-derives the edits
/// from that same — already mutated — content. These tests pin the observable
/// consequences of that so the fix can be verified rather than assumed.
final class SyncEngineWriteTests: XCTestCase {

    private func seeds() throws -> [String: String] {
        [
            "myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md"),
            "myproj/tasks.md": try Fixtures.text("tasks-after-update.md"),
            "myproj/review.md": try Fixtures.text("review-seeded.md"),
            "myproj/notes/2026-07-25.md": try Fixtures.text("notes-after-edit-promote.md"),
        ]
    }

    // MARK: - The headline regression

    func testAddFindingReachesGitHubExactlyOnce() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md")])
        defer { harness.teardown() }

        let text = "Brand new finding captured on the phone"
        try await harness.engine.enqueue(.addFinding(project: "myproj", text: text, type: nil))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/FINDINGS.md")
        let puts = await harness.repo.putCount(for: "myproj/FINDINGS.md")
        XCTAssertEqual(puts, 1, "expected a single commit for one finding")

        let remote = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: remote), 1,
                       "finding should appear on GitHub exactly once")
    }

    func testAddTaskIsNotDuplicatedInThePushedBody() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/tasks.md": try Fixtures.text("tasks-after-update.md")])
        defer { harness.teardown() }

        let text = "Wire up the fixture regeneration gate"
        try await harness.engine.enqueue(.addTask(project: "myproj", text: text))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/tasks.md")
        let remote = await harness.remote("myproj/tasks.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: remote), 1,
                       "task was written to GitHub more than once")

        let doc = TasksFile(project: "myproj", content: remote).doc
        let matching = (doc.active + doc.queue + doc.done).filter { $0.line.contains(text) }
        XCTAssertEqual(matching.count, 1, "parsed remote tasks.md holds a duplicate")
    }

    func testAddNoteIsNotDuplicatedInThePushedBody() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/notes/2026-07-25.md": try Fixtures.text("notes-after-edit-promote.md")])
        defer { harness.teardown() }

        let text = "A third note added from the phone"
        try await harness.engine.enqueue(
            .addNote(project: "myproj", date: "2026-07-25", time: "16:20:00", text: text))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/notes/2026-07-25.md")
        let remote = await harness.remote("myproj/notes/2026-07-25.md") ?? ""
        XCTAssertEqual(occurrences(of: text, in: remote), 1,
                       "note was written to GitHub more than once")
    }

    // MARK: - Ops whose addressing key is erased by their own application

    func testRemoveFindingByFidReachesGitHub() async throws {
        let harness = try await SyncHarness.make(
            seed: ["myproj/FINDINGS.md": try Fixtures.text("findings-after-remove.md")])
        defer { harness.teardown() }

        try await harness.engine.enqueue(.removeFinding(project: "myproj", match: "6957f9f8"))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/FINDINGS.md")
        let remote = await harness.remote("myproj/FINDINGS.md") ?? ""
        XCTAssertFalse(remote.contains("fid:6957f9f8"), "removal never reached GitHub")
    }

    func testApproveQueueRemovesTheLineRemotely() async throws {
        let seed = try Fixtures.text("review-seeded.md")
        let harness = try await SyncHarness.make(seed: ["myproj/review.md": seed])
        defer { harness.teardown() }

        let line = ReviewFile(content: seed).parse()[0].line
        try await harness.engine.enqueue(.approveQueue(project: "myproj", line: line))
        await harness.engine.flushForTesting()

        await harness.assertDrained("myproj/review.md")
        let remote = await harness.remote("myproj/review.md") ?? ""
        XCTAssertFalse(remote.contains(line), "approved line still on GitHub")
    }

    // MARK: - Whole-class coverage

    /// One case per `PendingOp`. A 15th case added later without touching the
    /// push path fails here rather than in production.
    func testEveryOpKindFlushesCleanly() async throws {
        let reviewLine = ReviewFile(content: try Fixtures.text("review-seeded.md")).parse()[0].line
        let date = "2026-07-25"
        let notePath = "myproj/notes/\(date).md"

        let cases: [(name: String, op: PendingOp, paths: [String])] = [
            ("addFinding", .addFinding(project: "myproj", text: "Sweep finding", type: nil),
             ["myproj/FINDINGS.md"]),
            ("editFinding", .editFinding(project: "myproj", match: "6957f9f8", newText: "Swept edit"),
             ["myproj/FINDINGS.md"]),
            ("removeFinding", .removeFinding(project: "myproj", match: "38209d83"),
             ["myproj/FINDINGS.md"]),
            ("approveQueue", .approveQueue(project: "myproj", line: reviewLine),
             ["myproj/review.md"]),
            ("rejectQueue", .rejectQueue(project: "myproj", line: reviewLine),
             ["myproj/review.md"]),
            ("editQueue", .editQueue(project: "myproj", line: reviewLine, newText: "Swept queue text"),
             ["myproj/review.md"]),
            ("addNote", .addNote(project: "myproj", date: date, time: "17:00:00", text: "Swept note"),
             [notePath]),
            ("editNote", .editNote(project: "myproj", date: date, stableId: "5588c05d", text: "Swept note edit"),
             [notePath]),
            ("removeNote", .removeNote(project: "myproj", date: date, stableId: "5588c05d"),
             [notePath]),
            ("promoteNote", .promoteNote(project: "myproj", date: date, stableId: "5588c05d", findingType: nil),
             ["myproj/FINDINGS.md", notePath]),
            ("addTask", .addTask(project: "myproj", text: "Swept task"),
             ["myproj/tasks.md"]),
            ("completeTask", .completeTask(project: "myproj", match: "013d708f"),
             ["myproj/tasks.md"]),
            ("removeTask", .removeTask(project: "myproj", match: "aa853063"),
             ["myproj/tasks.md"]),
            ("updateTask", .updateTask(project: "myproj", match: "013d708f", text: "Swept task update",
                                       priority: nil, section: nil),
             ["myproj/tasks.md"]),
        ]

        XCTAssertEqual(cases.count, 14, "every PendingOp case must be represented")

        for testCase in cases {
            let harness = try await SyncHarness.make(seed: try seeds())
            defer { harness.teardown() }

            try await harness.engine.enqueue(testCase.op)
            await harness.engine.flushForTesting()

            let status = await harness.engine.currentStatus()
            XCTAssertEqual(status.failedCount, 0, "\(testCase.name): parked instead of pushed")
            XCTAssertEqual(status.pendingCount, 0, "\(testCase.name): never drained")

            for path in testCase.paths {
                let remote = await harness.remote(path)
                let local = await harness.local(path)
                XCTAssertEqual(remote, local, "\(testCase.name): local and remote diverged for \(path)")
            }
        }
    }
}
