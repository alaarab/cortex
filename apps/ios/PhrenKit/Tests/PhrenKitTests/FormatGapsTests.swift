import XCTest
@testable import PhrenKit

/// docs/store-format.md §7 lists five scenarios the fixture corpus didn't
/// cover, each a real rough edge rather than a hypothetical one. This file
/// closes all five on the Swift side, reading the same committed fixtures
/// `conformance-format-gaps.test.ts` reads on the TypeScript side
/// (Fixtures/), so both languages assert against identical bytes.
final class FormatGapsTests: XCTestCase {
    // MARK: - Gap 1 (§2.1): unrecognised metadata comment survives an edit verbatim
    //
    // The format's most important invariant. A writer that round-trips
    // through a typed model instead of doing surgical string editing would
    // silently destroy this instead of carrying it through.

    func testUnknownAnnotationSurvivesAddAndEdit() throws {
        let afterAdd = try Fixtures.text("findings-unknown-annotation-after-add.md")
        let afterEdit = try Fixtures.text("findings-unknown-annotation-after-edit.md")
        XCTAssertTrue(afterAdd.contains(#"<!-- someday:field "x" -->"#))
        XCTAssertTrue(afterEdit.contains(#"<!-- someday:field "x" -->"#))

        var file = FindingsFile(content: afterAdd)
        try file.edit(project: "myproj",
                      oldText: "Unknown metadata comments must survive edits verbatim",
                      newText: "Edited text after an unrecognised annotation round trip")
        assertSameContent(file.content, afterEdit, "edit with unrecognised annotation")
        XCTAssertTrue(file.content.contains(#"<!-- someday:field "x" -->"#))
    }

    /// Fixture-independent proof against today's parser/mutator, not just a
    /// frozen snapshot: a comment neither `FindingsFile` nor
    /// `MetadataRegex` has ever heard of still comes back out unchanged.
    func testUnknownAnnotationSurvivesFreshWrite() throws {
        var file = FindingsFile(content: "")
        _ = try file.add(project: "myproj", text: "A finding with an alien annotation")
        // FindingsFile.add has no extraAnnotations parameter (an intentional
        // MVP divergence — see FindingsFile.add's doc comment), so the
        // alien comment is appended the way a sync from a newer/other
        // writer would actually arrive: already sitting on the line before
        // this implementation ever edits it.
        file = FindingsFile(content: file.content.replacingOccurrences(
            of: "A finding with an alien annotation",
            with: #"A finding with an alien annotation <!-- future:field "unreleased" -->"#
        ))
        try file.edit(project: "myproj", oldText: "A finding with an alien annotation", newText: "Renamed, no annotation supplied")
        XCTAssertTrue(file.content.contains(#"<!-- future:field "unreleased" -->"#))
        XCTAssertTrue(file.content.contains("Renamed, no annotation supplied"))
    }

    // MARK: - Gap 2 (§5.2): legacy <details> archive block
    //
    // Recognised by both readers, written by neither — the
    // least-exercised parser path. The fixture is hand-authored (nothing
    // produces this shape today); the parsed JSON alongside it came from
    // calling the real CLI reader.

    func testLegacyDetailsBlockParseMatchesCLI() throws {
        let content = try Fixtures.text("findings-legacy-details-archive.md")
        let file = FindingsFile(content: content)

        let defaultParsed = file.parse()
        guard let expectedDefault = try Fixtures.json("findings-legacy-details-archive-default-parsed.json") as? [[String: Any]] else {
            return XCTFail("bad findings-legacy-details-archive-default-parsed.json")
        }
        XCTAssertEqual(defaultParsed.count, expectedDefault.count)
        XCTAssertEqual(defaultParsed.first?.text, "Active finding outside any archive block")
        XCTAssertEqual(defaultParsed.first?.archived, expectedDefault.first?["archived"] as? Bool)

        let withArchived = file.parse(includeArchived: true)
        guard let expectedArchived = try Fixtures.json("findings-legacy-details-archive-with-archived-parsed.json") as? [[String: Any]] else {
            return XCTFail("bad findings-legacy-details-archive-with-archived-parsed.json")
        }
        XCTAssertEqual(withArchived.count, expectedArchived.count)
        let archived = withArchived.first { $0.stableId == "0000abcd" }
        XCTAssertEqual(archived?.text, "Archived finding inside a legacy details block")
        XCTAssertEqual(archived?.status.rawValue, "superseded")
        XCTAssertEqual(archived?.statusUpdated, "2026-01-06")
        XCTAssertEqual(archived?.statusReason, "superseded_by")
        XCTAssertEqual(archived?.statusRef, "replacement text")
        XCTAssertEqual(archived?.archived, true)
    }

    func testLegacyDetailsBlockRefusesEditAndRemove() throws {
        let content = try Fixtures.text("findings-legacy-details-archive.md")

        var editTarget = FindingsFile(content: content)
        XCTAssertThrowsError(try editTarget.edit(project: "myproj",
                                                 oldText: "Archived finding inside a legacy details block",
                                                 newText: "changed")) {
            guard case PhrenKitError.archivedReadOnly = $0 else { return XCTFail("wrong error: \($0)") }
        }

        var removeTarget = FindingsFile(content: content)
        XCTAssertThrowsError(try removeTarget.remove(project: "myproj", match: "Archived finding inside a legacy details block")) {
            guard case PhrenKitError.archivedReadOnly = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    // MARK: - Gap 3 (§6): [bracket] tag outside every known vocabulary

    func testNonstandardTagIsNotMangled() throws {
        let afterAdd = try Fixtures.text("findings-nonstandard-tag-after-add.md")
        let afterEdit = try Fixtures.text("findings-nonstandard-tag-after-edit.md")
        XCTAssertTrue(afterAdd.contains("[nonstandard] Bracket tags outside every known vocabulary must not be mangled"))
        XCTAssertTrue(afterEdit.contains("[nonstandard] Edited text without supplying any tag of its own"))

        let parsed = FindingsFile(content: afterAdd).parse()
        let entry = parsed.first { $0.stableId == "0000a002" }
        // parse() never validates the tag against any known-tag set — it
        // comes back as plain text, untouched.
        XCTAssertEqual(entry?.text, "[nonstandard] Bracket tags outside every known vocabulary must not be mangled")
        XCTAssertEqual(entry?.typeTag, "nonstandard")

        var file = FindingsFile(content: afterAdd)
        try file.edit(project: "myproj",
                      oldText: "Bracket tags outside every known vocabulary must not be mangled",
                      newText: "Edited text without supplying any tag of its own")
        assertSameContent(file.content, afterEdit, "edit with nonstandard tag")
    }

    // MARK: - Gap 4 (§4.2): pinned+prioritised task edited by text only
    //
    // Priority and pinned state are a dual source of truth — a substring in
    // the task text AND a parsed field. `update`/`updateTask` recompute
    // both from the *new* text whenever text changes, so a rename that
    // doesn't re-supply them silently drops both. This pins the actual
    // behaviour; it does not fix it.

    func testPinnedPrioritisedTaskBeforeTextOnlyEdit() throws {
        let content = try Fixtures.text("tasks-pinned-before-text-edit.md")
        let file = TasksFile(project: "myproj", content: content)
        let item = file.doc.queue.first { $0.stableId == "0000b001" }
        XCTAssertEqual(item?.priority, .high)
        XCTAssertEqual(item?.pinned, true)
        XCTAssertEqual(item?.line, "Ship urgent fix [high] [pinned]")
    }

    func testTextOnlyUpdateDropsPriorityAndPinned() throws {
        let content = try Fixtures.text("tasks-pinned-before-text-edit.md")
        var file = TasksFile(project: "myproj", content: content)
        try file.update("Ship urgent fix", updates: .init(text: "Ship urgent fix (renamed)"))

        let updated = file.doc.queue.first { $0.stableId == "0000b001" }
        XCTAssertEqual(updated?.line, "Ship urgent fix (renamed)")
        XCTAssertNil(updated?.priority)
        XCTAssertNil(updated?.pinned)

        assertSameContent(file.render(), try Fixtures.text("tasks-pinned-after-text-only-edit.md"), "text-only update on pinned task")
    }

    // MARK: - Gap 5 (§2.2, §4.3): UTF-16 code unit counting at truncation boundaries
    //
    // Lengths and slice offsets are counted in UTF-16 code units, matching
    // JavaScript's `.length`/`.slice` — not Unicode scalars and not
    // grapheme clusters. Each fixture plants a CANARY string just past the
    // boundary it should not survive, so a miscounted truncation (e.g.
    // Swift's grapheme-based `.count`) is a visible failure.

    func testReviewQueueTruncatesAt500UTF16Units() throws {
        let content = try Fixtures.text("review-unicode-boundary.md")
        let items = ReviewFile(content: content).parse()
        guard let entry = items.first(where: { $0.text.hasPrefix("🧵") }) else {
            return XCTFail("unicode review entry missing")
        }

        XCTAssertEqual(entry.text.utf16.count, 500)
        XCTAssertTrue(entry.text.hasSuffix("…"))
        XCTAssertFalse(entry.text.contains("CANARY"))
        // All 200 astral emoji (400 of the 500 units) survive whole.
        XCTAssertEqual(entry.text.filter { $0 == "🧵" }.count, 200)

        guard let expected = try Fixtures.json("review-unicode-boundary-parsed.json") as? [[String: Any]],
              let expectedText = expected.first?["text"] as? String else {
            return XCTFail("bad review-unicode-boundary-parsed.json")
        }
        XCTAssertEqual(entry.text, expectedText)
    }

    func testSupersedesAndSupersededByTruncateAt60UTF16Units() throws {
        let content = try Fixtures.text("findings-unicode-supersede-after.md")
        let parsed = FindingsFile(content: content).parse()
        let old = parsed.first { $0.stableId == "0000a003" }
        let new = parsed.first { $0.stableId == "0000a004" }

        XCTAssertEqual(old?.supersededBy?.utf16.count, 60)
        XCTAssertFalse(old?.supersededBy?.contains("NEW-FINDING-TAIL") ?? true)
        XCTAssertEqual(new?.supersedes?.utf16.count, 60)
        XCTAssertFalse(new?.supersedes?.contains("CANARY") ?? true)

        // The finding's own visible text is never truncated — only the
        // cross-reference comments are.
        XCTAssertTrue(old?.text.contains("CANARY-MUST-NOT-SURVIVE-60-TRUNCATION") ?? false)
        XCTAssertTrue(new?.text.contains("NEW-FINDING-TAIL") ?? false)

        guard let expected = try Fixtures.json("findings-unicode-supersede-parsed.json") as? [String: Any],
              let expectedOld = expected["old"] as? [String: Any],
              let expectedNew = expected["new"] as? [String: Any] else {
            return XCTFail("bad findings-unicode-supersede-parsed.json")
        }
        XCTAssertEqual(old?.supersededBy, expectedOld["supersededBy"] as? String)
        XCTAssertEqual(new?.supersedes, expectedNew["supersedes"] as? String)
    }
}
