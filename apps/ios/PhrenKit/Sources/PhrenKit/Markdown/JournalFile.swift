import Foundation

/// One team-store journal file: `<project>/journal/YYYY-MM-DD-<actor>.md`.
///
/// Transcribes the team-store half of `packages/cli/src/finding/journal.ts`
/// (`appendTeamJournal` at journal.ts:150, `readTeamJournalEntries` at
/// journal.ts:176). Everything above that line in the TS file is the *runtime*
/// JSONL journal under `.runtime/finding-journal/`, which the phone never sees.
///
/// **Why this file type exists at all.** A store with `role: team` never
/// line-splices `FINDINGS.md` on an add: `handleAddFinding` (tools/finding.ts:186)
/// appends to a per-actor, per-day markdown file and returns without touching
/// `FINDINGS.md`. One file per actor per day is the whole design — two people
/// capturing findings the same afternoon write two different files, so git
/// merges them instead of conflicting on adjacent lines in one. The app has to
/// honor the same layout in both directions or it either can't see what the
/// team wrote (the journal isn't in `FINDINGS.md`) or reintroduces exactly the
/// race the layout prevents.
///
/// Bullets are parsed by ``FindingsFile`` rather than by a second parser —
/// the same reuse ``TopicDocument`` makes for the cold tier. Only the date
/// heading differs (`## 2026-07-28 (tester)` carries an actor suffix that
/// `extractDateHeading` rejects), and the date is authoritative in the
/// *filename* anyway, which is where the CLI's own reader takes it from
/// (journal.ts:196).
public struct JournalFile: Sendable {
    /// journal.ts:143 `TEAM_JOURNAL_DIR`
    public static let directoryName = "journal"

    public let date: String
    public let actor: String
    /// `nil` means the file does not exist yet — the distinction the CLI draws
    /// with `fs.existsSync` (journal.ts:165) to decide whether an append needs
    /// to write the day's heading first.
    public private(set) var content: String?

    public init(date: String, actor: String, content: String? = nil) {
        self.date = date
        self.actor = actor
        self.content = content
    }

    // MARK: - Naming

    /// journal.ts:158 — `${date}-${resolvedActor}.md`
    public static func fileName(date: String, actor: String) -> String {
        "\(date)-\(actor).md"
    }

    public var fileName: String { Self.fileName(date: date, actor: actor) }

    /// The repo-relative path, i.e. what ``LocalStore`` keys a file by.
    public static func path(project: String, date: String, actor: String) -> String {
        "\(project)/\(directoryName)/\(fileName(date: date, actor: actor))"
    }

    public func path(project: String) -> String {
        Self.path(project: project, date: date, actor: actor)
    }

    /// journal.ts:196 — `/^(\d{4}-\d{2}-\d{2})-(.+)\.md$/`. The CLI reads a
    /// journal entry's date and actor from the filename and never from the
    /// heading, so this is the authoritative split.
    public static func parseFileName(_ name: String) -> (date: String, actor: String)? {
        let regex = JSRegex(#"^(\d{4}-\d{2}-\d{2})-(.+)\.md$"#)
        guard let match = regex.firstMatch(in: name),
              let date = JSRegex.substring(name, match, 1),
              let actor = JSRegex.substring(name, match, 2) else { return nil }
        return (date, actor)
    }

    /// A filename component safe to put between the date and `.md`.
    ///
    /// The CLI never sanitizes here — its actor is `$USER` (machine-identity.ts:41),
    /// already a path-safe token. The app's actor is a GitHub login (also safe)
    /// or, failing that, a device name like `Ala's iPhone`, which is not. This
    /// is the CLI's own sanitizer for the runtime journal's session ids
    /// (journal.ts:36) applied to the actor slot: the result still satisfies
    /// the `(.+)` the CLI's reader splits on, and can never introduce a path
    /// separator or escape the journal directory.
    public static func sanitizeActor(_ actor: String?) -> String {
        let raw = (actor ?? "").jsTrimmed
        let safe = JSRegex(#"[^a-zA-Z0-9._-]+"#).replaceAll(raw, with: "_")
        let trimmed = JSRegex(#"^_+|_+$"#).replaceAll(safe, with: "")
        // machine-identity.ts:41 — `getCurrentActor` falls back to "unknown".
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    // MARK: - Read (journal.ts:176 readTeamJournalEntries)

    /// The raw entry strings, metadata comments and all — exactly what
    /// `readTeamJournalEntries` reports (journal.ts:201).
    public var entries: [String] {
        (content ?? "").components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).jsTrimmed }
    }

    /// The file's entries as findings, for the same list `FINDINGS.md` feeds.
    ///
    /// `ids` continue from `offset` so a project's journal findings never
    /// collide with each other or with `FINDINGS.md`'s positional `L…` ids —
    /// `SearchIndex` keys documents by that id when a finding has no `fid:`,
    /// and a journal entry never does.
    public func findings(idOffset: Int = 0) -> [Finding] {
        FindingsFile(content: content ?? "").parse().enumerated().map { index, parsed in
            var finding = parsed
            finding.id = "J\(idOffset + index + 1)"
            // The heading inside the file carries the actor suffix that
            // `extractDateHeading` rejects, so every bullet parsed above came
            // back dated "unknown". The filename is the CLI's own source of
            // truth for both fields (journal.ts:196).
            finding.date = date
            finding.actor = finding.actor ?? actor
            finding.journalFile = fileName
            return finding
        }
    }

    // MARK: - Write (journal.ts:150 appendTeamJournal)

    /// Appends one finding, byte-for-byte as `appendTeamJournal` writes it
    /// (journal.ts:161-170): a `- ` bullet plus the provenance comment, onto
    /// an existing file, or after a `## <date> (<actor>)` heading and a blank
    /// line when the file is new.
    ///
    /// No dedup and no type auto-detection, matching the CLI's team branch —
    /// it appends what it was given (tools/finding.ts:191-196). Repeating
    /// yourself in an append-only log is a legitimate thing to do; suppressing
    /// it would need to read every other actor's file, which is exactly the
    /// cross-file coupling the layout exists to avoid.
    public mutating func append(_ finding: String, machine: String? = nil) {
        let sourceComment = buildSourceComment(
            FindingProvenance(source: "human", machine: machine, actor: actor)
        )
        let entry = "- \(finding)\(sourceComment.isEmpty ? "" : " \(sourceComment)")\n"
        if let existing = content {
            content = existing + entry
        } else {
            content = "## \(date) (\(actor))\n\n\(entry)"
        }
    }

    /// The bullet text an add would journal, with the type tag applied the way
    /// the CLI does before handing it to `appendTeamJournal`
    /// (`applyFindingTypePrefix`, core/finding.ts:24).
    ///
    /// Validation is deliberately *stricter* than the CLI's team branch, which
    /// returns before `addFindingToFile` ever runs its secret scan: a shared
    /// store is the last place a leaked credential should land, and the app
    /// promises it never commits what the CLI would reject.
    public static func preparedFinding(_ text: String, type: FindingType? = nil) throws -> String {
        let trimmed = text.jsTrimmed
        guard !trimmed.isEmpty else { throw PhrenKitError.emptyInput("Finding text cannot be empty.") }
        if let secret = SecretScanner.scan(trimmed) {
            throw PhrenKitError.secretDetected(
                "Rejected: finding appears to contain a secret (\(secret)). Strip credentials before saving."
            )
        }
        guard let type else { return trimmed }
        // core/finding.ts:16 — `/^\s*\[[^\]]+\]\s*/`
        if JSRegex(#"^\s*\[[^\]]+\]\s*"#).test(trimmed) { return trimmed }
        return "[\(type.rawValue)] \(trimmed)"
    }
}
