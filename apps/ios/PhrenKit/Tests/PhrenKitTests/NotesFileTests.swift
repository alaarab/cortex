import XCTest
@testable import PhrenKit

final class NotesFileTests: XCTestCase {
    func testParseMatchesCLI() throws {
        let content = try Fixtures.text("notes-after-edit-promote.md")
        let file = NotesFile(project: "myproj", date: "2026-07-25", content: content)
        guard let expected = try Fixtures.json("notes-parsed.json") as? [[String: Any]] else {
            return XCTFail("bad notes-parsed.json")
        }

        // listNotes sorts newest-first; the file itself is chronological.
        let byId = Dictionary(uniqueKeysWithValues: file.notes.map { ($0.stableId, $0) })
        XCTAssertEqual(file.notes.count, expected.count)
        for exp in expected {
            guard let note = byId[exp["stableId"] as? String ?? ""] else {
                return XCTFail("missing note \(exp["stableId"] ?? "?")")
            }
            XCTAssertEqual(note.id, exp["id"] as? String)
            XCTAssertEqual(note.time, exp["time"] as? String)
            XCTAssertEqual(note.text, exp["text"] as? String)
            XCTAssertEqual(note.promoted, exp["promoted"] as? Bool)
            XCTAssertEqual(note.date, exp["date"] as? String)
        }
    }

    func testRenderRoundTripsCLIFile() throws {
        let content = try Fixtures.text("notes-after-edit-promote.md")
        let file = NotesFile(project: "myproj", date: "2026-07-25", content: content)
        assertSameContent(file.render() ?? "", content, "notes round-trip")
    }

    func testEditAndPromoteMatchCLIByteForByte() throws {
        // CLI ran: editNote(n1, "First note, edited") then markNotePromoted(n1).
        var file = NotesFile(project: "myproj", date: "2026-07-25",
                             content: try Fixtures.text("notes-after-add.md"))
        let n1 = file.notes.first { $0.time == "14:30:05" }!
        try file.edit(stableId: n1.stableId, text: "First note, edited")
        try file.markPromoted(stableId: n1.stableId)
        assertSameContent(file.render() ?? "", try Fixtures.text("notes-after-edit-promote.md"), "edit+promote")
    }

    func testRemoveLastNoteDeletesFile() throws {
        var file = NotesFile(project: "myproj", date: "2026-07-25", content: nil)
        let note = try file.add(text: "only note", time: "10:00:00")
        try file.remove(stableId: note.stableId)
        XCTAssertNil(file.render())
    }

    func testPromoteTwiceRefused() throws {
        var file = NotesFile(project: "myproj", date: "2026-07-25",
                             content: try Fixtures.text("notes-after-edit-promote.md"))
        let promoted = file.notes.first { $0.promoted }!
        XCTAssertThrowsError(try file.markPromoted(stableId: promoted.stableId))
    }

    func testHeadingLikeBodyLineEscaped() throws {
        var file = NotesFile(project: "myproj", date: "2026-07-25", content: nil)
        // notes.ts:71 — a body line matching the heading regex gets #-prefixed.
        let sneaky = "## 10:00 <!-- nid:aaaabbbb -->"
        try file.add(text: "first line\n\(sneaky)", time: "11:00:00")
        let rendered = file.render()!
        let reparsed = NotesFile(project: "myproj", date: "2026-07-25", content: rendered)
        XCTAssertEqual(reparsed.notes.count, 1)
        XCTAssertTrue(reparsed.notes[0].text.contains("#\(sneaky)"))
    }

    func testNoteLengthCap() {
        var file = NotesFile(project: "myproj", date: "2026-07-25", content: nil)
        XCTAssertThrowsError(try file.add(text: String(repeating: "x", count: 10_001), time: "10:00:00"))
    }
}
