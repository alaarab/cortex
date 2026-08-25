import Foundation

/// A parsed `reference/topics/<slug>.md` — the cold tier's on-disk shape.
///
/// Written by `appendArchivedEntriesToTopicDoc`
/// (packages/cli/src/project-topics.ts:799): a `# <project> - <Label>`
/// heading, a `<!-- phren:auto-topic slug=… -->` marker, then
/// `## Archived YYYY-MM-DD` sections of ordinary finding bullets, citations
/// and all.
///
/// The bullets are parsed by ``FindingsFile`` itself rather than by a second
/// parser: `extractDateHeading` (access.ts:164) already understands the
/// `## Archived <date>` heading form, so a topic doc and a live FINDINGS.md
/// differ only in what the entries *mean*. Every entry that comes out of here
/// is stamped `archived` — read-only in `FindingsFile`'s own mutation guard,
/// and excluded by construction from `SearchIndex`, which only indexes
/// `!finding.archived`.
public struct TopicDocument: Sendable {
    public let project: String
    public let slug: String
    /// The document's own `# ` heading, or the humanized slug when the file
    /// was written before that heading existed.
    public let title: String
    public let entries: [Finding]

    public init(project: String, slug: String, content: String) {
        self.project = project
        self.slug = slug
        self.title = Self.heading(in: content) ?? slug
        self.entries = FindingsFile(content: content).parse().map { entry in
            var archived = entry
            archived.archived = true
            return archived
        }
    }

    public init(reference: ColdDocRef, content: String) {
        self.init(project: reference.project, slug: reference.slug, content: content)
    }

    /// Archived entries newest-day first, matching how the Findings tab groups
    /// the hot tier.
    public var groupedByDate: [(date: String, entries: [Finding])] {
        let groups = Dictionary(grouping: entries, by: \.date)
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    /// `# myproj - Build tooling` → `Build tooling`; a heading without the
    /// `<project> - ` prefix is taken whole.
    private static func heading(in content: String) -> String? {
        guard let line = content.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) else {
            return nil
        }
        let text = String(line.dropFirst(2)).jsTrimmed
        guard let separator = text.range(of: " - ") else { return text.isEmpty ? nil : text }
        let label = String(text[separator.upperBound...]).jsTrimmed
        return label.isEmpty ? text : label
    }
}
