import Foundation

// Models mirror the TypeScript shapes in packages/cli/src 1:1 so the two
// implementations stay diffable field-by-field.

/// Mirrors `FindingLifecycleStatus` (packages/cli/src/finding/lifecycle.ts).
public enum FindingLifecycleStatus: String, Codable, CaseIterable, Sendable {
    case active
    case superseded
    case contradicted
    case stale
    case invalidCitation = "invalid_citation"
    case retracted
}

/// Mirrors `FINDING_TYPES` (packages/cli/src/phren-core.ts).
public enum FindingType: String, Codable, CaseIterable, Sendable {
    case decision, pitfall, pattern, tradeoff, architecture, bug
}

/// Mirrors `FindingCitation` (packages/cli/src/content/citation.ts).
public struct FindingCitation: Codable, Equatable, Sendable {
    public var createdAt: String
    public var repo: String?
    public var file: String?
    public var line: Int?
    public var commit: String?
    public var supersedes: String?
    public var taskItem: String?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case repo, file, line, commit, supersedes
        case taskItem = "task_item"
    }

    public init(createdAt: String, repo: String? = nil, file: String? = nil, line: Int? = nil,
                commit: String? = nil, supersedes: String? = nil, taskItem: String? = nil) {
        self.createdAt = createdAt
        self.repo = repo
        self.file = file
        self.line = line
        self.commit = commit
        self.supersedes = supersedes
        self.taskItem = taskItem
    }
}

/// Mirrors `FindingProvenance` (packages/cli/src/content/citation.ts).
public struct FindingProvenance: Codable, Equatable, Sendable {
    public var source: String?
    public var machine: String?
    public var actor: String?
    public var tool: String?
    public var model: String?
    public var sessionId: String?
    public var scope: String?

    public init(source: String? = nil, machine: String? = nil, actor: String? = nil,
                tool: String? = nil, model: String? = nil, sessionId: String? = nil, scope: String? = nil) {
        self.source = source
        self.machine = machine
        self.actor = actor
        self.tool = tool
        self.model = model
        self.sessionId = sessionId
        self.scope = scope
    }

    public var isEmpty: Bool {
        source == nil && machine == nil && actor == nil && tool == nil
            && model == nil && sessionId == nil && scope == nil
    }
}

/// Mirrors `FindingItem` (packages/cli/src/data/access.ts).
public struct Finding: Codable, Equatable, Identifiable, Sendable {
    /// Positional ID recomputed on every read (`L1`, `L2`, ...).
    public var id: String
    /// Stable 8-char hex ID embedded as `<!-- fid:XXXXXXXX -->`.
    public var stableId: String?
    public var date: String
    public var text: String
    public var citation: String?
    public var citationData: FindingCitation?
    public var taskItem: String?
    public var confidence: Double?
    public var scope: String?
    public var machine: String?
    public var actor: String?
    public var supersededBy: String?
    public var supersedes: String?
    public var contradicts: [String]?
    public var status: FindingLifecycleStatus
    public var statusUpdated: String?
    public var statusReason: String?
    public var statusRef: String?
    public var archived: Bool
    /// The type tag parsed from a leading `[tag]` prefix, when present.
    public var typeTag: String?

    /// Raw markdown line this finding was parsed from (mutation key).
    public var rawLine: String
}

/// Mirrors `QueueItem` (packages/cli/src/data/access.ts).
public struct QueueItem: Codable, Equatable, Identifiable, Sendable {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case review = "Review"
        case stale = "Stale"
        case conflicts = "Conflicts"
    }

    public var id: String
    public var section: Section
    public var date: String
    public var text: String
    /// The raw markdown line — the mutation key for approve/reject/edit.
    public var line: String
    public var confidence: Double?
    public var risky: Bool
    public var machine: String?
    public var model: String?
}

/// Mirrors `ProjectQueueItem` (packages/cli/src/data/access.ts).
public struct ProjectQueueItem: Codable, Equatable, Identifiable, Sendable {
    public var project: String
    public var item: QueueItem
    public var id: String { "\(project)/\(item.id)/\(item.line)" }
}

/// Mirrors `NoteItem` (packages/cli/src/data/notes.ts).
public struct Note: Codable, Equatable, Identifiable, Sendable {
    /// `nid:xxxxxxxx`
    public var id: String
    public var stableId: String
    public var project: String
    public var date: String
    /// Always normalized to `HH:MM:SS` on parse.
    public var time: String
    public var text: String
    public var promoted: Bool
}

/// Mirrors `TaskItem` (packages/cli/src/data/tasks.ts).
public struct PhrenTask: Codable, Equatable, Identifiable, Sendable {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case active = "Active"
        case queue = "Queue"
        case done = "Done"
    }
    public enum Priority: String, Codable, CaseIterable, Sendable {
        case high, medium, low
    }

    /// Positional ID (`A1`, `Q3`, `D2`) recomputed on every read.
    public var id: String
    /// Stable 8-char hex ID embedded as `<!-- bid:XXXXXXXX -->`.
    public var stableId: String?
    public var section: Section
    /// Clean task text with the bid comment stripped.
    public var line: String
    public var checked: Bool
    public var priority: Priority?
    public var context: String?
    public var pinned: Bool?
    public var githubIssue: Int?
    public var githubUrl: String?
    public var rank: Int?
    public var lastActivity: String?
    public var createdAt: String?
    public var sessionId: String?
    public var scope: String?
    public var childFindings: [String]?
    public var speculative: Bool?
    public var parentFinding: String?
}

/// Mirrors `TaskDoc` (packages/cli/src/data/tasks.ts).
public struct TaskDoc: Codable, Equatable, Sendable {
    public var project: String
    public var title: String
    public var active: [PhrenTask]
    public var queue: [PhrenTask]
    public var done: [PhrenTask]

    public func items(in section: PhrenTask.Section) -> [PhrenTask] {
        switch section {
        case .active: return active
        case .queue: return queue
        case .done: return done
        }
    }

    public var allItems: [PhrenTask] { active + queue + done }
}

/// A project in the store: a top-level directory with markdown files.
public struct Project: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var findingCount: Int
    public var taskCount: Int
    public var noteCount: Int
    public var reviewCount: Int
    public var id: String { name }

    public init(name: String, findingCount: Int = 0, taskCount: Int = 0, noteCount: Int = 0, reviewCount: Int = 0) {
        self.name = name
        self.findingCount = findingCount
        self.taskCount = taskCount
        self.noteCount = noteCount
        self.reviewCount = reviewCount
    }
}

public enum PhrenKitError: Error, LocalizedError, Equatable {
    case emptyInput(String)
    case notFound(String)
    case ambiguousMatch(String)
    case validation(String)
    case archivedReadOnly(String)
    case secretDetected(String)
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput(let m), .notFound(let m), .ambiguousMatch(let m),
             .validation(let m), .archivedReadOnly(let m), .secretDetected(let m),
             .duplicate(let m):
            return m
        }
    }
}
