import XCTest
@testable import PhrenKit

/// Covers the cold tier: catalogue built from the tree the sync already
/// fetches, no eager blob fetches, size refusal, LRU eviction, staleness, and
/// the hard rule that archived content never reaches the search index.
final class ColdTierTests: XCTestCase {
    private var directory: URL!

    private static let topicDoc = """
    # myproj - Build tooling

    <!-- phren:auto-topic slug=build-tooling -->

    ## Archived 2026-06-01

    - [pitfall] esbuild's watch mode misses symlinked packages <!-- fid:aaaa1111 -->
      <!-- citation: {"created_at":"2026-01-04T10:00:00.000Z"} -->
    - [decision] pnpm workspaces over lerna <!-- fid:bbbb2222 -->

    ## Archived 2026-08-01

    - [pattern] turbo caches per-package, not per-repo <!-- fid:cccc3333 -->

    """

    private static let findingsSeed = """
    # myproj Findings

    <!-- consolidated: 2026-08-01 -->

    ## 2026-08-02

    - [decision] Keep JWT expiry at 15 minutes <!-- fid:dddd4444 -->

    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phren-cold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeEngine(remote: [String: String]) async throws -> (SyncEngine, FakeGitHubClient) {
        let store = try LocalStore(rootDirectory: directory, owner: "o", repo: "r", branch: "main")
        let client = FakeGitHubClient(remote: remote)
        let engine = SyncEngine(client: client, store: store, stateDirectory: directory)
        await engine.setAutoFlush(false)
        return (engine, client)
    }

    // MARK: - Catalogue

    func testColdDocRefRecognizesOnlyTopicDocs() {
        let ref = ColdDocRef(path: "myproj/reference/topics/build-tooling.md", sha: "s", size: 4096)
        XCTAssertEqual(ref?.project, "myproj")
        XCTAssertEqual(ref?.slug, "build-tooling")
        XCTAssertEqual(ref?.displayName, "Build tooling")

        // `global` archives too — it's a readable project directory.
        XCTAssertNotNil(ColdDocRef(path: "global/reference/topics/general.md", sha: "s", size: 1))

        for path in [
            "myproj/reference/index.md",              // hand-written prose
            "myproj/reference/topics/nested/x.md",    // wrong depth
            "myproj/FINDINGS.md",
            "profiles/reference/topics/general.md",   // reserved dir
            "myproj/reference/topics/notes.txt",      // not markdown
        ] {
            XCTAssertNil(ColdDocRef(path: path, sha: "s", size: 1), "\(path) is not a topic doc")
        }
    }

    /// The whole premise: a pull that fetches the tree already knows the entire
    /// cold tier, so cataloguing it must not cost one extra blob request.
    func testPullCataloguesColdTierWithoutFetchingIt() async throws {
        let (engine, client) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            "myproj/reference/topics/build-tooling.md": Self.topicDoc,
            "myproj/reference/topics/testing.md": Self.topicDoc,
        ])
        await engine.pull(force: true)

        let fetched = await client.blobFetches
        XCTAssertEqual(fetched, ["myproj/FINDINGS.md"],
                       "only hot paths may be fetched; cold blobs wait for a tap")

        let topics = await engine.coldStore.topics(for: "myproj")
        XCTAssertEqual(topics.map(\.slug), ["build-tooling", "testing"])
        let summary = await engine.coldStore.projectSummaries()["myproj"]
        XCTAssertEqual(summary?.topicCount, 2)
        XCTAssertGreaterThan(summary?.totalBytes ?? 0, 0, "sizes come free with the tree")
        XCTAssertNil(summary?.findingCount, "nothing is hydrated, so nothing may be counted")
    }

    func testHydrationFetchesOnceThenServesFromCache() async throws {
        let (engine, client) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            "myproj/reference/topics/build-tooling.md": Self.topicDoc,
        ])
        await engine.pull(force: true)

        let path = "myproj/reference/topics/build-tooling.md"
        let document = try await engine.coldDocument(at: path)
        XCTAssertEqual(document.title, "Build tooling")
        XCTAssertEqual(document.entries.count, 3)
        XCTAssertTrue(document.entries.allSatisfy(\.archived), "every cold entry is archived")
        XCTAssertEqual(document.groupedByDate.map(\.date), ["2026-08-01", "2026-06-01"])

        let afterFirst = await client.blobFetches
        _ = try await engine.coldDocument(at: path)
        let afterSecond = await client.blobFetches
        XCTAssertEqual(afterFirst, afterSecond, "a second open must not refetch")

        // The count is knowable now, so the summary may report it.
        let summary = await engine.coldStore.projectSummaries()["myproj"]
        XCTAssertEqual(summary?.findingCount, 3)
    }

    /// A cached doc whose sha moved is never rendered from cache.
    func testStaleCacheIsRefetchedOnOpen() async throws {
        let path = "myproj/reference/topics/build-tooling.md"
        let (engine, client) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            path: Self.topicDoc,
        ])
        await engine.pull(force: true)
        _ = try await engine.coldDocument(at: path)

        let updated = Self.topicDoc + "\n## Archived 2026-08-02\n\n- [bug] vite dev server leaks sockets <!-- fid:eeee5555 -->\n"
        await client.setRemote(path, updated)
        await engine.pull(force: true)

        let before = await client.blobFetches
        let document = try await engine.coldDocument(at: path)
        let after = await client.blobFetches
        XCTAssertEqual(after.count, before.count + 1, "a moved sha must refetch")
        XCTAssertEqual(document.entries.count, 4)
    }

    /// Refused on the size the tree already reported — no request is made.
    func testOversizedTopicIsRefusedWithoutFetching() async throws {
        let path = "myproj/reference/topics/huge.md"
        let huge = String(repeating: "- a very long archived finding line\n", count: 40_000)
        XCTAssertGreaterThan(huge.utf8.count, ColdStore.maxDocumentBytes)

        let (engine, client) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            path: huge,
        ])
        await engine.pull(force: true)

        let before = await client.blobFetches
        do {
            _ = try await engine.coldDocument(at: path)
            XCTFail("an oversized cold doc must be refused")
        } catch let error as PhrenKitError {
            XCTAssertTrue(error.localizedDescription.contains("too large to open on the phone"),
                          "got: \(error.localizedDescription)")
        }
        let after = await client.blobFetches
        XCTAssertEqual(before, after, "refusal must happen before the request")
    }

    func testCacheEvictsLeastRecentlyUsedUnderBudget() async throws {
        let cold = ColdStore(rootDirectory: directory)
        // Three docs, each a third of the budget plus a slice, so the third
        // one can't fit alongside the first two.
        let chunk = ColdStore.cacheBudgetBytes / 2 + 1024
        let refs = (1...3).map { index in
            ColdDocRef(path: "myproj/reference/topics/t\(index).md", sha: "sha\(index)", size: chunk)
        }
        await cold.replaceCatalogue(refs.compactMap { $0 })

        for (index, ref) in refs.enumerated() {
            guard let ref else { return XCTFail("bad fixture") }
            await cold.cache(path: ref.path, text: String(repeating: "x", count: chunk),
                             sha: ref.sha, findingCount: index)
        }

        let cached = await cold.cachedPaths()
        XCTAssertEqual(cached, ["myproj/reference/topics/t3.md"],
                       "the budget holds one of these, and it keeps the newest")
        let bytes = await cold.cachedBytes()
        XCTAssertLessThanOrEqual(bytes, ColdStore.cacheBudgetBytes)
    }

    /// A topic the CLI merged away drops out of the catalogue *and* off disk.
    func testCatalogueReplacementDropsVanishedTopics() async throws {
        let cold = ColdStore(rootDirectory: directory)
        guard let ref = ColdDocRef(path: "myproj/reference/topics/gone.md", sha: "s1", size: 32) else {
            return XCTFail("bad fixture")
        }
        await cold.replaceCatalogue([ref])
        await cold.cache(path: ref.path, text: "- gone", sha: "s1", findingCount: 1)
        let cachedBefore = await cold.cachedPaths()
        XCTAssertEqual(cachedBefore, [ref.path])

        await cold.replaceCatalogue([])
        let cachedAfter = await cold.cachedPaths()
        let hydration = await cold.hydration(for: ref.path)
        XCTAssertTrue(cachedAfter.isEmpty)
        XCTAssertEqual(hydration, .unknown)
    }

    /// The archive row's data — a date and a topic count — has to survive the
    /// trip through `snapshot()` and the catalogue, or the footer has nothing
    /// to render.
    func testSnapshotCarriesTheConsolidationDate() async throws {
        let (engine, _) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            "myproj/reference/topics/build-tooling.md": Self.topicDoc,
            "other/FINDINGS.md": "# other Findings\n\n## 2026-08-02\n\n- never consolidated\n",
        ])
        await engine.pull(force: true)

        let store = try LocalStore(rootDirectory: directory, owner: "o", repo: "r", branch: "main")
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.consolidated["myproj"], "2026-08-01")
        XCTAssertNil(snapshot.consolidated["other"], "a project with no stamp has no archive")

        let summaries = await engine.coldStore.projectSummaries()
        XCTAssertEqual(summaries["myproj"]?.topicCount, 1)
        XCTAssertNil(summaries["other"])
    }

    // MARK: - Search isolation

    /// Cold content must not be searchable from the phone: a search returns
    /// live knowledge, which is what the CLI's own FTS index holds.
    func testColdContentNeverEntersTheSearchIndex() async throws {
        let (engine, _) = try await makeEngine(remote: [
            "myproj/FINDINGS.md": Self.findingsSeed,
            "myproj/reference/topics/build-tooling.md": Self.topicDoc,
        ])
        await engine.pull(force: true)
        _ = try await engine.coldDocument(at: "myproj/reference/topics/build-tooling.md")

        let store = try LocalStore(rootDirectory: directory, owner: "o", repo: "r", branch: "main")
        let paths = await store.allPaths()
        XCTAssertFalse(paths.contains { $0.contains("reference/") },
                       "hydrated cold docs live outside the mirrored tree")

        let index = SearchIndex(snapshot: await store.snapshot())
        XCTAssertTrue(index.search("esbuild").isEmpty, "archived text is not searchable")
        XCTAssertTrue(index.search("turbo caches").isEmpty)
        XCTAssertFalse(index.search("jwt expiry").isEmpty, "live findings still are")
    }

    /// Belt and braces: even handed straight to the index, an archived entry
    /// is filtered by `!finding.archived`.
    func testArchivedEntriesAreFilteredEvenIfHandedToTheIndex() {
        let document = TopicDocument(project: "myproj", slug: "build-tooling", content: Self.topicDoc)
        var snapshot = LocalStore.Snapshot.empty
        snapshot.findings = ["myproj": document.entries]
        XCTAssertTrue(SearchIndex(snapshot: snapshot).search("esbuild").isEmpty)
    }
}
