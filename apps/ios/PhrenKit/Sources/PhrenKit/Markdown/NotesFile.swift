import Foundation

/// Parser + renderer for one day's notes file (`notes/YYYY-MM-DD.md`).
///
/// Transcribes packages/cli/src/data/notes.ts. Unlike FINDINGS.md, the CLI
/// fully re-renders this file on every mutation (`renderDailyFile`,
/// notes.ts:115), so whole-file re-serialization here matches CLI behavior
/// exactly. An empty file (last note removed) means "delete the file".
public struct NotesFile: Sendable {
    public static let maxNoteLength = 10_000

    public let project: String
    public let date: String
    public private(set) var notes: [Note]

    // notes.ts:39 NOTE_HEADING_RE
    static let headingRegex = JSRegex(
        #"^##\s+(\d{2}:\d{2}(?::\d{2})?)\s+<!--\s*nid:([a-f0-9]{8})\s*-->(?:\s+<!--\s*promoted\s*-->)?\s*$"#,
        caseInsensitive: true
    )
    static let promotedRegex = JSRegex(#"<!--\s*promoted\s*-->"#, caseInsensitive: true)

    public init(project: String, date: String, content: String?) {
        self.project = project
        self.date = date
        self.notes = content.map { Self.parseDailyFile($0, project: project, date: date) } ?? []
    }

    // MARK: - Parse (notes.ts:74 parseDailyFile)

    static func parseDailyFile(_ content: String, project: String, date: String) -> [Note] {
        var items: [Note] = []
        var current: (stableId: String, time: String, promoted: Bool, body: [String])?

        func finish() {
            guard let c = current else { return }
            let text = c.body.joined(separator: "\n").jsTrimmed
            if !text.isEmpty {
                items.append(Note(
                    id: "nid:\(c.stableId)",
                    stableId: c.stableId,
                    project: project,
                    date: date,
                    time: c.time.count == 5 ? "\(c.time):00" : c.time,
                    text: text,
                    promoted: c.promoted
                ))
            }
        }

        for line in content.components(separatedBy: "\n") {
            if let m = headingRegex.firstMatch(in: line),
               let time = JSRegex.substring(line, m, 1),
               let nid = JSRegex.substring(line, m, 2) {
                finish()
                current = (nid.lowercased(), time, promotedRegex.test(line), [])
            } else if current != nil {
                current?.body.append(line)
            }
        }
        finish()
        return items
    }

    // MARK: - Render (notes.ts:115 renderDailyFile)

    /// Returns nil when there are no notes left — the caller deletes the file
    /// (notes.ts:207).
    public func render() -> String? {
        guard !notes.isEmpty else { return nil }
        let entries = notes.map { note -> String in
            let promoted = note.promoted ? " <!-- promoted -->" : ""
            return "## \(note.time) <!-- nid:\(note.stableId) -->\(promoted)\n\n\(note.text)"
        }
        return "# \(project) Notes — \(date)\n\n\(entries.joined(separator: "\n\n"))\n"
    }

    // MARK: - Mutations (notes.ts:163-225)

    /// notes.ts:60 `normalizeNoteText`
    static func normalizeNoteText(_ text: String) throws -> String {
        let normalized = JSRegex(#"\r\n?"#).replaceAll(text, with: "\n").jsTrimmed
        guard !normalized.isEmpty else { throw PhrenKitError.emptyInput("Note text cannot be empty.") }
        guard normalized.count <= maxNoteLength else {
            throw PhrenKitError.validation("Note text exceeds \(maxNoteLength) characters.")
        }
        if let secret = SecretScanner.scan(normalized) {
            throw PhrenKitError.secretDetected(
                "Rejected: note appears to contain a secret (\(secret)). Strip credentials before saving."
            )
        }
        // notes.ts:71 — a body line that would parse as a heading gets #-prefixed.
        return normalized.components(separatedBy: "\n")
            .map { headingRegex.test($0) ? "#\($0)" : $0 }
            .joined(separator: "\n")
    }

    @discardableResult
    public mutating func add(text: String, time: String) throws -> Note {
        let normalized = try Self.normalizeNoteText(text)
        var stableId = FindingsFile.randomHexId()
        while notes.contains(where: { $0.stableId == stableId }) {
            stableId = FindingsFile.randomHexId()
        }
        let note = Note(
            id: "nid:\(stableId)", stableId: stableId, project: project,
            date: date, time: time, text: normalized, promoted: false
        )
        notes.append(note)
        return note
    }

    private func indexOf(stableId: String) throws -> Int {
        guard let idx = notes.firstIndex(where: { $0.stableId == stableId }) else {
            throw PhrenKitError.notFound("No note matching \"nid:\(stableId)\" was found.")
        }
        return idx
    }

    @discardableResult
    public mutating func edit(stableId: String, text: String) throws -> Note {
        let normalized = try Self.normalizeNoteText(text)
        let idx = try indexOf(stableId: stableId)
        notes[idx].text = normalized
        return notes[idx]
    }

    @discardableResult
    public mutating func remove(stableId: String) throws -> Note {
        let idx = try indexOf(stableId: stableId)
        return notes.remove(at: idx)
    }

    /// notes.ts:223 `markNotePromoted`. Promotion itself is a two-file
    /// operation (core/note.ts:13 promoteNote): the caller first adds the
    /// finding to FINDINGS.md, then marks the note here; a note that is
    /// already promoted must be refused before the finding write.
    @discardableResult
    public mutating func markPromoted(stableId: String) throws -> Note {
        let idx = try indexOf(stableId: stableId)
        guard !notes[idx].promoted else {
            throw PhrenKitError.validation("Note nid:\(stableId) has already been promoted.")
        }
        notes[idx].promoted = true
        return notes[idx]
    }
}
