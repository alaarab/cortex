import Foundation

/// Transcription of `METADATA_REGEX` and its parsing/strip helpers from
/// packages/cli/src/content/metadata.ts. Each pattern carries a comment citing
/// the TypeScript original; keep the two in lockstep when the CLI format evolves.
enum MetadataRegex {
    // metadata.ts:21 — `<!-- phren:status "active" -->`
    static let status = JSRegex(
        #"<!--\s*phren:status\s+"?(active|superseded|contradicted|stale|invalid_citation|retracted)"?\s*-->"#,
        caseInsensitive: true
    )

    // metadata.ts:46 — `<!-- phren:superseded_by "text" 2025-01-01 -->`
    static let supersededBy = JSRegex(
        #"<!--\s*phren:superseded_by\s+"([^"]+)"(?:\s+([0-9]{4}-[0-9]{2}-[0-9]{2}))?\s*-->"#,
        caseInsensitive: true
    )

    // metadata.ts:52 — legacy `<!-- superseded_by: "text" -->`
    static let supersededByLegacy = JSRegex(#"<!--\s*superseded_by:\s*"([^"]+)"\s*-->"#, caseInsensitive: true)

    // metadata.ts:55 — `<!-- phren:supersedes "text" -->`
    static let supersedes = JSRegex(#"<!--\s*phren:supersedes\s+"([^"]+)"\s*-->"#, caseInsensitive: true)

    // metadata.ts:58 — `<!-- phren:contradicts "text" -->`
    static let contradicts = JSRegex(#"<!--\s*phren:contradicts\s+"([^"]+)"\s*-->"#, caseInsensitive: true)

    // metadata.ts:61 — global version for matchAll (case-sensitive in the TS source)
    static let contradictsAll = JSRegex(#"<!--\s*phren:contradicts\s+"([^"]+)"\s*-->"#)

    // metadata.ts:64 — legacy `<!-- conflicts_with: "text" (from project: foo) -->`
    static let conflictsWith = JSRegex(
        #"<!--\s*conflicts_with:\s*"([^"]+)"(?:\s*\(from project:\s*[^)]+\))?\s*-->"#,
        caseInsensitive: true
    )

    // metadata.ts:70 — full-line `<!-- phren:cite {...} -->`
    static let citation = JSRegex(#"^\s*<!--\s*phren:cite\s+\{.*\}\s*-->\s*$"#)

    // metadata.ts:73 — opening marker for JSON payload extraction
    static let citationMarker = JSRegex(#"<!--\s*phren:cite\s+"#)

    // metadata.ts:76,79 — archive block markers
    static let archiveStart = JSRegex(#"<!--\s*phren:archive:start\s*-->"#)
    static let archiveEnd = JSRegex(#"<!--\s*phren:archive:end\s*-->"#)
    static let detailsOpen = JSRegex(#"^<details(?:\s|>)"#, caseInsensitive: true)
    static let detailsClose = JSRegex(#"^</details>"#, caseInsensitive: true)

    // metadata.ts:82 — `<!-- fid:abcd1234 -->`
    static let findingId = JSRegex(#"<!--\s*fid:([a-z0-9]{8})\s*-->"#, caseInsensitive: true)

    // metadata.ts:85 — `<!-- created: 2025-01-01 -->`
    static let createdDate = JSRegex(#"<!--\s*created:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*-->"#, caseInsensitive: true)

    // metadata.ts:91 — `<!-- source:... -->`
    static let source = JSRegex(#"<!--\s*source:\s*(.*?)\s*-->"#)

    // metadata.ts:94 — any HTML comment (non-greedy)
    static let anyComment = JSRegex(#"<!--.*?-->"#)

    // citation.ts:140 — standalone `<!-- scope:VALUE -->`
    static let scopeComment = JSRegex(#"<!--\s*scope:(".*?"|\S+)\s*-->"#)

    // metadata.ts helpers -----------------------------------------------------

    // metadata.ts:36 — quoted status field (status_updated / status_reason / status_ref)
    static func statusField(_ field: String) -> JSRegex {
        JSRegex("<!--\\s*phren:\(field)\\s+\"([^\"]+)\"\\s*-->", caseInsensitive: true)
    }

    // metadata.ts:41 — raw (unquoted) fallback for status fields
    static func statusFieldRaw(_ field: String) -> JSRegex {
        JSRegex("<!--\\s*phren:\(field)\\s+([^>]+?)\\s*-->", caseInsensitive: true)
    }
}

// MARK: - Parsing helpers (metadata.ts:137-244)

/// metadata.ts:137 `parseStatus`
func parseStatus(_ line: String) -> String? {
    MetadataRegex.status.group(line)?.lowercased()
}

/// metadata.ts:142 `parseStatusField`
func parseStatusField(_ line: String, _ field: String) -> String? {
    if let quoted = MetadataRegex.statusField(field).group(line) {
        return quoted.collapsedWhitespace.jsTrimmed
    }
    if let raw = MetadataRegex.statusFieldRaw(field).group(line) {
        return raw.collapsedWhitespace.jsTrimmed
    }
    return nil
}

/// metadata.ts:150 `parseSupersession`
func parseSupersession(_ line: String) -> (ref: String, date: String?)? {
    if let m = MetadataRegex.supersededBy.firstMatch(in: line),
       let ref = JSRegex.substring(line, m, 1) {
        return (ref, JSRegex.substring(line, m, 2))
    }
    if let ref = MetadataRegex.supersededByLegacy.group(line) {
        return (ref, nil)
    }
    return nil
}

/// metadata.ts:164 `parseContradiction`
func parseContradiction(_ line: String) -> String? {
    MetadataRegex.contradicts.group(line) ?? MetadataRegex.conflictsWith.group(line)
}

/// metadata.ts:173 `parseAllContradictions`
func parseAllContradictions(_ line: String) -> [String] {
    MetadataRegex.contradictsAll.allGroups(line)
}

/// metadata.ts:178 `parseFindingId`
func parseFindingId(_ line: String) -> String? {
    MetadataRegex.findingId.group(line)
}

/// metadata.ts:183 `parseCreatedDate`
func parseCreatedDate(_ line: String) -> String? {
    MetadataRegex.createdDate.group(line)
}

/// metadata.ts:188 `isCitationLine`
func isCitationLine(_ line: String) -> Bool {
    MetadataRegex.citation.test(line.jsTrimmed)
}

/// metadata.ts:193 `isArchiveStart`
func isArchiveStart(_ line: String) -> Bool {
    MetadataRegex.archiveStart.test(line) || MetadataRegex.detailsOpen.test(line.jsTrimmed)
}

/// metadata.ts:198 `isArchiveEnd`
func isArchiveEnd(_ line: String) -> Bool {
    MetadataRegex.archiveEnd.test(line) || MetadataRegex.detailsClose.test(line.jsTrimmed)
}

/// metadata.ts:231 `stripComments`
func stripComments(_ text: String) -> String {
    MetadataRegex.anyComment.replaceAll(text, with: "").jsTrimmed
}

/// metadata.ts:236 `normalizeFindingText` — the canonical needle used for
/// finding matching. Must stay byte-identical to the TS version or edit/remove
/// operations will resolve to different bullets than the CLI would.
func normalizeFindingText(_ raw: String) -> String {
    var s = JSRegex(#"^-\s+"#).replaceFirst(raw, with: "")
    s = MetadataRegex.anyComment.replaceAll(s, with: " ")
    s = JSRegex(#"\[confidence\s+[01](?:\.\d+)?\]"#, caseInsensitive: true).replaceAll(s, with: " ")
    s = s.collapsedWhitespace
    return s.jsTrimmed.lowercased()
}
