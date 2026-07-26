import Foundation

/// The app's registry entry for one store: a GitHub repo the user added.
///
/// Deliberately not the CLI's `stores.yaml` schema — that registry holds local
/// filesystem paths and unnormalized (often SSH) git remotes, neither of which
/// is portable to the phone. Stores are added manually via the repo picker.
public struct StoreDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var owner: String
    public var name: String
    public var branch: String
    /// Whether the token has push permission (from `GitHubRepo.permissions`).
    /// False renders the store read-only in the UI.
    public var canPush: Bool

    public var id: String { "\(owner)/\(name)" }
    public var displayName: String { name }

    public init(owner: String, name: String, branch: String, canPush: Bool = true) {
        self.owner = owner
        self.name = name
        self.branch = branch
        self.canPush = canPush
    }

    enum CodingKeys: String, CodingKey {
        case owner, name, branch, canPush
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(String.self, forKey: .owner)
        name = try container.decode(String.self, forKey: .name)
        branch = try container.decode(String.self, forKey: .branch)
        // Absent in the legacy single-store `SelectedRepo` JSON (same
        // owner/name/branch shape) — default to writable; corrected on the
        // next repo fetch.
        canPush = try container.decodeIfPresent(Bool.self, forKey: .canPush) ?? true
    }
}
