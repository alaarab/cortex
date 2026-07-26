import Foundation

/// On-device full-text search over the parsed snapshot. A simple in-memory
/// inverted index: at phren's documented scale (docs/performance.md treats
/// <1K findings as "small") a full rebuild per sync is milliseconds.
/// Archived content is excluded, matching the CLI's FTS index behavior.
public struct SearchIndex: Sendable {
    public enum DocKind: String, CaseIterable, Sendable {
        case finding, note, task, summary
    }

    public struct Result: Identifiable, Equatable, Sendable {
        public let id: String
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
        var docs: [Doc] = []
        for (project, findings) in snapshot.findings {
            for finding in findings where !finding.archived {
                docs.append(Self.doc(
                    id: "f:\(project):\(finding.stableId ?? finding.id)",
                    project: project, kind: .finding, text: finding.text,
                    date: finding.date, typeTag: finding.typeTag
                ))
            }
        }
        for (project, notes) in snapshot.notes {
            for note in notes {
                docs.append(Self.doc(
                    id: "n:\(project):\(note.stableId)",
                    project: project, kind: .note, text: note.text,
                    date: note.date, typeTag: nil
                ))
            }
        }
        for (project, taskDoc) in snapshot.tasks {
            for task in taskDoc.allItems {
                docs.append(Self.doc(
                    id: "t:\(project):\(task.stableId ?? task.id)",
                    project: project, kind: .task, text: task.line,
                    date: task.createdAt.map { String($0.prefix(10)) }, typeTag: nil
                ))
            }
        }
        for (project, summary) in snapshot.summaries {
            for (i, paragraph) in summary.components(separatedBy: "\n\n").enumerated() {
                let trimmed = paragraph.jsTrimmed
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                docs.append(Self.doc(
                    id: "s:\(project):\(i)",
                    project: project, kind: .summary, text: trimmed,
                    date: nil, typeTag: nil
                ))
            }
        }
        self.docs = docs
    }

    private static func doc(id: String, project: String, kind: DocKind,
                            text: String, date: String?, typeTag: String?) -> Doc {
        Doc(id: id, project: project, kind: kind, text: text, date: date,
            typeTag: typeTag, tokens: tokenFrequencies(text))
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
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
    public func search(_ query: String, project: String? = nil,
                       kind: DocKind? = nil, typeTag: String? = nil,
                       limit: Int = 50) -> [Result] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var results: [Result] = []
        for doc in docs {
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
                id: doc.id, project: doc.project, kind: doc.kind,
                text: doc.text, date: doc.date, typeTag: doc.typeTag, score: score
            ))
        }
        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
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
