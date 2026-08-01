import Foundation

/// Reader for a project's `truths.md` — phren's pinned, always-injected,
/// never-decaying memory.
///
/// Written by `upsertCanonical` (packages/cli/src/content/learning.ts:269) as
/// `- <memory> _(added YYYY-MM-DD)_` under a `## Truths` heading, and read by
/// both the CLI (`handleTruths`, cli/actions.ts:98) and the MCP `get_truths`
/// tool (tools/memory.ts:77) with the same one-liner: every line starting
/// `- `, sliced past the bullet.
///
/// Read-only by construction: `truths.md` is not in `LocalStore.isWritablePath`
/// and there is no phone-side pin flow, so this file parses and never
/// serializes. The app has been *downloading* it since the first release
/// (`isSyncedPath` lists it) and parsing it into nothing.
public struct TruthsFile: Sendable {
    public let content: String

    public init(content: String) {
        self.content = content
    }

    /// The pinned truths, in file order (newest first — `upsertCanonical`
    /// inserts each new one straight after the `## Truths` heading).
    public var truths: [Truth] {
        content.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") }
            .compactMap(Self.parse)
    }

    /// Splits `- text _(added 2026-08-01)_` into its two halves.
    ///
    /// Divergence from the CLI, which hands back the whole sliced line: the
    /// suffix is phren's own bookkeeping, not part of what the user pinned, so
    /// the app renders it as a date beside the truth rather than as words
    /// inside it. The text is otherwise untouched — comments and all.
    private static func parse(_ line: String) -> Truth? {
        let body = String(line.dropFirst(2)).jsTrimmed
        guard !body.isEmpty else { return nil }
        let suffix = JSRegex(#"\s*_\(added\s+(\d{4}-\d{2}-\d{2})\)_\s*$"#, caseInsensitive: true)
        guard let match = suffix.firstMatch(in: body),
              let whole = JSRegex.substring(body, match, 0),
              let date = JSRegex.substring(body, match, 1) else {
            return Truth(text: body, addedDate: nil)
        }
        let text = String(body.dropLast(whole.count)).jsTrimmed
        return text.isEmpty ? nil : Truth(text: text, addedDate: date)
    }
}
