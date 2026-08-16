import XCTest
@testable import PhrenKit

/// Approve must promote, not discard.
///
/// `phren extract` queues every candidate scoring below `autoAcceptThreshold`
/// into review.md **without** writing it to FINDINGS.md — for those the queue
/// line is the only copy (access.ts:839). The iOS port used to splice the line
/// out and write nothing, and the Review tab turns that into a swipe gesture, so
/// a triage session could destroy dozens of extracted findings while showing a
/// green checkmark for each.
final class ReviewApproveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-approve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(usesTeamJournal: Bool = false) async throws -> (SyncEngine, LocalStore) {
        let store = try LocalStore(rootDirectory: directory, owner: "o", repo: "r", branch: "main")
        let engine = SyncEngine(client: FakeGitHubClient(), store: store, stateDirectory: directory)
        await engine.setAutoFlush(false)
        await engine.setWriteContext(.init(actor: "octocat", machine: "Ala-iPhone",
                                           usesTeamJournal: usesTeamJournal))
        return (engine, store)
    }

    private let queueLine = "- [2026-07-26] [pitfall] Session hooks fire twice when both modes are enabled [confidence 0.60]"

    private func seedQueue(_ store: LocalStore) async throws {
        try await store.write("proj/review.md", content: """
        # proj Review Queue

        ## Review

        \(queueLine)

        ## Stale

        ## Conflicts

        """, blobSha: nil)
    }

    func testApprovingAnExtractionCandidateWritesTheFinding() async throws {
        let (engine, store) = try await makeEngine()
        try await seedQueue(store)
        // No FINDINGS.md at all: the queue line is the only copy of this text.

        try await engine.enqueue(.approveQueue(project: "proj", line: queueLine))
        await engine.flushNow()

        let findings = try XCTUnwrap(await store.read("proj/FINDINGS.md"),
                                     "approve must create FINDINGS.md, not discard the candidate")
        XCTAssertTrue(findings.contains("Session hooks fire twice when both modes are enabled"))
        // Written today, but the observation's own date is preserved.
        XCTAssertTrue(findings.contains(#"<!-- phren:queued "2026-07-26" -->"#))
        // The confidence marker is queue bookkeeping and must not leak in.
        XCTAssertFalse(findings.contains("confidence"))

        let review = try XCTUnwrap(await store.read("proj/review.md"))
        XCTAssertFalse(review.contains("Session hooks fire twice"), "the line should be dequeued")
    }

    func testApprovingAnItemAlreadyInFindingsDoesNotDuplicateIt() async throws {
        let (engine, store) = try await makeEngine()
        try await seedQueue(store)
        try await store.write("proj/FINDINGS.md", content: """
        # proj Findings

        ## 2026-07-20

        - [pitfall] Session hooks fire twice when both modes are enabled <!-- fid:11112222 -->

        """, blobSha: nil)

        try await engine.enqueue(.approveQueue(project: "proj", line: queueLine))
        await engine.flushNow()

        let findings = try XCTUnwrap(await store.read("proj/FINDINGS.md"))
        let occurrences = findings.components(separatedBy: "Session hooks fire twice").count - 1
        XCTAssertEqual(occurrences, 1, "the existing finding should be kept as-is, not duplicated")
        XCTAssertTrue(findings.contains("fid:11112222"))

        let review = try XCTUnwrap(await store.read("proj/review.md"))
        XCTAssertFalse(review.contains("Session hooks fire twice"))
    }

    func testApprovingIntoATeamStoreWritesTheJournal() async throws {
        let (engine, store) = try await makeEngine(usesTeamJournal: true)
        try await seedQueue(store)

        try await engine.enqueue(.approveQueue(project: "proj", line: queueLine))
        await engine.flushNow()

        let today = String(FindingsFile.isoTimestamp(Date()).prefix(10))
        let journal = try XCTUnwrap(await store.read("proj/journal/\(today)-octocat.md"),
                                    "a team-store approve belongs in the journal")
        XCTAssertTrue(journal.contains("Session hooks fire twice when both modes are enabled"))
        let findings = await store.read("proj/FINDINGS.md")
        XCTAssertNil(findings, "team stores never line-splice FINDINGS.md")
    }

    func testApproveKeepsTheQueueLineWhenPromotionFails() async throws {
        let (engine, store) = try await makeEngine()
        let secretLine = "- [2026-07-26] deploy key is sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        try await store.write("proj/review.md", content: """
        # proj Review Queue

        ## Review

        \(secretLine)

        """, blobSha: nil)

        // enqueue applies locally first, so a domain error surfaces here and
        // nothing is queued or written.
        do {
            try await engine.enqueue(.approveQueue(project: "proj", line: secretLine))
            XCTFail("approving a line containing a credential should fail")
        } catch {
            XCTAssertTrue(error is PhrenKitError, "expected a domain error, got \(error)")
        }
        await engine.flushNow()

        // Approve never destroys an item it could not promote (access.ts:108).
        let review = try XCTUnwrap(await store.read("proj/review.md"))
        XCTAssertTrue(review.contains("sk-ant-api03"), "the queue line must survive a failed promotion")
        XCTAssertNil(await store.read("proj/FINDINGS.md"))
    }

    /// The CLI's own output is the contract. `findings-after-approve.md` is
    /// snapshotted straight from `access.approveQueueItem`, so it pins the shape
    /// the port has to produce — and its existence is what makes a
    /// dequeue-only "approve" impossible to ship again.
    func testCLIFixtureShowsApproveWritesTheFinding() throws {
        let cliFindings = try Fixtures.text("findings-after-approve.md")
        let cliReview = try Fixtures.text("review-after-approve.md")

        XCTAssertTrue(cliFindings.contains("Session hooks fire twice when both MCP and hooks mode are enabled"),
                      "the CLI promotes the approved candidate into FINDINGS.md")
        XCTAssertTrue(cliFindings.contains(#"<!-- phren:queued "2026-07-26" -->"#),
                      "the promotion records when the observation was captured")
        XCTAssertFalse(cliFindings.contains("confidence"),
                       "the queue's confidence marker never reaches FINDINGS.md")
        XCTAssertFalse(cliReview.contains("Session hooks fire twice"),
                       "and the queue line is gone")
    }

    func testDequeueAloneLeavesFindingsUntouched() throws {
        // The primitive the fixed approve is built from.
        var file = ReviewFile(content: """
        # proj Review Queue

        ## Review

        \(queueLine)

        """)
        try file.dequeue(lineText: queueLine)
        XCTAssertFalse(file.content.contains("Session hooks fire twice"))
    }
}
