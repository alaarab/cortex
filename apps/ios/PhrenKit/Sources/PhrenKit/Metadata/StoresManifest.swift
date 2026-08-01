import Foundation

/// Hand-rolled parser for the CLI's root `stores.yaml` registry
/// (packages/cli/src/store-registry.ts `StoreRegistry`) — the file that
/// answers "which of my stores does this project actually belong to".
///
/// The app has no YAML dependency and doesn't want one for a file this
/// shape-constrained: `js-yaml`'s `dump` always renders this exact block
/// style (2-space list indent, keys one level deeper, nested lists one level
/// deeper still), so a line-by-line indentation walk is both sufficient and
/// far cheaper than a general YAML parser. Anything outside the shape below
/// (extra top-level keys, `path`/`remote`/`sync`/`version`, flow-style lists)
/// is read tolerantly and ignored rather than rejected — a store health
/// feature that throws on a registry field it doesn't understand yet would be
/// exactly the kind of silent failure this branch exists to prevent.
///
/// ```yaml
/// version: 1
/// stores:
///   - id: 365c6bb8
///     name: phren
///     path: ~/.phren
///     role: primary
///     sync: managed-git
///   - id: 67d3e4c9
///     name: work-shared
///     path: ~/.phren-work-shared
///     role: team
///     sync: managed-git
///     projects:
///       - alpha
///       - beta
/// ```
public struct StoresManifest: Equatable, Sendable {
    /// One `stores:` list entry. Only `name`, `role`, and `projects` are ever
    /// read by the app (see the file doc comment); `id` is captured too since
    /// it's free, but nothing keys off it today.
    public struct Entry: Equatable, Sendable {
        public var id: String?
        public var name: String
        /// Raw registry role string ("primary" | "team" | "readonly" per the
        /// CLI, but stored as-is rather than an enum so an unrecognized future
        /// role still parses instead of vanishing).
        public var role: String
        public var projects: [String]

        public init(id: String? = nil, name: String, role: String, projects: [String] = []) {
            self.id = id
            self.name = name
            self.role = role
            self.projects = projects
        }

        /// The registry guarantees exactly one `primary` entry
        /// (store-registry.ts `validateRegistry`); every other role is "not
        /// primary" as far as claim-checking cares.
        public var isPrimary: Bool { role == "primary" }
    }

    public var stores: [Entry]

    public init(stores: [Entry] = []) {
        self.stores = stores
    }

    public static let empty = StoresManifest()

    /// The entry whose `projects` list names `project`, provided that entry
    /// isn't a `primary` role and isn't the store the project physically
    /// lives in (`physicalStoreName`) — i.e. "this project is physically here,
    /// but the registry says it belongs to that other store." Returns the
    /// first such match; the CLI's own validation already rejects registries
    /// with duplicate store names, so more than one match would itself be a
    /// malformed registry.
    public func claimingEntry(for project: String, physicalStoreName: String?) -> Entry? {
        stores.first { entry in
            !entry.isPrimary
                && entry.name != physicalStoreName
                && entry.projects.contains(project)
        }
    }

    // MARK: - Parsing

    /// Parses `stores.yaml` content into a manifest. Never throws: a missing
    /// `stores:` key, an empty file, or a garbled entry all just yield fewer
    /// (or zero) entries rather than an error — the caller has no recovery
    /// action for a malformed registry beyond "don't show claim badges today".
    public static func parse(_ content: String) -> StoresManifest {
        var entries: [Entry] = []
        var current: Entry?
        var entryIndent: Int?
        var keyIndent: Int?
        var projectsMode = false
        var inStores = false

        func flush() {
            if let current, !current.name.isEmpty { entries.append(current) }
            current = nil
            projectsMode = false
        }

        func apply(_ pair: Substring, to entry: inout Entry) {
            guard let colon = pair.firstIndex(of: ":") else { return }
            let key = pair[pair.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var value = pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "id": entry.id = value.isEmpty ? nil : value
            case "name": entry.name = value
            case "role": entry.role = value
            case "projects":
                // Flow-style inline list ("projects: [alpha, beta]"), in case
                // a registry is ever hand-edited rather than CLI-written.
                if value.hasPrefix("["), value.hasSuffix("]") {
                    entry.projects = value.dropFirst().dropLast()
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
            default: break // path, sync, remote, version, and anything future — ignored, not an error.
            }
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count

            if indent == 0 {
                if trimmed == "stores:" {
                    inStores = true
                } else if inStores {
                    // Any other top-level key (or the same "stores:" file's
                    // trailing content) ends the list.
                    flush()
                    inStores = false
                }
                continue
            }
            guard inStores else { continue }

            let isDashLine = trimmed.hasPrefix("-")
            if isDashLine, entryIndent == nil {
                // First entry of the list — establishes the indent this whole
                // registry uses for "- key: value" entry starts.
                entryIndent = indent
                keyIndent = indent + 2
            }

            if isDashLine, indent == entryIndent {
                flush()
                current = Entry(name: "", role: "")
                let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { apply(Substring(rest), to: &current!) }
                continue
            }

            guard current != nil else { continue }

            if isDashLine, projectsMode, let keyIndent, indent > keyIndent {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { current!.projects.append(item) }
                continue
            }

            // A non-list-item line at (or past) the entry's key indent is a
            // "key: value" continuation — and, since only "projects:" ever
            // opens a nested block, anything else closes that block.
            projectsMode = false
            apply(Substring(trimmed), to: &current!)
            if trimmed.hasPrefix("projects:") {
                let value = trimmed.dropFirst("projects:".count).trimmingCharacters(in: .whitespaces)
                projectsMode = value.isEmpty
            }
        }
        flush()
        return StoresManifest(stores: entries)
    }
}
