import Foundation

/// The `.phren-team.yaml` a team store repo carries at its root — phren's only
/// *self-describing* store marker.
///
/// Transcribes `readTeamBootstrap` (packages/cli/src/store-registry.ts:220)
/// and the file `phren team init` writes (cli/team.ts:73): three flat keys,
/// one per line.
///
/// ```yaml
/// name: arc-team
/// description: Arc platform team
/// default_role: team
/// ```
///
/// **Why the app reads this rather than only `stores.yaml`.** The registry
/// lives at the *primary* store's root (`~/.phren/stores.yaml`) and describes
/// stores by local filesystem path; a team store repo never contains it. So a
/// phone that has attached the team repo — but not the personal store that
/// registers it — can learn a store's role from this file and from nothing
/// else. It is also what the CLI itself trusts: `phren store add` takes the
/// role from `bootstrap?.default_role` in preference to the flag the user
/// passed (cli/namespaces-store.ts:147).
public struct TeamBootstrap: Equatable, Sendable {
    public static let fileName = ".phren-team.yaml"

    public var name: String
    public var description: String?
    /// Raw role string, kept as-is for the same reason ``StoresManifest/Entry``
    /// keeps its own: an unrecognized future role should still parse.
    /// `readTeamBootstrap` drops values outside `primary | team | readonly`
    /// (store-registry.ts:231), and so does this.
    public var defaultRole: String?

    public init(name: String, description: String? = nil, defaultRole: String? = nil) {
        self.name = name
        self.description = description
        self.defaultRole = defaultRole
    }

    /// store-registry.ts:12 `StoreRole`
    public static let validRoles: Set<String> = ["primary", "team", "readonly"]

    /// The role this store should be treated as. A bootstrap file that names
    /// no role still means "team": the file exists only in a store created by
    /// `phren team init`, which always writes `default_role: team`
    /// (cli/team.ts:80).
    public var role: String { defaultRole ?? "team" }

    /// Parses the file, or returns nil the way `readTeamBootstrap` does — a
    /// missing or non-string `name` is the CLI's single rejection rule
    /// (store-registry.ts:227), and everything else is read tolerantly.
    ///
    /// Hand-rolled for the same reason ``StoresManifest`` is: the app carries
    /// no YAML dependency, and this file is three flat scalars. Values are
    /// split on the *first* colon, which is if anything more forgiving than
    /// `js-yaml` (an unquoted `description:` containing a colon fails to load
    /// there, and takes the whole file with it).
    public static func parse(_ content: String) -> TeamBootstrap? {
        var name: String?
        var description: String?
        var defaultRole: String?

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            // Only top-level scalars; anything indented belongs to a nested
            // structure this shape doesn't have.
            guard line == line.trimmingCharacters(in: .whitespaces) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "name": name = value
            case "description": description = value
            case "default_role": defaultRole = validRoles.contains(value) ? value : nil
            default: break
            }
        }

        guard let name else { return nil }
        return TeamBootstrap(name: name, description: description, defaultRole: defaultRole)
    }
}
