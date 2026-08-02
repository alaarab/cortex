import Foundation
import XCTest
@testable import PhrenKit

/// The other half of conformance: `apps/ios/scripts/generate-fixtures.mjs`
/// proves TypeScript writes → Swift reads, but PhrenKit is a full writer too
/// (`FindingsFile.add`/`.edit`/`.remove`, `TasksFile.add`/`.complete`/
/// `.update`, `ReviewFile.edit`/`.approve`, `NotesFile.add`/`.edit`/
/// `.markPromoted`), and nothing proved TypeScript's readers accept what
/// Swift produces. A TypeScript test cannot invoke Swift directly, so the
/// corpus moves through disk instead, the same way the CLI-to-Swift
/// direction already does:
///
///   1. This test builds file content with PhrenKit's real mutators (never
///      hand-formatted strings standing in for them) and, when asked to
///      regenerate, writes the result into `Fixtures/swift-writes/` — a
///      sibling of the CLI-generated `Fixtures/` corpus, committed to git.
///   2. `packages/cli/src/__tests__/conformance-swift-writes.test.ts` reads
///      those exact committed files with the CLI's own readers
///      (`readFindings`, `readTasks`, `readReviewQueue`, `listNotes`) and
///      asserts the parsed shape matches what this file intended.
///
/// Regenerating is opt-in (`PHREN_REGENERATE_SWIFT_FIXTURES=1 swift test`)
/// rather than automatic on every run, for the same reason
/// `generate-fixtures.mjs` is a manual step on the TypeScript side: nothing
/// here has (or should get) an injected id source, so an unconditional
/// rewrite would silently rotate every `fid`/`bid`/`nid` on every test run —
/// churn indistinguishable from a real conformance break. Absent the
/// environment variable, this test still builds everything and asserts
/// Swift's own round-trip, so it exercises the same writer code paths either
/// way; only the disk write is conditional.
final class SwiftWritesFixturesTests: XCTestCase {
    /// The source directory this file lives in, resolved at compile time —
    /// not `Bundle.module`, which only sees the *copied* resources, not the
    /// writable source tree `git` tracks.
    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("swift-writes")
    }

    private var shouldRegenerate: Bool {
        ProcessInfo.processInfo.environment["PHREN_REGENERATE_SWIFT_FIXTURES"] == "1"
    }

    private func persist(_ content: String, as name: String) throws {
        guard shouldRegenerate else { return }
        let dir = Self.fixturesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - FINDINGS.md

    func testFindingsWrittenByPhrenKit() throws {
        var file = FindingsFile(content: "")
        let decisionFid = try file.add(
            project: "myproj",
            text: "[decision] Chose async/await over Combine for the sync engine",
            options: .init(scope: "builder", now: Self.fixedNow(0))
        )
        let pitfallFid = try file.add(
            project: "myproj",
            text: "[pitfall] Session tokens expire after 15 minutes of inactivity",
            options: .init(provenance: FindingProvenance(
                source: "human", machine: "swift-test-mac", actor: "swift-tester", tool: "phren-ios"
            ), now: Self.fixedNow(1))
        )
        _ = try file.add(
            project: "myproj",
            text: "Plain finding written by PhrenKit with no tag",
            options: .init(now: Self.fixedNow(2))
        )
        try file.edit(project: "myproj",
                      oldText: "Plain finding written by PhrenKit",
                      newText: "Edited by PhrenKit after being written by PhrenKit")
        try file.remove(project: "myproj", match: "Session tokens expire")

        // Swift-side self-check: what got written parses back the way it was
        // intended, before it ever reaches the other language.
        let parsed = file.parse()
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first { $0.stableId == decisionFid }?.scope, "builder")
        XCTAssertNil(parsed.first { $0.stableId == pitfallFid }, "removed finding must not survive")
        XCTAssertTrue(parsed.contains { $0.text == "Edited by PhrenKit after being written by PhrenKit" })

        try persist(file.content, as: "findings.md")
    }

    // MARK: - tasks.md

    func testTasksWrittenByPhrenKit() throws {
        var file = TasksFile(project: "myproj", content: nil)
        try file.add("Ship the PhrenKit conformance suite [high]")
        try file.add("Draft app store notes")
        try file.add("Investigate widget refresh timing [low]")
        try file.complete("Draft app store notes")
        try file.update("Investigate widget refresh timing", updates: .init(
            text: "Investigate widget refresh timing on iOS 18",
            priority: .medium,
            section: .active
        ))

        let rendered = file.render()
        let reparsed = TasksFile(project: "myproj", content: rendered)
        XCTAssertEqual(reparsed.doc.active.count, 1)
        XCTAssertEqual(reparsed.doc.active.first?.priority, .medium)
        XCTAssertEqual(reparsed.doc.done.first?.line, "Draft app store notes")
        XCTAssertEqual(reparsed.doc.queue.first?.priority, .high)

        try persist(rendered, as: "tasks.md")
    }

    // MARK: - review.md

    func testReviewWrittenByPhrenKit() throws {
        // ReviewFile has no "append a brand-new entry" writer — nothing on
        // the Swift side ever originates a queue line from scratch, only
        // `edit`/`approve`/`reject` an existing one (§4.3: entries have no
        // stable id and are located by exact line-text equality, same as
        // every other ReviewFile mutator). The seed below stands in for
        // entries that arrived via sync from a CLI-side `appendReviewQueue`
        // call; the mutations below it are the real, exercised PhrenKit
        // writer surface.
        let seed = """
        # myproj review queue

        ## Review

        - [2026-07-29] [pitfall] Background refresh silently drops queued writes when the device sleeps mid-sync
        - [2026-07-29] Unverified capture waiting on human review

        ## Stale

        ## Conflicts
        """
        var file = ReviewFile(content: seed)
        let items = file.parse()
        try file.edit(lineText: items[0].line,
                      newText: "Edited by PhrenKit: background refresh drops writes when the device sleeps mid-sync")
        try file.approve(lineText: items[1].line)

        let reparsed = ReviewFile(content: file.content).parse()
        XCTAssertEqual(reparsed.count, 1)
        XCTAssertEqual(reparsed[0].text, "Edited by PhrenKit: background refresh drops writes when the device sleeps mid-sync")

        try persist(file.content, as: "review.md")
    }

    // MARK: - notes/YYYY-MM-DD.md

    /// A fixed, valid date rather than "today" — the file name and the
    /// `## HH:MM:SS` headings both have to parse under `notes.ts`'s regexes
    /// regardless of when this test happens to run.
    static let noteDate = "2026-07-31"

    func testNotesWrittenByPhrenKit() throws {
        var file = NotesFile(project: "myproj", date: Self.noteDate, content: nil)
        let first = try file.add(text: "First note captured on the phone, never seen by the CLI", time: "09:15:00")
        _ = try file.add(text: "Second note, quick single line", time: "09:20:00")
        try file.edit(stableId: first.stableId, text: "First note, edited on the phone")
        try file.markPromoted(stableId: first.stableId)

        guard let rendered = file.render() else { return XCTFail("render() must not be nil with notes present") }
        let reparsed = NotesFile(project: "myproj", date: Self.noteDate, content: rendered).notes
        XCTAssertEqual(reparsed.count, 2)
        XCTAssertEqual(reparsed.first { $0.stableId == first.stableId }?.promoted, true)
        XCTAssertEqual(reparsed.first { $0.stableId == first.stableId }?.text, "First note, edited on the phone")

        try persist(rendered, as: "notes-\(Self.noteDate).md")
    }

    // MARK: - Helpers

    /// Distinct fixed instants so citation timestamps/created dates don't
    /// collide, without depending on wall-clock time at all.
    private static func fixedNow(_ offsetSeconds: Int) -> Date {
        Date(timeIntervalSince1970: 1_785_500_000 + Double(offsetSeconds))
    }
}
