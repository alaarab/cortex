import Foundation

/// One document in the **cold tier**: findings the CLI's
/// `autoArchiveToReference` (content/archive.ts:108) moved out of a project's
/// `FINDINGS.md` into `reference/topics/<slug>.md` once the project passed its
/// findings cap.
///
/// A catalogue entry is metadata only — path, blob sha, byte size — never the
/// text. All three come out of the recursive tree the sync engine already
/// fetches on every change (`GitTree.Entry` decodes `size` as well as `sha`),
/// so a complete index of the cold tier costs **zero** extra requests and
/// **zero** extra bytes. Only the text is deferred, and only until the user
/// opens a specific topic.
public struct ColdDocRef: Codable, Sendable, Hashable, Identifiable {
    public let path: String
    public let sha: String
    /// Raw blob size from the tree. Optional because the tree omits it for
    /// non-blob entries; a missing size can't be size-checked, so hydration
    /// treats it as unknown rather than as zero.
    public let size: Int?
    public let project: String
    public let slug: String

    public var id: String { path }

    /// A human-facing topic name recovered from the slug — the CLI's own
    /// labels live in `topic-config.json`, which the app doesn't sync, and
    /// the slug is a faithful stand-in ("build-tooling" → "Build tooling").
    public var displayName: String {
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = words.first else { return slug }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst())
            .joined(separator: " ")
    }

    /// Recognizes `<project>/reference/topics/<slug>.md` and nothing else.
    /// `reference/` also holds hand-written prose in some stores; only the
    /// auto-archive output has a stable shape the app can render as findings.
    public init?(path: String, sha: String, size: Int?) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4,
              LocalStore.isReadableProjectDirName(parts[0]),
              parts[1] == "reference", parts[2] == "topics",
              parts[3].hasSuffix(".md"), parts[3].count > 3 else { return nil }
        self.path = path
        self.sha = sha
        self.size = size
        self.project = parts[0]
        self.slug = String(parts[3].dropLast(3))
    }

    public init?(entry: GitTree.Entry) {
        guard entry.type == "blob", let sha = entry.sha else { return nil }
        self.init(path: entry.path, sha: sha, size: entry.size)
    }
}

/// What the app knows about one project's cold tier without reading a byte of
/// it: how many topics there are and how much they weigh.
public struct ColdSummary: Sendable, Equatable {
    public let project: String
    public let topicCount: Int
    public let totalBytes: Int
    /// Archived findings actually counted, or nil while any topic in this
    /// project is still un-hydrated. Never estimated: the exact number is only
    /// knowable by reading every topic doc, which is the work the cold tier
    /// exists to avoid. The UI says "6 topics" until it can honestly say
    /// "214 findings in 6 topics".
    public let findingCount: Int?
}

/// The cold tier's catalogue and its lazily hydrated, byte-budgeted cache.
///
/// # Why a tier at all
///
/// Once a project passes its findings cap the CLI moves its oldest findings
/// into `reference/topics/*.md`. Those files were not synced, so on the phone
/// consolidated findings did not *collapse* — they vanished. Eagerly syncing
/// `reference/` was measured on a real store at 5.5× the 30-day download,
/// 6.9× the cold-start payload and 6.9× the per-poll parse work, to serve
/// content nobody reads most days.
///
/// So: catalogue everything (free — see ``ColdDocRef``), hydrate one document
/// when the user opens it, cache it under a budget, and re-check its sha
/// against the tree every time it is opened.
///
/// # What it deliberately does not do
///
/// - It never fetches a cold blob eagerly. The only fetch is
///   ``SyncEngine/coldDocument(at:)``, driven by a tap.
/// - It never feeds `SearchIndex`. A phone search returns live knowledge,
///   matching the CLI, which strips archived content from its own index.
/// - It never renders cached text whose sha no longer matches the catalogue —
///   ``hydration(for:)`` is the only way in, and staleness is one of its
///   answers rather than something callers are trusted to remember.
public actor ColdStore {
    /// Refuse rather than fetch above this raw blob size. The largest real
    /// topic document measured is ~341 KB, which is ~445 KB on the wire once
    /// the blobs API base64s it; 1 MB leaves that threefold headroom while
    /// still refusing outright the pathological file that would otherwise sit
    /// there spinning on a cellular connection.
    public static let maxDocumentBytes = 1_048_576

    /// Total budget for hydrated documents on disk. Roughly a dozen of the
    /// largest real topic docs — enough that browsing an archive doesn't
    /// re-download what you just read, bounded so it can't grow into a second
    /// copy of the store.
    public static let cacheBudgetBytes = 4 * 1_048_576

    /// Why a document couldn't be handed straight back.
    public enum Hydration: Sendable, Equatable {
        /// Cached, and its sha still matches the catalogue's — safe to render.
        case cached(String)
        /// Absent, or cached at a sha the tree has since moved past. Carries
        /// the sha to fetch, which is always the catalogue's current one.
        case fetch(sha: String)
        /// Refused before the request was made, on the size the tree already
        /// told us.
        case tooLarge(bytes: Int)
        /// Not in the catalogue: never synced, or re-archived away since.
        case unknown
    }

    /// **Persisted** as `cold-tier.json`. Pure cache bookkeeping — everything
    /// it indexes can be refetched — but it still follows
    /// ``VersionedDocument``'s contract so a schema change sets the file aside
    /// instead of silently orphaning the files it points at.
    struct State: Codable, Sendable, VersionedDocument {
        static let currentSchemaVersion = 1

        var schemaVersion: Int = State.currentSchemaVersion
        /// repo path → catalogue entry, replaced wholesale from every tree.
        var catalogue: [String: ColdDocRef] = [:]
        /// repo path → what is actually on disk for it.
        var cached: [String: CacheRecord] = [:]

        /// What the user calls this file when it goes wrong.
        static let documentName = "archived-findings cache records"

        init() {}

        enum CodingKeys: String, CodingKey {
            case schemaVersion, catalogue, cached
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
                ?? Self.initialSchemaVersion
            catalogue = try container.decodeIfPresent([String: ColdDocRef].self, forKey: .catalogue) ?? [:]
            cached = try container.decodeIfPresent([String: CacheRecord].self, forKey: .cached) ?? [:]
        }
    }

    struct CacheRecord: Codable, Sendable, Equatable {
        /// The blob sha the cached bytes came from — the staleness key.
        var sha: String
        var bytes: Int
        var fileName: String
        /// LRU key. Bumped on every successful read, not on write alone.
        var lastAccessed: Date
        /// Archived findings parsed out of the doc when it was hydrated, so
        /// the archive row can eventually report a real count.
        var findingCount: Int
    }

    private let root: URL
    private let stateURL: URL
    private var state: State

    /// A cold cache that can't be created just never caches: unlike the
    /// pending-ops queue, nothing here is the only copy of anything. The load
    /// path still reports a *corrupt* state file through `StorageIssueLog`,
    /// because that is a schema problem worth hearing about.
    public init(rootDirectory: URL) {
        let cacheRoot = rootDirectory.appendingPathComponent("cold", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let url = rootDirectory.appendingPathComponent("cold-tier.json")
        let loaded = PersistedState.load(State.self, from: url, document: State.documentName).value ?? State()
        self.root = cacheRoot
        self.stateURL = url
        self.state = loaded
        // A quarantined (or simply absent) state file leaves bytes in `cold/`
        // that nothing can account for any more — drop them rather than let
        // the cache grow storage it no longer indexes.
        Self.removeFiles(in: cacheRoot, keeping: Set(loaded.cached.values.map(\.fileName)))
    }

    // MARK: - Catalogue

    /// Replaces the catalogue from a freshly fetched tree, and forgets cached
    /// documents whose path is no longer in it (a topic the CLI merged away).
    public func replaceCatalogue(_ refs: [ColdDocRef]) {
        state.catalogue = Dictionary(refs.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for (path, record) in state.cached where state.catalogue[path] == nil {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(record.fileName))
            state.cached.removeValue(forKey: path)
        }
        persist()
    }

    /// This project's topics, largest first — the archive browser's order, so
    /// the topic that actually holds the history leads.
    public func topics(for project: String) -> [ColdDocRef] {
        state.catalogue.values
            .filter { $0.project == project }
            .sorted {
                let (left, right) = ($0.size ?? 0, $1.size ?? 0)
                return left == right ? $0.slug < $1.slug : left > right
            }
    }

    /// One summary per project that has any cold content at all.
    public func projectSummaries() -> [String: ColdSummary] {
        var byProject: [String: [ColdDocRef]] = [:]
        for ref in state.catalogue.values {
            byProject[ref.project, default: []].append(ref)
        }
        return byProject.mapValues { refs in
            let counted = refs.compactMap { ref -> Int? in
                guard let record = state.cached[ref.path], record.sha == ref.sha else { return nil }
                return record.findingCount
            }
            return ColdSummary(
                project: refs[0].project,
                topicCount: refs.count,
                totalBytes: refs.reduce(0) { $0 + ($1.size ?? 0) },
                // Only when every topic has been read at least once at its
                // current sha; a partial sum would understate by an unknown
                // amount, which is worse than saying nothing.
                findingCount: counted.count == refs.count ? counted.reduce(0, +) : nil
            )
        }
    }

    public func reference(for path: String) -> ColdDocRef? { state.catalogue[path] }

    // MARK: - Hydration

    /// The only way to read a cold document, so the sha comparison can't be
    /// skipped by a caller in a hurry.
    public func hydration(for path: String) -> Hydration {
        guard let ref = state.catalogue[path] else { return .unknown }
        if let record = state.cached[path], record.sha == ref.sha,
           let text = try? String(contentsOf: root.appendingPathComponent(record.fileName), encoding: .utf8) {
            touch(path)
            return .cached(text)
        }
        if let size = ref.size, size > Self.maxDocumentBytes {
            return .tooLarge(bytes: size)
        }
        return .fetch(sha: ref.sha)
    }

    /// Records a freshly fetched document, then evicts least-recently-used
    /// entries until the cache is back inside its budget.
    public func cache(path: String, text: String, sha: String, findingCount: Int) {
        let fileName = Self.fileName(for: path)
        let bytes = text.utf8.count
        guard (try? Data(text.utf8).write(to: root.appendingPathComponent(fileName), options: .atomic)) != nil else {
            // Nothing is lost — the next open refetches. Recording the doc as
            // cached when its bytes aren't on disk is what would hurt.
            return
        }
        state.cached[path] = CacheRecord(sha: sha, bytes: bytes, fileName: fileName,
                                         lastAccessed: Date(), findingCount: findingCount)
        evictToBudget()
        persist()
    }

    /// Test/diagnostic view of what is actually held on disk.
    func cachedPaths() -> [String] { state.cached.keys.sorted() }

    func cachedBytes() -> Int { state.cached.values.reduce(0) { $0 + $1.bytes } }

    // MARK: - Internals

    private func touch(_ path: String) {
        state.cached[path]?.lastAccessed = Date()
        persist()
    }

    private func evictToBudget() {
        var total = cachedBytes()
        guard total > Self.cacheBudgetBytes else { return }
        // Path breaks ties: two documents cached in the same instant must
        // still evict in a defined order.
        let oldestFirst = state.cached.sorted {
            $0.value.lastAccessed == $1.value.lastAccessed
                ? $0.key < $1.key
                : $0.value.lastAccessed < $1.value.lastAccessed
        }
        for (path, record) in oldestFirst {
            guard total > Self.cacheBudgetBytes else { break }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(record.fileName))
            state.cached.removeValue(forKey: path)
            total -= record.bytes
        }
    }

    /// `<project>/reference/topics/<slug>.md` → `<project>__<slug>.md`. Every
    /// component was validated by ``ColdDocRef``'s initializer, so this can
    /// neither escape the directory nor collide across projects.
    private static func fileName(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "__")
    }

    private static func removeFiles(in directory: URL, keeping known: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !known.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func persist() {
        state.schemaVersion = State.currentSchemaVersion
        PersistedState.save(state, to: stateURL, document: State.documentName)
    }
}
