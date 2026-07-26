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

    /// Commit-message summary following the session-stop hook convention
    /// (`phren: <project>(findings)` — cli/session-stop.ts:354-378), suffixed
    /// with the app as the writing tool.
    public var commitMessage: String {
        let kind: String
        switch self {
        case .addFinding, .editFinding, .removeFinding: kind = "findings"
        case .approveQueue, .rejectQueue, .editQueue: kind = "update"
        case .addNote, .editNote, .removeNote, .promoteNote: kind = "update"
        case .addTask, .completeTask, .removeTask, .updateTask: kind = "task"
        }
        return "phren: \(project)(\(kind)) via ios"
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

    public init(op: PendingOp) {
        self.id = UUID()
        self.op = op
        self.queuedAt = Date()
        self.attempts = 0
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
