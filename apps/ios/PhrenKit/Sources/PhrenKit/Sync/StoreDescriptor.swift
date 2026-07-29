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
    /// A store created on this device with no GitHub repo behind it (yet).
    /// Local stores never sync; "Connect to GitHub" upgrades them by uploading
    /// their files to a repo and swapping the descriptor. Optional so
    /// registries persisted by earlier builds keep decoding.
    public var isLocal: Bool

    public var id: String { "\(owner)/\(name)" }
    public var displayName: String { name }

    public init(owner: String, name: String, branch: String, canPush: Bool = true,
                isLocal: Bool = false) {
        self.owner = owner
        self.name = name
        self.branch = branch
        self.canPush = canPush
        self.isLocal = isLocal
    }

    /// Convenience for on-device stores. The reserved "local" owner cannot
    /// collide with a GitHub store id: GitHub logins can't contain "/", so no
    /// real store is ever "local/<name>".
    public static func local(name: String) -> StoreDescriptor {
        StoreDescriptor(owner: "local", name: name, branch: "main", canPush: true, isLocal: true)
    }

    enum CodingKeys: String, CodingKey {
        case owner, name, branch, canPush, isLocal
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
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
    }
}
