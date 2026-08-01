import Foundation

/// A user mutation, expressed as a domain operation rather than a file diff so
/// it can be re-applied onto fresh content after a remote change (the
/// refetch-reapply half of sha-conflict recovery).
///
/// **Persisted.** This enum is written into `pending-ops.json` and is the
/// single most breakage-prone type in the app: adding a case makes queues
/// written by the new build unreadable to every older build, and renaming one
/// makes queues written by *older* builds unreadable here. Either is a schema
/// break — see the contract on ``VersionedDocument``, and bump
/// ``PendingOpsQueue/currentSchemaVersion`` when you take one.
public enum PendingOp: Codable, Equatable, Sendable {
    case addFinding(project: String, text: String, type: String?)
    case editFinding(project: String, match: String, newText: String)
    case removeFinding(project: String, match: String)
    case approveQueue(project: String, line: String)
    case rejectQueue(project: String, line: String)
    case editQueue(project: String, line: String, newText: String)
    case addNote(project: String, date: String, time: String, text: String)
    case editNote(project: String, date: String, stableId: String, text: String)
    case removeNote(project: String, date: String, stableId: String)
    case promoteNote(project: String, date: String, stableId: String, findingType: String?)
    case addTask(project: String, text: String)
    case completeTask(project: String, match: String)
    case removeTask(project: String, match: String)
    case updateTask(project: String, match: String, text: String?, priority: String?, section: String?)

    public var project: String {
        switch self {
        case .addFinding(let p, _, _), .editFinding(let p, _, _), .removeFinding(let p, _),
             .approveQueue(let p, _), .rejectQueue(let p, _), .editQueue(let p, _, _),
             .addNote(let p, _, _, _), .editNote(let p, _, _, _), .removeNote(let p, _, _),
             .promoteNote(let p, _, _, _),
             .addTask(let p, _), .completeTask(let p, _), .removeTask(let p, _),
             .updateTask(let p, _, _, _, _):
            return p
        }
    }

    /// The `(kind)` token of the commit message — the session-stop hook's
    /// vocabulary (cli/session-stop.ts:354-378).
    public var commitKind: String {
        switch self {
        case .addFinding, .editFinding, .removeFinding: return "findings"
        case .approveQueue, .rejectQueue, .editQueue: return "update"
        case .addNote, .editNote, .removeNote, .promoteNote: return "update"
        case .addTask, .completeTask, .removeTask, .updateTask: return "task"
        }
    }

    /// Commit-message summary following the session-stop hook convention
    /// (`phren: <project>(findings)` — cli/session-stop.ts:354-378), suffixed
    /// with the app as the writing tool.
    public var commitMessage: String {
        "phren: \(project)(\(commitKind)) via ios"
    }

    /// Commit summary for a coalesced group of ops sharing one commit. A
    /// single op keeps the plain shape; a batch appends its size, so a
    /// 12-item approve reads `phren: myproj(update x12) via ios`.
    public static func commitMessage(for ops: [PendingOp]) -> String {
        guard let first = ops.first else { return "phren: sync via ios" }
        guard ops.count > 1 else { return first.commitMessage }
        return "phren: \(first.project)(\(first.commitKind) x\(ops.count)) via ios"
    }

    /// The document this op owns — the coalescing key. Ops that also touch a
    /// second file (reject/edit mirror into FINDINGS.md, promote writes both)
    /// still group by the file their domain operation addresses. The project
    /// is part of the path, so two projects' review.md files never coalesce.
    public var primaryPath: String {
        switch self {
        case .addFinding, .editFinding, .removeFinding:
            return "\(project)/FINDINGS.md"
        case .approveQueue, .rejectQueue, .editQueue:
            return "\(project)/review.md"
        case .addNote(_, let date, _, _), .editNote(_, let date, _, _),
             .removeNote(_, let date, _), .promoteNote(_, let date, _, _):
            return "\(project)/notes/\(date).md"
        case .addTask, .completeTask, .removeTask, .updateTask:
            return "\(project)/tasks.md"
        }
    }

    /// Every file the op can write, in the order `SyncEngine.computeEdits`
    /// emits them. Only a fallback: the engine records the paths an op
    /// actually edited when it applies it, and queue entries written by an
    /// older build have none.
    public var editablePaths: [String] {
        switch self {
        case .rejectQueue, .editQueue:
            return [primaryPath, "\(project)/FINDINGS.md"]
        case .promoteNote:
            return ["\(project)/FINDINGS.md", primaryPath]
        default:
            return [primaryPath]
        }
    }

    /// A short human label for the pending/failed ops UI.
    public var label: String {
        switch self {
        case .addFinding(_, let text, _): return "Add finding: \(text.prefix(60))"
        case .editFinding: return "Edit finding"
        case .removeFinding: return "Delete finding"
        case .approveQueue: return "Approve review item"
        case .rejectQueue: return "Reject review item"
        case .editQueue: return "Edit review item"
        case .addNote(_, _, _, let text): return "Add note: \(text.prefix(60))"
        case .editNote: return "Edit note"
        case .removeNote: return "Delete note"
        case .promoteNote: return "Promote note to finding"
        case .addTask(_, let text): return "Add task: \(text.prefix(60))"
        case .completeTask: return "Complete task"
        case .removeTask: return "Delete task"
        case .updateTask: return "Update task"
        }
    }
}

/// **Persisted** inside `pending-ops.json`. Every field added since the first
/// release is optional on purpose — see the contract on ``VersionedDocument``.
public struct QueuedOp: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let op: PendingOp
    public let queuedAt: Date
    public var attempts: Int
    public var lastError: String?
    /// Repo paths this op actually edited when it was applied to the local
    /// cache, in edit order. The flush pushes exactly these files, so a
    /// tolerated no-op (a reject whose finding was already gone) never sends
    /// an unchanged file. Nil for entries persisted before this was recorded —
    /// `editedPaths` then falls back to the op's static shape.
    public var paths: [String]?
    /// Blob SHAs of files the op deleted locally, captured before the delete:
    /// `LocalStore.delete` drops the manifest entry, so the remote DELETE
    /// would otherwise have no sha to send.
    public var deletedShas: [String: String]?

    public init(op: PendingOp) {
        self.id = UUID()
        self.op = op
        self.queuedAt = Date()
        self.attempts = 0
    }

    /// Files the flush must push for this op.
    public var editedPaths: [String] {
        paths ?? op.editablePaths
    }
}

/// FIFO durable queue persisted next to the manifest.
///
/// **This file is user data, not a cache.** It holds mutations that exist
/// nowhere else until a flush reaches GitHub, so it is never discarded on a
/// bad read — see the contract on ``VersionedDocument`` before changing this
/// type or ``PendingOp``.
public struct PendingOpsQueue: Codable, Sendable, VersionedDocument {
    /// Still 1: `schemaVersion` is itself an additive field, and the shape
    /// every shipped build wrote (without the key) is version 1 by definition.
    /// Bump this only alongside a real break — a new `PendingOp` case, say.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = PendingOpsQueue.currentSchemaVersion
    public var pending: [QueuedOp] = []
    /// Ops that failed permanently (ambiguous / not-found after a remote
    /// change) — surfaced in Settings as "needs attention".
    public var failed: [QueuedOp] = []

    /// What the user calls this file when it goes wrong.
    static let documentName = "unsynced changes"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pending, failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Absent in every queue written before versioning existed. That shape
        // is version 1, and it has to keep decoding forever.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.initialSchemaVersion
        pending = try container.decodeIfPresent([QueuedOp].self, forKey: .pending) ?? []
        failed = try container.decodeIfPresent([QueuedOp].self, forKey: .failed) ?? []
    }

    /// Reads the queue, reporting rather than dropping anything unreadable:
    /// a file that can't be decoded is moved aside by ``PersistedState`` and
    /// the caller starts empty from there, with an issue to show the user.
    static func load(from url: URL) -> (queue: PendingOpsQueue, issue: StorageIssue?) {
        let result = PersistedState.load(PendingOpsQueue.self, from: url, document: documentName)
        return (result.value ?? PendingOpsQueue(), result.issue)
    }

    /// Returns the failure instead of swallowing it — a queue that can't be
    /// written is offline work that dies when the app is killed, and the user
    /// gets to know that before it happens.
    @discardableResult
    func save(to url: URL) -> StorageIssue? {
        PersistedState.save(self, to: url, document: Self.documentName)
    }
}
