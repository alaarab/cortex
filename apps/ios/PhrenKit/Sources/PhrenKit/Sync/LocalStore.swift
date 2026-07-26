import Foundation

/// On-device mirror of the phren store repo: plain markdown files under
/// Application Support, path-for-path with the repo, plus a manifest of blob
/// SHAs. Markdown text is the source of truth (matching the CLI), so no
/// database — parsing the whole store is trivial at phren's documented scale
/// (docs/performance.md: <1K findings is "small").
public actor LocalStore {
    public struct Manifest: Codable, Sendable {
        public var owner: String
        public var repo: String
        public var branch: String
        public var headSha: String?
        /// repo path → blob SHA (the optimistic-concurrency key for writes)
        public var blobShas: [String: String]
        public var lastSyncedAt: Date?

        public init(owner: String, repo: String, branch: String) {
            self.owner = owner
            self.repo = repo
            self.branch = branch
            self.blobShas = [:]
        }
    }

    /// Only these paths are ever written back to GitHub. Everything else in
    /// the store — `.config/`, `phren.root.yaml`, `stores.yaml`, `CLAUDE.md`,
    /// `summary.md`, `reference/`, `journal/` — is read-only for the app.
    public static func isWritablePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, isProjectDirName(parts[0]) else { return false }
        if parts.count == 2 {
            return ["FINDINGS.md", "tasks.md", "review.md"].contains(parts[1])
        }
        if parts.count == 3, parts[1] == "notes" {
            return JSRegex(#"^\d{4}-\d{2}-\d{2}\.md$"#).test(parts[2])
        }
        return false
    }

    /// Paths the sync engine mirrors locally. Skips `.config/`, `reference/`,
    /// `journal/`, and `global/` for the MVP (plan §GitHub sync engine).
    public static func isSyncedPath(_ path: String) -> Bool {
        if path == "phren.root.yaml" || path == "stores.yaml" { return true }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, isProjectDirName(parts[0]) else { return false }
        if parts.count == 2 {
            return ["FINDINGS.md", "tasks.md", "review.md", "summary.md", "CLAUDE.md", "truths.md"].contains(parts[1])
        }
        if parts.count == 3, parts[1] == "notes" {
            return JSRegex(#"^\d{4}-\d{2}-\d{2}\.md$"#).test(parts[2])
        }
        return false
    }

    /// Project directory names mirror `isValidProjectName` (lowercase letters,
    /// numbers, hyphens), excluding reserved/dot/global/archived dirs.
    static func isProjectDirName(_ name: String) -> Bool {
        guard JSRegex(#"^[a-z0-9][a-z0-9-]*$"#).test(name) else { return false }
        return name != "global" && name != "profiles" && !name.hasSuffix(".archived")
    }

    private let root: URL
    private var manifest: Manifest

    public init(rootDirectory: URL, owner: String, repo: String, branch: String) throws {
        self.root = rootDirectory
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"),
                                                withIntermediateDirectories: true)
        let manifestURL = rootDirectory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let saved = try? JSONDecoder().decode(Manifest.self, from: data),
           saved.owner == owner, saved.repo == repo {
            self.manifest = saved
        } else {
            self.manifest = Manifest(owner: owner, repo: repo, branch: branch)
        }
    }

    public static func defaultDirectory(owner: String, repo: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PhrenStore/\(owner)__\(repo)", isDirectory: true)
    }

    // MARK: - Manifest

    public var currentManifest: Manifest { manifest }

    public func updateManifest(_ mutate: (inout Manifest) -> Void) throws {
        mutate(&manifest)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }

    // MARK: - Files

    private func fileURL(_ path: String) -> URL {
        root.appendingPathComponent("files").appendingPathComponent(path)
    }

    public func read(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ path: String, content: String, blobSha: String?) throws {
        let url = fileURL(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        try updateManifest { manifest in
            if let blobSha {
                manifest.blobShas[path] = blobSha
            }
        }
    }

    public func delete(_ path: String) throws {
        try? FileManager.default.removeItem(at: fileURL(path))
        try updateManifest { $0.blobShas.removeValue(forKey: path) }
    }

    public func blobSha(for path: String) -> String? {
        manifest.blobShas[path]
    }

    public func allPaths() -> [String] {
        // Resolve symlinks on both sides before prefix-stripping: enumerated
        // URLs come back resolved (/private/var/…) while the stored root may
        // be the unresolved alias (/var/…), and a naive substring replace
        // mangles the relative path.
        let filesRoot = root.appendingPathComponent("files").resolvingSymlinksInPath()
        let rootPrefix = filesRoot.path.hasSuffix("/") ? filesRoot.path : filesRoot.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: filesRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let filePath = url.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(rootPrefix) else { continue }
            paths.append(String(filePath.dropFirst(rootPrefix.count)))
        }
        return paths.sorted()
    }

    public func wipe() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"),
                                                withIntermediateDirectories: true)
        manifest = Manifest(owner: manifest.owner, repo: manifest.repo, branch: manifest.branch)
    }

    // MARK: - Snapshot (parsed view for the UI)

    public struct Snapshot: Sendable {
        public var projects: [Project]
        public var findings: [String: [Finding]]
        public var tasks: [String: TaskDoc]
        public var notes: [String: [Note]]
        public var reviewQueue: [ProjectQueueItem]
        public var summaries: [String: String]

        public static let empty = Snapshot(projects: [], findings: [:], tasks: [:], notes: [:], reviewQueue: [], summaries: [:])
    }

    /// Parses every cached file into the UI model. Sorting of the cross-project
    /// review queue mirrors `readReviewQueueAcrossProjects` (access.ts:797).
    public func snapshot() -> Snapshot {
        var findings: [String: [Finding]] = [:]
        var tasks: [String: TaskDoc] = [:]
        var notes: [String: [Note]] = [:]
        var summaries: [String: String] = [:]
        var queue: [ProjectQueueItem] = []
        var projectNames = Set<String>()

        for path in allPaths() {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2, Self.isProjectDirName(parts[0]) else { continue }
            let project = parts[0]
            projectNames.insert(project)
            guard let content = read(path) else { continue }

            if parts.count == 2 {
                switch parts[1] {
                case "FINDINGS.md":
                    findings[project] = FindingsFile(content: content).parse()
                case "tasks.md":
                    tasks[project] = TasksFile(project: project, content: content).doc
                case "review.md":
                    for item in ReviewFile(content: content).parse() {
                        queue.append(ProjectQueueItem(project: project, item: item))
                    }
                case "summary.md":
                    summaries[project] = content
                default:
                    break
                }
            } else if parts.count == 3, parts[1] == "notes" {
                let date = String(parts[2].dropLast(3))
                let file = NotesFile(project: project, date: date, content: content)
                notes[project, default: []].append(contentsOf: file.notes)
            }
        }

        // notes.ts:152 — newest first across days
        for project in notes.keys {
            notes[project]?.sort { "\($0.date)T\($0.time)" > "\($1.date)T\($1.time)" }
        }

        queue.sort(by: Self.reviewQueueOrder)

        let projects = projectNames.sorted().map { name in
            Project(
                name: name,
                findingCount: findings[name]?.count ?? 0,
                taskCount: tasks[name].map { $0.active.count + $0.queue.count } ?? 0,
                noteCount: notes[name]?.count ?? 0,
                reviewCount: queue.filter { $0.project == name }.count
            )
        }

        return Snapshot(
            projects: projects, findings: findings, tasks: tasks,
            notes: notes, reviewQueue: queue, summaries: summaries
        )
    }

    /// access.ts:797 — section order, then date desc, then project, then id.
    /// Shared with the app's cross-store merge so a multi-store queue sorts
    /// identically to a single-store one.
    public static func reviewQueueOrder(_ a: ProjectQueueItem, _ b: ProjectQueueItem) -> Bool {
        let sectionOrder: [QueueItem.Section: Int] = [.review: 0, .stale: 1, .conflicts: 2]
        let aDate = a.item.date == "unknown" ? "" : a.item.date
        let bDate = b.item.date == "unknown" ? "" : b.item.date
        if a.item.section != b.item.section {
            return sectionOrder[a.item.section]! < sectionOrder[b.item.section]!
        }
        if aDate != bDate { return aDate > bDate }
        if a.project != b.project { return a.project < b.project }
        return a.item.id < b.item.id
    }
}
