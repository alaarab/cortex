import XCTest
@testable import PhrenKit

/// Phase-1 groundwork: provenance passthrough, ref resolution, snapshot docs,
/// dataVersion gating, and search-index determinism + new token classes.
final class KitGroundworkTests: XCTestCase {

    // MARK: - Provenance passthrough

    func testFindingCarriesFullProvenance() throws {
        let findings = FindingsFile(content: try Fixtures.text("findings-after-remove.md")).parse()
        let finding = try XCTUnwrap(findings.first { $0.stableId == "6957f9f8" })
        let provenance = try XCTUnwrap(finding.provenance,
                                       "source comment was parsed but dropped from the model")
        XCTAssertEqual(provenance.source, "human")
        XCTAssertEqual(provenance.machine, "test-machine")
        XCTAssertEqual(provenance.actor, "tester")
        XCTAssertEqual(provenance.tool, "phren-ios")
        // The CLI-mirrored fields stay in lockstep with the struct.
        XCTAssertEqual(finding.machine, provenance.machine)
        XCTAssertEqual(finding.actor, provenance.actor)
    }

    // MARK: - Ref resolution (supersedes refs are 60-char text snippets)

    func testResolveFindingRefPrefixMatches() throws {
        let findings = FindingsFile(content: try Fixtures.text("findings-after-remove.md")).parse()
        // A truncated snippet of the real text resolves…
        let hit = FindingsFile.resolveFindingRef("Always validate JWT expiry", in: findings)
        XCTAssertEqual(hit?.stableId, "6957f9f8")
        // …case- and metadata-insensitively (normalizeFindingText on both sides).
        let caseHit = FindingsFile.resolveFindingRef("[pattern] ALWAYS VALIDATE jwt", in: findings)
        XCTAssertEqual(caseHit?.stableId, "6957f9f8")
        // Unknown text does not.
        XCTAssertNil(FindingsFile.resolveFindingRef("no such finding anywhere", in: findings))
        XCTAssertNil(FindingsFile.resolveFindingRef("   ", in: findings))
    }

    // MARK: - Snapshot: archived + docs

    func testSnapshotCarriesArchivedAndDocs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-ground-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")

        let findingsWithArchive = """
        # myproj Findings

        ## 2026-07-26

        - Live finding <!-- fid:aaaa1111 --> <!-- created: 2026-07-26 -->

        <details>
        <summary>Archived 2026-07-01</summary>

        ## 2026-07-01

        - Old archived finding <!-- fid:bbbb2222 --> <!-- created: 2026-07-01 -->

        </details>
        """
        try await store.write("myproj/FINDINGS.md", content: findingsWithArchive, blobSha: "s1")
        try await store.write("myproj/truths.md",
                              content: "# Truths\n\n- The sky is blue\n- Water is wet\n", blobSha: "s2")
        try await store.write("myproj/CLAUDE.md",
                              content: "# CLAUDE.md\n\nInstruction boilerplate here.\n", blobSha: "s3")

        let snapshot = await store.snapshot()
        let findings = snapshot.findings["myproj"] ?? []
        XCTAssertEqual(findings.count, 2, "archived findings should ride along")
        XCTAssertEqual(findings.filter(\.archived).count, 1)
        // Counts show only live findings.
        XCTAssertEqual(snapshot.projects.first?.findingCount, 1)
        // Docs surfaced.
        XCTAssertNotNil(snapshot.truths["myproj"])
        XCTAssertNotNil(snapshot.claudeDocs["myproj"])
    }

    // MARK: - dataVersion

    func testDataVersionBumpsOnContentChangesOnly() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")

        let v0 = await store.dataVersion
        try await store.write("myproj/FINDINGS.md", content: "# F\n", blobSha: nil)
        let v1 = await store.dataVersion
        XCTAssertGreaterThan(v1, v0)

        // Reads don't bump.
        _ = await store.readIfAvailable("myproj/FINDINGS.md")
        _ = await store.snapshot()
        let v2 = await store.dataVersion
        XCTAssertEqual(v2, v1)

        try await store.delete("myproj/FINDINGS.md")
        let v3 = await store.dataVersion
        XCTAssertGreaterThan(v3, v2)
    }

    // MARK: - Search index

    private func groundSnapshot() async throws -> (LocalStore.Snapshot, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-index-\(UUID().uuidString)")
        let store = try LocalStore(rootDirectory: dir, owner: "o", repo: "r", branch: "main")
        try await store.write("myproj/FINDINGS.md",
                              content: try Fixtures.text("findings-after-remove.md"), blobSha: nil)
        try await store.write("myproj/tasks.md",
                              content: try Fixtures.text("tasks-after-update.md"), blobSha: nil)
        try await store.write("myproj/review.md",
                              content: try Fixtures.text("review-seeded.md"), blobSha: nil)
        try await store.write("myproj/truths.md",
                              content: "# Truths\n\n- Deterministic builds are a feature\n", blobSha: nil)
        return (await store.snapshot(), dir)
    }

    func testIndexIsDeterministicAcrossBuilds() async throws {
        let (snapshot, dir) = try await groundSnapshot()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = SearchIndex(snapshot: snapshot).search("the")
        let b = SearchIndex(snapshot: snapshot).search("the")
        XCTAssertEqual(a.map(\.id), b.map(\.id),
                       "two builds over the same snapshot must rank identically")
    }

    func testFullDateAndBareIdQueriesMatch() async throws {
        let (snapshot, dir) = try await groundSnapshot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = SearchIndex(snapshot: snapshot)

        // Full date matches the finding under that heading (previously shredded
        // into ["2026","07","26"] and unmatchable as a unit).
        XCTAssertFalse(index.search("2026-07-26").isEmpty)

        // A bare fid, and the same id with its prefix, both hit.
        XCTAssertFalse(index.search("6957f9f8").isEmpty)
        XCTAssertEqual(index.search("fid:6957f9f8").map(\.id),
                       index.search("6957f9f8").map(\.id))

        // A bid finds its task.
        let taskHits = index.search("bid:013d708f")
        XCTAssertEqual(taskHits.first?.kind, .task)
    }

    func testReviewAndTruthDocsAreIndexed() async throws {
        let (snapshot, dir) = try await groundSnapshot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = SearchIndex(snapshot: snapshot)

        let review = index.search("session hooks fire twice", kind: .review)
        XCTAssertEqual(review.first?.kind, .review)
        XCTAssertEqual(review.first?.typeTag, "pitfall")

        let truth = index.search("deterministic builds", kind: .truth)
        XCTAssertEqual(truth.first?.kind, .truth)
    }
}
