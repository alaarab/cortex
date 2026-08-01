import Foundation
import PhrenKit

/// One capture, as the user would describe it: "the thing I said, and where it
/// went". Kept so "where did that go?" has an answer inside the app instead of
/// requiring a search through nine projects on GitHub.
struct CaptureLogEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case note
        case task

        var label: String { self == .note ? "Note" : "Task" }
        var systemImage: String { self == .note ? "note.text" : "checklist" }
    }

    /// Which surface made the capture — the difference between "I typed this
    /// into the app" and "this happened while my phone was in my pocket".
    enum Source: String, Codable {
        case siri
        case app

        var label: String { self == .siri ? "Siri / Shortcuts" : "In app" }
    }

    let id: UUID
    let at: Date
    let kind: Kind
    /// Store-qualified destination, same addressing unit as everything else in
    /// the capture path — never the bare project name.
    let storeId: String
    let project: String
    let snippet: String
    let source: Source

    /// Matches this entry against the pending-op queue. Not an op id: the
    /// queue is written by PhrenKit and an op carries no back-reference, so the
    /// log identifies its op by what it *is* (destination + kind + the same
    /// truncated text), which is stable across the queue's own re-encoding.
    var fingerprint: String {
        CaptureLog.fingerprint(kind: kind, storeId: storeId, project: project, snippet: snippet)
    }
}

/// The last few captures, newest first, persisted next to the capture default.
///
/// Deliberately small and lossy — 20 entries of at most ~80 characters each.
/// This is a receipt drawer, not a second copy of the store: the capture itself
/// lives in the markdown, and the entry exists only to say where that markdown
/// is and whether it has left the device yet.
enum CaptureLog {
    static let limit = 20
    /// Long enough to recognize a dictated sentence, short enough that a row
    /// stays a row.
    static let snippetLength = 80

    private static let key = "phren.capture.log"

    static func entries() -> [CaptureLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([CaptureLogEntry].self, from: data) else { return [] }
        return entries
    }

    /// Appends a capture that has actually been accepted by a store. Callers
    /// record only after the write succeeded — a log entry for something that
    /// was rejected would be a worse lie than no entry at all.
    static func record(
        kind: CaptureLogEntry.Kind,
        storeId: String,
        project: String,
        text: String,
        source: CaptureLogEntry.Source
    ) {
        let entry = CaptureLogEntry(
            id: UUID(),
            at: Date(),
            kind: kind,
            storeId: storeId,
            project: project,
            snippet: snippet(text),
            source: source
        )
        let trimmed = Array(([entry] + entries()).prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// First line-ish of the capture: whitespace collapsed so a dictated
    /// paragraph doesn't render as a ragged block, then truncated.
    static func snippet(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > snippetLength else { return collapsed }
        return String(collapsed.prefix(snippetLength)) + "…"
    }

    /// The fingerprint of a queued op, or nil when the op isn't a capture
    /// (edits, approvals and completions never appear in this log).
    static func fingerprint(storeId: String, op: PendingOp) -> String? {
        switch op {
        case .addNote(let project, _, _, let text):
            return fingerprint(kind: .note, storeId: storeId, project: project, snippet: snippet(text))
        case .addTask(let project, let text):
            return fingerprint(kind: .task, storeId: storeId, project: project, snippet: snippet(text))
        default:
            return nil
        }
    }

    static func fingerprint(kind: CaptureLogEntry.Kind, storeId: String, project: String, snippet: String) -> String {
        "\(kind.rawValue)|\(storeId)|\(project)|\(snippet)"
    }
}

/// How far along a logged capture is. Read off the pending-op queue rather
/// than stored: the queue is the truth, and an entry that outlives its op is
/// simply one that has shipped.
enum CaptureSyncState: Equatable {
    case synced
    case queued
    case failed

    var label: String {
        switch self {
        case .synced: return "synced"
        case .queued: return "waiting to sync"
        case .failed: return "needs attention"
        }
    }

    var systemImage: String {
        switch self {
        case .synced: return "checkmark.circle"
        case .queued: return "arrow.up.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// The pending/failed fingerprints of every attached store, sampled once so a
/// list of rows doesn't re-await the engines per row.
struct CaptureQueueState {
    var pending: Set<String> = []
    var failed: Set<String> = []

    func state(of entry: CaptureLogEntry) -> CaptureSyncState {
        let fingerprint = entry.fingerprint
        if failed.contains(fingerprint) { return .failed }
        if pending.contains(fingerprint) { return .queued }
        return .synced
    }

    @MainActor
    static func sample(from model: AppModel) async -> CaptureQueueState {
        var state = CaptureQueueState()
        for (storeId, op) in await model.pendingOps() {
            if let fingerprint = CaptureLog.fingerprint(storeId: storeId, op: op) {
                state.pending.insert(fingerprint)
            }
        }
        for entry in await model.failedOps() {
            if let fingerprint = CaptureLog.fingerprint(storeId: entry.storeId, op: entry.op.op) {
                state.failed.insert(fingerprint)
            }
        }
        return state
    }
}
