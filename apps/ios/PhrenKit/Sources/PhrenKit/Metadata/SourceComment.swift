import Foundation

// Transcriptions from packages/cli/src/content/citation.ts.

/// citation.ts:100 `buildCitationComment`
func buildCitationComment(_ citation: FindingCitation) -> String {
    // JSON.stringify key order in the TS source follows FindingCitation field
    // order; reproduce it for tidy diffs.
    var parts: [String] = []
    func add(_ key: String, _ value: String?) {
        guard let value else { return }
        parts.append("\"\(key)\":\(jsonString(value))")
    }
    add("created_at", citation.createdAt)
    add("repo", citation.repo)
    add("file", citation.file)
    if let line = citation.line { parts.append("\"line\":\(line)") }
    add("commit", citation.commit)
    add("supersedes", citation.supersedes)
    add("task_item", citation.taskItem)
    return "<!-- phren:cite {\(parts.joined(separator: ","))} -->"
}

private func jsonString(_ value: String) -> String {
    // Minimal JSON string encoder matching JSON.stringify for our payloads.
    var out = "\""
    for scalar in value.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// citation.ts:104 `readSourceToken`
private func readSourceToken(_ raw: String?) -> String? {
    guard let raw = raw?.jsTrimmed, !raw.isEmpty else { return nil }
    if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
        return String(raw.dropFirst().dropLast())
    }
    return raw
}

/// citation.ts:120 `buildSourceComment`
func buildSourceComment(_ source: FindingProvenance) -> String {
    var parts: [String] = []
    if let v = source.source { parts.append(v) }
    if let v = source.machine { parts.append("machine:\(v)") }
    if let v = source.actor { parts.append("actor:\(v)") }
    if let v = source.tool { parts.append("tool:\(v)") }
    if let v = source.model { parts.append("model:\(v)") }
    if let v = source.sessionId { parts.append("session:\(v)") }
    if let v = source.scope { parts.append("scope:\(v)") }
    return parts.isEmpty ? "" : "<!-- source:\(parts.joined(separator: " ")) -->"
}

/// citation.ts:133 `buildScopeComment`
func buildScopeComment(_ scope: String?) -> String {
    guard let scope, !scope.isEmpty, scope != "shared" else { return "" }
    return "<!-- scope:\(scope) -->"
}

/// citation.ts:139 `parseScopeComment`
func parseScopeComment(_ line: String) -> String? {
    guard let raw = MetadataRegex.scopeComment.group(line) else { return nil }
    let unquoted = JSRegex(#"^"|"$"#).replaceAll(raw, with: "").jsTrimmed
    return unquoted.isEmpty ? nil : unquoted
}

private let provenanceSources: Set<String> = ["human", "agent", "hook", "import", "consolidation", "unknown"]

/// citation.ts:146 `parseSourceComment`
func parseSourceComment(_ line: String) -> FindingProvenance? {
    guard let payload = MetadataRegex.source.group(line) else { return nil }

    let firstToken = payload.jsTrimmed.split(separator: " ").first.map(String.init) ?? ""
    func token(_ key: String) -> String? {
        readSourceToken(JSRegex("(?:^|\\s)\(key):(\".*?\"|\\S+)").group(payload))
    }

    let sourceRaw: String? = {
        if !firstToken.isEmpty, !firstToken.contains(":") { return firstToken }
        return token("source") ?? token("kind")
    }()
    let source = sourceRaw.flatMap { provenanceSources.contains($0) ? $0 : nil }
    let machine = token("machine") ?? token("host")
    let actor = token("actor") ?? token("agent")
    let tool = token("tool")
    let model = token("model")
    let sessionId = token("session") ?? token("session_id")
    let rawScope = token("scope")
    let scope: String? = rawScope.map { $0.jsTrimmed.isEmpty ? "shared" : $0.jsTrimmed }

    let provenance = FindingProvenance(
        source: source, machine: machine, actor: actor, tool: tool,
        model: model, sessionId: sessionId, scope: scope
    )
    return provenance.isEmpty ? nil : provenance
}

/// citation.ts:177 `parseCitationComment` — marker-based extraction so multiline
/// or escaped JSON payloads survive.
func parseCitationComment(_ line: String) -> FindingCitation? {
    guard let marker = MetadataRegex.citationMarker.firstMatch(in: line),
          let markerRange = Range(marker.range, in: line) else { return nil }
    let jsonStart = markerRange.upperBound
    guard let endMarker = line.range(of: "-->", range: jsonStart..<line.endIndex) else { return nil }
    let jsonStr = String(line[jsonStart..<endMarker.lowerBound]).jsTrimmed
    guard jsonStr.hasPrefix("{"), let data = jsonStr.data(using: .utf8) else { return nil }
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    guard let createdAt = parsed["created_at"] as? String, !createdAt.isEmpty else { return nil }
    return FindingCitation(
        createdAt: createdAt,
        repo: parsed["repo"] as? String,
        file: parsed["file"] as? String,
        line: (parsed["line"] as? NSNumber)?.intValue,
        commit: parsed["commit"] as? String,
        supersedes: parsed["supersedes"] as? String,
        taskItem: parsed["task_item"] as? String
    )
}
