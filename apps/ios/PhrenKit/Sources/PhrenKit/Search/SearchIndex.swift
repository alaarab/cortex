import Foundation

/// On-device full-text search over the parsed snapshot. A simple in-memory
/// index: at phren's documented scale (docs/performance.md treats <1K findings
/// as "small") a full rebuild per content change is milliseconds.
/// Archived content is excluded, matching the CLI's FTS index behavior.
public struct SearchIndex: Sendable {
    public enum DocKind: String, CaseIterable, Sendable {
        case finding, note, task, summary, review, truth
    }

    public struct Result: Identifiable, Equatable, Sendable {
        public let id: String
        /// Store the item came from ("" in single-store contexts).
        public let store: String
        public let project: String
        public let kind: DocKind
        public let text: String
        public let date: String?
        /// Finding type tag (for the type filter), when applicable.
        public let typeTag: String?
        public let score: Double
    }

    private struct Doc {
        let id: String
        let store: String
        let project: String
        let kind: DocKind
        let text: String
        let date: String?
        let typeTag: String?
        let tokens: [String: Int]
    }

    private var docs: [Doc] = []

    public init() {}

    public init(snapshot: LocalStore.Snapshot) {
        self.init(snapshots: [(store: "", snapshot: snapshot)])
    }

    /// Builds deterministically: dictionaries are iterated in sorted-key order
    /// so two builds over the same snapshot produce identically ordered docs —
    /// combined with the deterministic sort in `search`, equal-score results
    /// can no longer jitter between renders.
    public init(snapshots: [(store: String, snapshot: LocalStore.Snapshot)]) {
        var docs: [Doc] = []
        for (store, snapshot) in snapshots {
            for project in snapshot.findings.keys.sorted() {
                for finding in snapshot.findings[project] ?? [] where !finding.archived {
                    docs.append(Self.doc(
                        id: "f:\(store):\(project):\(finding.stableId ?? finding.id)",
                        store: store, project: project, kind: .finding, text: finding.text,
                        date: finding.date, typeTag: finding.typeTag,
                        // The fid is stripped from display text at parse time;
                        // feed it to the index directly so `a1b2c3d4` and
                        // `fid:a1b2c3d4` both find the finding.
                        extraTokens: [finding.stableId].compactMap { $0 }
                    ))
                }
            }
            for project in snapshot.notes.keys.sorted() {
                for note in snapshot.notes[project] ?? [] {
                    docs.append(Self.doc(
                        id: "n:\(store):\(project):\(note.stableId)",
                        store: store, project: project, kind: .note, text: note.text,
                        date: note.date, typeTag: nil,
                        extraTokens: [note.stableId]
                    ))
                }
            }
            for project in snapshot.tasks.keys.sorted() {
                for task in (snapshot.tasks[project]?.allItems ?? []) {
                    docs.append(Self.doc(
                        id: "t:\(store):\(project):\(task.stableId ?? task.id)",
                        store: store, project: project, kind: .task, text: task.line,
                        date: task.createdAt.map { String($0.prefix(10)) }, typeTag: nil,
                        extraTokens: [task.stableId].compactMap { $0 }
                    ))
                }
            }
            for item in snapshot.reviewQueue {
                docs.append(Self.doc(
                    id: "r:\(store):\(item.project):\(item.item.id)",
                    store: store, project: item.project, kind: .review, text: item.item.text,
                    date: item.item.date == "unknown" ? nil : item.item.date,
                    typeTag: Self.leadingTag(item.item.text)
                ))
            }
            for project in snapshot.summaries.keys.sorted() {
                for (i, paragraph) in (snapshot.summaries[project] ?? "").components(separatedBy: "\n\n").enumerated() {
                    let trimmed = paragraph.jsTrimmed
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    docs.append(Self.doc(
                        id: "s:\(store):\(project):\(i)",
                        store: store, project: project, kind: .summary, text: trimmed,
                        date: nil, typeTag: nil
                    ))
                }
            }
            // truths.md is indexed per bullet; CLAUDE.md deliberately is NOT —
            // instruction boilerplate would pollute every architecture query.
            // It still renders in the Docs UI.
            for project in snapshot.truths.keys.sorted() {
                var bulletIndex = 0
                for line in (snapshot.truths[project] ?? "").components(separatedBy: "\n") {
                    let trimmed = line.jsTrimmed
                    guard trimmed.hasPrefix("- ") else { continue }
                    docs.append(Self.doc(
                        id: "u:\(store):\(project):\(bulletIndex)",
                        store: store, project: project, kind: .truth,
                        text: String(trimmed.dropFirst(2)).jsTrimmed,
                        date: nil, typeTag: nil
                    ))
                    bulletIndex += 1
                }
            }
        }
        self.docs = docs
    }

    private static func doc(id: String, store: String, project: String, kind: DocKind,
                            text: String, date: String?, typeTag: String?,
                            extraTokens: [String] = []) -> Doc {
        var tokens = tokenFrequencies(text)
        // Searchable identity (fids/bids/nids, full dates) folded into the
        // frequency map — never into the display text.
        for token in extraTokens {
            tokens[token.lowercased(), default: 0] += 1
        }
        if let date, date.count == 10 {
            tokens[fuseDate(date), default: 0] += 1
        }
        return Doc(id: id, store: store, project: project, kind: kind, text: text, date: date,
                   typeTag: typeTag, tokens: tokens)
    }

    /// The `[tag]` prefix of a review-queue line, when present.
    private static func leadingTag(_ text: String) -> String? {
        JSRegex(#"^\[([a-z][a-z0-9_-]*)\]"#, caseInsensitive: true).group(text)?.lowercased()
    }

    static let datePattern = JSRegex(#"\b(\d{4})-(\d{2})-(\d{2})\b"#)
    static let idPrefixPattern = JSRegex(#"\b(?:fid|bid|nid|rid):"#, caseInsensitive: true)

    private static func fuseDate(_ date: String) -> String {
        date.replacingOccurrences(of: "-", with: "")
    }

    /// Tokenizer with a pre-pass, applied symmetrically to documents and
    /// queries: full dates fuse to one token (`2026-07-27` → `20260727`) so a
    /// date query matches its heading rather than shredding into `["2026",
    /// "07", "27"]`; `fid:`/`bid:`/`nid:`/`rid:` prefixes strip so a pasted id
    /// matches the bare hex the index carries.
    ///
    /// (Plain string replacement rather than a `$1$2$3` template — JSRegex's
    /// `replaceAll` deliberately escapes templates to match JS literal-string
    /// semantics, so capture references don't expand.)
    static func tokenize(_ text: String) -> [String] {
        var prepared = text.lowercased()
        for match in Set(datePattern.allMatches(prepared)) {
            prepared = prepared.replacingOccurrences(of: match, with: fuseDate(match))
        }
        prepared = idPrefixPattern.replaceAll(prepared, with: " ")
        return prepared
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func tokenFrequencies(_ text: String) -> [String: Int] {
        var frequencies: [String: Int] = [:]
        for token in tokenize(text) {
            frequencies[token, default: 0] += 1
        }
        return frequencies
    }

    /// Term-frequency scoring with prefix matching on the final query token
    /// (so search feels instant while typing) and a recency boost by date.
    public func search(_ query: String, store: String? = nil, project: String? = nil,
                       kind: DocKind? = nil, typeTag: String? = nil,
                       limit: Int = 50) -> [Result] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var results: [Result] = []
        for doc in docs {
            if let store, doc.store != store { continue }
            if let project, doc.project != project { continue }
            if let kind, doc.kind != kind { continue }
            if let typeTag, doc.typeTag != typeTag { continue }

            var score = 0.0
            var matchedAll = true
            for (i, token) in queryTokens.enumerated() {
                let isLast = i == queryTokens.count - 1
                if let tf = doc.tokens[token] {
                    score += Double(tf)
                } else if isLast, doc.tokens.keys.contains(where: { $0.hasPrefix(token) }) {
                    score += 0.5
                } else {
                    matchedAll = false
                    break
                }
            }
            guard matchedAll, score > 0 else { continue }

            // Recency boost: newer date headings rank higher.
            if let date = doc.date, date.count == 10 {
                score += Self.recencyBoost(date)
            }
            results.append(Result(
                id: doc.id, store: doc.store, project: doc.project, kind: doc.kind,
                text: doc.text, date: doc.date, typeTag: doc.typeTag, score: score
            ))
        }
        // Deterministic: id breaks score ties, so equal-score results hold
        // their order across renders (Swift's sort is not stable).
        return results
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    private static func recencyBoost(_ date: String) -> Double {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsed = formatter.date(from: date) else { return 0 }
        let ageDays = max(0, -parsed.timeIntervalSinceNow / 86_400)
        return max(0, 2.0 - ageDays / 90.0)
    }
}
