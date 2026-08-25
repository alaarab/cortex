import Foundation
import PhrenKit

/// A remembered (store, project) pair, as it sits in `UserDefaults`.
///
/// One type for both of the settings below because their stored shape is
/// byte-identical — and keeping it that way means one place to obey the
/// contract on `VersionedDocument`. Store-qualified on purpose: see
/// `QuickCaptureDefault`.
private struct CaptureTargetRef: Codable, VersionedDocument {
    /// Still 1: the shape shipped builds wrote (no `schemaVersion` key) is
    /// version 1, and adding the key is additive in both directions.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = CaptureTargetRef.currentSchemaVersion
    let storeId: String
    let project: String

    init(storeId: String, project: String) {
        self.storeId = storeId
        self.project = project
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, storeId, project
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.initialSchemaVersion
        storeId = try container.decode(String.self, forKey: .storeId)
        project = try container.decode(String.self, forKey: .project)
    }
}

/// What the user calls these settings when one of them goes wrong.
private let captureSettingsDocumentName = "quick capture settings"

/// Where a capture goes when the user didn't name a project.
///
/// This is the fix for the defect that made capture untrustworthy: a shortcut
/// run from its Shortcuts tile (no voice, no dialog anyone reads) used to file
/// the capture into the first writable project in sort order, and there was no
/// way afterwards to find out which one that was.
///
/// Nothing in here ever *guesses*. The only destination it will name is one the
/// user picked in Settings → Quick capture. "Unset" is a real, supported state
/// — it means **always ask** — and it is what every new install starts in.
///
/// Stored store-qualified on purpose: two attached stores can both hold a
/// project called `alphalens`, so a default that remembered only the name would
/// silently start resolving to the wrong store the day a second one is added.
enum QuickCaptureDefault {
    private static let key = "phren.capture.defaultTarget"

    /// The (store, project) the user chose, or nil for "Always ask".
    ///
    /// A value here is *not* a promise the project still exists — stores get
    /// removed and projects get deleted elsewhere. Callers must check it
    /// against the live writable set and ask rather than substitute
    /// (`PhrenCapture.resolveTarget`).
    static func load() -> (storeId: String, project: String)? {
        // An unreadable value is set aside, not overwritten, and falls back to
        // "Always ask" — the safe direction: capture asks instead of guessing.
        guard let value = PersistedState.load(CaptureTargetRef.self, fromDefaults: .standard,
                                              key: key, document: captureSettingsDocumentName).value
        else { return nil }
        return (value.storeId, value.project)
    }

    static func save(storeId: String, project: String) {
        PersistedState.save(CaptureTargetRef(storeId: storeId, project: project),
                            toDefaults: .standard, key: key, document: captureSettingsDocumentName)
    }

    /// Back to "Always ask".
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// `ProjectEntity.id` / `PhrenCaptureTarget.entityId` shape, so the
    /// Settings picker can tag rows with the same string the intents key on.
    static func entityId(storeId: String, project: String) -> String {
        "\(storeId)|\(project)"
    }

    /// Splits an `entityId` back into its parts. Store ids are `owner/repo`
    /// and project names can't contain `|`, so the first separator wins.
    static func parse(entityId: String) -> (storeId: String, project: String)? {
        guard let separator = entityId.firstIndex(of: "|") else { return nil }
        let storeId = String(entityId[entityId.startIndex..<separator])
        let project = String(entityId[entityId.index(after: separator)...])
        guard !storeId.isEmpty, !project.isEmpty else { return nil }
        return (storeId, project)
    }
}

/// Remembers the last (store, project) anything was captured into, written by
/// both capture surfaces.
///
/// This is a *convenience*, not a destination rule: the in-app capture sheet
/// opens on it so a run of captures into one project doesn't mean re-picking
/// every time, and the user sees (and can change) it before hitting Save. The
/// App Intents path deliberately does **not** consult it — an eyes-free capture
/// must never inherit a destination the user can't see, which is exactly how
/// captures used to vanish into a project nobody chose.
enum VoiceCaptureLastTarget {
    private static let key = "phren.voiceCapture.lastTarget"

    static func load() -> (storeId: String, project: String)? {
        guard let value = PersistedState.load(CaptureTargetRef.self, fromDefaults: .standard,
                                              key: key, document: captureSettingsDocumentName).value
        else { return nil }
        return (value.storeId, value.project)
    }

    static func save(storeId: String, project: String) {
        PersistedState.save(CaptureTargetRef(storeId: storeId, project: project),
                            toDefaults: .standard, key: key, document: captureSettingsDocumentName)
    }
}
