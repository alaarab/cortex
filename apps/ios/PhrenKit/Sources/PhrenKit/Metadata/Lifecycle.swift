import Foundation

// Transcriptions from packages/cli/src/finding/lifecycle.ts.

/// Mirrors `FindingLifecycleMetadata` (lifecycle.ts).
struct FindingLifecycleMetadata {
    var status: FindingLifecycleStatus = .active
    var statusUpdated: String?
    var statusReason: String?
    var statusRef: String?
}

/// lifecycle.ts `cleanCommentValue`
private func cleanCommentValue(_ value: String) -> String {
    value.collapsedWhitespace.jsTrimmed
}

/// lifecycle.ts `serializeCommentValue`
private func serializeCommentValue(_ value: String) -> String {
    cleanCommentValue(value).replacingOccurrences(of: "\"", with: "'")
}

/// lifecycle.ts:78 `parseFindingLifecycle`
func parseFindingLifecycle(_ line: String) -> FindingLifecycleMetadata {
    let created = parseCreatedDate(line).map(cleanCommentValue)
    let normalizedStatus = parseStatus(line).flatMap(FindingLifecycleStatus.init(rawValue:))

    var normalized = FindingLifecycleMetadata(
        status: normalizedStatus ?? .active,
        statusUpdated: parseStatusField(line, "status_updated") ?? created,
        statusReason: parseStatusField(line, "status_reason"),
        statusRef: parseStatusField(line, "status_ref")
    )

    if normalizedStatus != nil { return normalized }

    if let supersession = parseSupersession(line) {
        let updated = supersession.date ?? normalized.statusUpdated
        return FindingLifecycleMetadata(
            status: .superseded,
            statusUpdated: updated.map(cleanCommentValue),
            statusReason: normalized.statusReason ?? "superseded_by",
            statusRef: normalized.statusRef ?? cleanCommentValue(supersession.ref)
        )
    }

    if let contradictionRef = parseContradiction(line) {
        return FindingLifecycleMetadata(
            status: .contradicted,
            statusUpdated: normalized.statusUpdated,
            statusReason: normalized.statusReason ?? "conflicts_with",
            statusRef: normalized.statusRef ?? cleanCommentValue(contradictionRef)
        )
    }

    return normalized
}

/// lifecycle.ts:115 `buildLifecycleComments`
func buildLifecycleComments(_ lifecycle: FindingLifecycleMetadata?, fallbackDate: String? = nil) -> String {
    let status = lifecycle?.status ?? .active
    let statusUpdated = lifecycle?.statusUpdated ?? fallbackDate
    var parts = ["<!-- phren:status \"\(status.rawValue)\" -->"]
    if let statusUpdated {
        parts.append("<!-- phren:status_updated \"\(serializeCommentValue(statusUpdated))\" -->")
    }
    if let reason = lifecycle?.statusReason {
        parts.append("<!-- phren:status_reason \"\(serializeCommentValue(reason))\" -->")
    }
    if let ref = lifecycle?.statusRef {
        parts.append("<!-- phren:status_ref \"\(serializeCommentValue(ref))\" -->")
    }
    return parts.joined(separator: " ")
}

/// lifecycle.ts:37 `extractFindingType` — recognizes any tag key in
/// FINDING_TYPE_DECAY (a superset of FINDING_TYPES).
private let findingTypeDecayTags: Set<String> = [
    "pattern", "decision", "pitfall", "anti-pattern", "observation",
    "workaround", "bug", "tooling", "context",
]

func extractFindingType(_ line: String) -> String? {
    guard let tag = JSRegex(#"\[(\w[\w-]*)\]"#).group(line)?.lowercased() else { return nil }
    return findingTypeDecayTags.contains(tag) ? tag : nil
}
