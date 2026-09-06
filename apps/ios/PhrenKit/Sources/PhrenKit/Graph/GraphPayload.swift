import CryptoKit
import Foundation

/// The payload `window.phrenGraph.mount()` consumes, transcribed from the
/// `GraphPayload` the web memory UI receives (packages/cli/browser/graph/types.ts:37)
/// and produced by `buildGraph` (packages/cli/src/ui/data.ts:251).
///
/// On the web this JSON comes from the local phren HTTP server. The iOS app is
/// serverless, so the same shape is built on-device from the synced markdown.
///
/// **Deliberate divergences from `buildGraph`**, all consequences of what the
/// app syncs rather than of the renderer:
///
/// - No `entity` or `reference` nodes. Both are derived from `reference/` docs
///   and the FTS index, neither of which the app mirrors.
/// - Topics come from the finding's own `[tag]` rather than
///   `classifyTopicForText`. The CLI's topic set is *adaptive* — built from a
///   content signal over the whole store (project-topics.ts:636) — and a
///   half-transcribed version would silently disagree with the desktop graph.
///   Tag-derived topics are honest about being a different, simpler grouping.
/// - `scores` is empty: score journals live under `.config/`, unsynced.
///
/// Node ids, score keys, and link structure *do* match the CLI exactly, which
/// is what lets a node round-trip back to a FINDINGS.md bullet on save.
public struct GraphPayload: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var fullLabel: String
        public var group: String
        public var refCount: Int
        public var project: String
        public var store: String
        public var tagged: Bool
        public var scoreKey: String?
        public var scoreKeys: [String]?
        public var refDocs: [RefDoc]?
        public var topicSlug: String?
        public var topicLabel: String?
        public var date: String?
        public var priority: String?
        public var section: String?
        public var findingCount: Int?
        public var taskCount: Int?
    }

    public struct RefDoc: Codable, Equatable, Sendable {
        public var doc: String
        public var project: String
        public var scoreKey: String?
    }

    public struct Link: Codable, Equatable, Sendable {
        public var source: String
        public var target: String
    }

    public struct Topic: Codable, Equatable, Sendable {
        public var slug: String
        public var label: String
    }

    public var nodes: [Node]
    public var links: [Link]
    public var topics: [Topic]
    public var total: Int

    // A public struct's memberwise init is internal; the app builds a merged
    // payload across stores, so this one has to cross the module boundary.
    public init(nodes: [Node], links: [Link], topics: [Topic], total: Int) {
        self.nodes = nodes
        self.links = links
        self.topics = topics
        self.total = total
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = String(data: try encoder.encode(self), encoding: .utf8) else {
            throw PhrenKitError.validation("Graph payload is not encodable as UTF-8.")
        }
        return json
    }
}

/// Builds a `GraphPayload` from cached markdown.
public enum GraphBuilder {
    /// `entryScoreKey` (packages/cli/src/governance/scores.ts:247) — the key
    /// the CLI mints per bullet, and the handle the app uses to resolve a
    /// graph node back to its exact FINDINGS.md line.
    public static func entryScoreKey(project: String, filename: String, snippet: String) -> String {
        let short = String(snippet.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(200))
        let digest = Insecure.SHA1.hash(data: Data("\(project):\(filename):\(short)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(project)/\(filename):\(hex.prefix(12))"
    }

    /// `findingStableId` (packages/cli/src/finding-graph-id.ts:12).
    public static func findingStableId(scoreKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(scoreKey.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "finding:\(hex.prefix(12))"
    }

    static let taggedBullet = JSRegex(#"^-\s+\[([a-z_-]+)\]\s+(.+?)(?:\s*<!--.*-->)?$"#)
    static let plainBullet = JSRegex(#"^-\s+(.+?)(?:\s*<!--.*-->)?$"#)
    static let dateHeading = JSRegex(#"^##\s+(\d{4}-\d{2}-\d{2})"#)
    static let minPlainLength = 10

    /// data.ts:351 — unfocused graphs are capped; focusing a project lifts the
    /// cap for that project.
    static let maxTagged = 200
    static let maxUntagged = 100
    static let maxTasks = 50

    /// `label` truncation, data.ts:426.
    static func truncate(_ text: String) -> String {
        text.count > 55 ? "\(text.prefix(52))..." : text
    }

    public struct Input: Sendable {
        /// project → raw FINDINGS.md
        public var findingsMarkdown: [String: String]
        public var tasks: [String: TaskDoc]
        public var projects: [String]
        public var storeName: String

        public init(findingsMarkdown: [String: String], tasks: [String: TaskDoc],
                    projects: [String], storeName: String) {
            self.findingsMarkdown = findingsMarkdown
            self.tasks = tasks
            self.projects = projects
            self.storeName = storeName
        }
    }

    public static func build(_ input: Input, focusProject: String? = nil) -> GraphPayload {
        var nodes: [GraphPayload.Node] = []
        var links: [GraphPayload.Link] = []
        var usedFindingIds: [String: Int] = [:]
        var topics: [String: String] = [:]
        var findingCounts: [String: Int] = [:]
        var taskCounts: [String: Int] = [:]

        let projectSet = Set(input.projects)
        let considered = focusProject.map { [$0] } ?? input.projects
        let isFocused = focusProject != nil

        // data.ts:291 — a repeated score key (two identical bullets) gets a
        // `-2`, `-3` suffix so node ids stay unique.
        func uniqueFindingId(_ id: String) -> String {
            let seen = usedFindingIds[id] ?? 0
            usedFindingIds[id] = seen + 1
            return seen == 0 ? id : "\(id)-\(seen + 1)"
        }

        for project in considered.sorted() {
            let markdown = input.findingsMarkdown[project]
            nodes.append(GraphPayload.Node(
                id: project, label: project, fullLabel: project, group: "project",
                refCount: markdown == nil ? 0 : 1, project: project, store: input.storeName,
                tagged: false, findingCount: 0, taskCount: 0
            ))
            guard let markdown else { continue }

            var taggedCount = 0
            var untaggedAdded = 0
            var currentDate: String?

            for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                if let date = dateHeading.group(line, 1) {
                    currentDate = date
                    continue
                }

                var text: String?
                var tag: String?
                if let matchedTag = taggedBullet.group(line, 1) {
                    tag = matchedTag
                    text = taggedBullet.group(line, 2)?.trimmingCharacters(in: .whitespaces)
                } else {
                    text = plainBullet.group(line, 1)?.trimmingCharacters(in: .whitespaces)
                }
                guard let text, !text.isEmpty else { continue }

                let isTagged = tag != nil
                if isTagged {
                    if !isFocused && taggedCount >= maxTagged { continue }
                } else {
                    if text.count < minPlainLength { continue }
                    if !isFocused && untaggedAdded >= maxUntagged { continue }
                }

                // data.ts:429 — the score key is minted over the bullet
                // *including* its tag prefix, which is what disambiguates two
                // findings differing only by tag.
                let snippet = tag.map { "[\($0)] \(text)" } ?? text
                let scoreKey = entryScoreKey(project: project, filename: "FINDINGS.md", snippet: snippet)
                let nodeId = uniqueFindingId(findingStableId(scoreKey: scoreKey))

                let slug = tag ?? "general"
                topics[slug] = topics[slug] ?? slug.replacingOccurrences(of: "-", with: " ").capitalized

                if isTagged { taggedCount += 1 } else { untaggedAdded += 1 }
                nodes.append(GraphPayload.Node(
                    id: nodeId, label: truncate(text), fullLabel: text,
                    group: "topic:\(slug)", refCount: isTagged ? taggedCount : untaggedAdded,
                    project: project, store: input.storeName, tagged: isTagged,
                    scoreKey: scoreKey, scoreKeys: [scoreKey],
                    refDocs: [GraphPayload.RefDoc(doc: "\(project)/FINDINGS.md", project: project, scoreKey: scoreKey)],
                    topicSlug: slug, topicLabel: topics[slug], date: currentDate
                ))
                links.append(GraphPayload.Link(source: project, target: nodeId))

                // data.ts:412 — an exact mention of another project's name
                // links the two projects.
                for other in exactProjectMentions(text, projectSet: projectSet, current: project) {
                    links.append(GraphPayload.Link(source: project, target: other))
                }
            }
            findingCounts[project] = taggedCount + untaggedAdded

            // ── Tasks (data.ts:497) ──
            if let doc = input.tasks[project] {
                var taskCount = 0
                for section in [PhrenTask.Section.active, .queue] {
                    let group = section == .active ? "task-active" : "task-queue"
                    for item in doc.items(in: section) {
                        if taskCount >= maxTasks { break }
                        let scoreKey = entryScoreKey(project: project, filename: "tasks.md", snippet: item.line)
                        nodes.append(GraphPayload.Node(
                            id: "\(project):task:\(item.id)", label: truncate(item.line), fullLabel: item.line,
                            group: group, refCount: 0, project: project, store: input.storeName,
                            tagged: false, scoreKey: scoreKey, scoreKeys: [scoreKey],
                            refDocs: [GraphPayload.RefDoc(doc: "\(project)/tasks.md", project: project, scoreKey: scoreKey)],
                            priority: item.priority?.rawValue, section: item.section.rawValue
                        ))
                        links.append(GraphPayload.Link(source: project, target: "\(project):task:\(item.id)"))
                        taskCount += 1
                    }
                }
                taskCounts[project] = taskCount
            }
        }

        // Fold the per-project tallies back onto the project nodes.
        for index in nodes.indices where nodes[index].group == "project" {
            nodes[index].findingCount = findingCounts[nodes[index].id] ?? 0
            nodes[index].taskCount = taskCounts[nodes[index].id] ?? 0
        }

        // Drop links pointing at projects outside the focused slice.
        let nodeIds = Set(nodes.map(\.id))
        links = links.filter { nodeIds.contains($0.source) && nodeIds.contains($0.target) }

        let topicList = topics
            .map { GraphPayload.Topic(slug: $0.key, label: $0.value) }
            .sorted { $0.slug < $1.slug }

        return GraphPayload(nodes: nodes, links: links, topics: topicList, total: nodes.count)
    }

    /// `findBulletTextByScoreKey` (packages/cli/src/ui/server.ts:1232) —
    /// resolve a node's score key back to the exact FINDINGS.md bullet,
    /// *including* its `[tag]` prefix, which is the string the finding
    /// mutators match on. Returns nil when the key does not resolve, so
    /// callers fall back to text matching exactly as the server does.
    public static func findBulletText(project: String, scoreKey: String, findingsMarkdown: String) -> String? {
        for rawLine in findingsMarkdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let entry: String?
            if let tag = taggedBullet.group(line, 1), let text = taggedBullet.group(line, 2) {
                entry = "[\(tag)] \(text.trimmingCharacters(in: .whitespaces))"
            } else if let text = plainBullet.group(line, 1) {
                entry = text.trimmingCharacters(in: .whitespaces)
            } else {
                entry = nil
            }
            guard let entry, !entry.isEmpty else { continue }
            if entryScoreKey(project: project, filename: "FINDINGS.md", snippet: entry) == scoreKey {
                return entry
            }
        }
        return nil
    }

    /// `exactProjectMentions` (data.ts:101) — tokenize on `[a-z0-9_-]+` and
    /// match a whole token, so "phren" in "phrenology" is not a mention.
    static let projectToken = JSRegex(#"[a-z0-9_-]+"#)

    static func exactProjectMentions(_ text: String, projectSet: Set<String>, current: String) -> [String] {
        let tokens = Set(projectToken.allMatches(text.lowercased()))
        return projectSet
            .filter { $0 != current && tokens.contains($0.lowercased()) }
            .sorted()
    }
}
