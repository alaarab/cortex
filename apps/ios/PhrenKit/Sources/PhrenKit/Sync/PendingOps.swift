import Foundation

/// A user mutation, expressed as a domain operation rather than a file diff so
/// it can be re-applied onto fresh content after a remote change (the
/// refetch-reapply half of sha-conflict recovery).
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
public struct PendingOpsQueue: Codable, Sendable {
    public var pending: [QueuedOp] = []
    /// Ops that failed permanently (ambiguous / not-found after a remote
    /// change) — surfaced in Settings as "needs attention".
    public var failed: [QueuedOp] = []

    static func load(from url: URL) -> PendingOpsQueue {
        guard let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode(PendingOpsQueue.self, from: data) else {
            return PendingOpsQueue()
        }
        return queue
    }

    func save(to url: URL) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
