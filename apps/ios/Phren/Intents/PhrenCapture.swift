import Foundation
import PhrenKit

/// One writable destination for a hands-free capture: a (store, project) pair,
/// the same addressing unit the in-app capture sheet uses
/// (`VoiceCaptureTarget`), reachable without a SwiftUI environment.
struct PhrenCaptureTarget: Sendable, Hashable {
    let storeId: String
    let storeName: String
    let project: String
    /// True when more than one store is attached, so the project name alone
    /// is ambiguous and the store has to be shown/spoken alongside it.
    let qualified: Bool

    /// Stable across launches — `ProjectEntity.id`, which the Shortcuts app
    /// persists inside a saved shortcut.
    var entityId: String { "\(storeId)|\(project)" }

    /// How the project reads on screen ("myproj", "myproj · work-shared").
    var displayName: String { qualified ? "\(project) · \(storeName)" : project }

    /// How Siri says it back — a middle dot doesn't survive text-to-speech.
    var spokenName: String { qualified ? "\(project) in \(storeName)" : project }
}

/// Capture failures that have nothing to do with a specific store (those are
/// `StoreWriteError`). Siri speaks `localizedStringResource` verbatim, so
/// each case has to stand on its own as a sentence heard once, eyes-free.
enum PhrenCaptureError: LocalizedError, CustomLocalizedStringResourceConvertible {
    /// No store has ever been attached — the user hasn't finished onboarding.
    case notSetUp
    /// Stores exist but the token can't push to any of them.
    case noWritableStore
    /// A writable store exists but nothing is cached under it yet.
    case nothingSynced
    /// A saved shortcut references a project that has since gone away.
    case unknownProject(String)
    /// The op itself was rejected (empty text, a secret, a parse failure).
    case rejected(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp:
            return "phren isn't set up yet — open the app to connect your store."
        case .noWritableStore:
            return "Your phren store is read-only. Your GitHub token needs Contents: Read and write on the store repo."
        case .nothingSynced:
            return "phren hasn't synced your store yet — open the app once and try again."
        case .unknownProject(let name):
            return "phren has no project called \(name)."
        case .rejected(let reason):
            return "phren couldn't save that: \(reason)"
        }
    }

    var errorDescription: String? { String(localized: localizedStringResource) }
}

/// The capture path shared by every App Intent: find the writable
/// (store, project) pairs, pick one, and get an op into the store.
///
/// Two worlds, because an App Intent runs in the app's own process but the
/// system may have launched that process *for the intent*, with no scene and
/// therefore no `AppModel.bootstrap()`:
///
/// 1. **App alive** — `AppModel.current` has open store contexts. Route
///    through `AppModel.enqueue` so the local cache, the pending queue, the
///    sync engine and the widget snapshot all see the write exactly as they
///    would from a tap.
/// 2. **Cold background launch** — no contexts. Open the store's `LocalStore`
///    directly and hand it to a `SyncEngine` wired to a client that refuses to
///    talk to the network, so `enqueue` still does its normal apply-locally +
///    append-to-`pending-ops.json` (identical bytes, identical format) while
///    the flush it schedules dies instantly. The op ships on the next
///    foreground pass. Capture never needs the radio, and never needs the
///    Keychain — the GitHub token is not read anywhere on this path.
///
/// The two never run at once: the offline route is taken only when no store
/// context exists, and once `bootstrap()` has opened one, every later intent
/// in this process takes route 1. The offline engines are cached per process
/// so back-to-back Siri captures share one queue in memory.
@MainActor
enum PhrenCapture {
    // MARK: - Targets

    /// Every writable (store, project) pair, live model or not.
    static func targets() async -> [PhrenCaptureTarget] {
        if let model = AppModel.current, !model.storeContexts.isEmpty {
            return liveTargets(model)
        }
        return await offlineTargets()
    }

    private static func liveTargets(_ model: AppModel) -> [PhrenCaptureTarget] {
        model.storeContexts.flatMap { context in
            context.descriptor.canPush
                ? context.snapshot.projects.map {
                    PhrenCaptureTarget(
                        storeId: context.id,
                        storeName: context.descriptor.displayName,
                        project: $0.name,
                        qualified: model.hasMultipleStores
                    )
                }
                : []
        }
        .sorted { ($0.project, $0.storeName) < ($1.project, $1.storeName) }
    }

    private static func offlineTargets() async -> [PhrenCaptureTarget] {
        let descriptors = AppModel.storedDescriptors()
        let qualified = descriptors.count > 1
        var result: [PhrenCaptureTarget] = []
        for descriptor in descriptors where descriptor.canPush {
            guard let store = try? openStore(descriptor) else { continue }
            for project in await projectNames(in: store) {
                result.append(PhrenCaptureTarget(
                    storeId: descriptor.id,
                    storeName: descriptor.displayName,
                    project: project,
                    qualified: qualified
                ))
            }
        }
        return result.sorted { ($0.project, $0.storeName) < ($1.project, $1.storeName) }
    }

    /// Project names straight off the cached tree — every path `LocalStore`
    /// holds is either a project-scoped file or one of the two root YAMLs
    /// (which have no directory component), so the first component of any
    /// two-part-or-longer path is a project. Cheaper than `snapshot()`, which
    /// would parse every findings/tasks/notes file just to list names.
    private static func projectNames(in store: LocalStore) async -> [String] {
        var names = Set<String>()
        for path in await store.allPaths() {
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            names.insert(String(parts[0]))
        }
        return names.sorted()
    }

    // MARK: - Resolution

    /// Resolves the destination for a capture: the project the user named, or
    /// the last one anything was captured into (shared with the in-app voice
    /// sheet via `VoiceCaptureLastTarget`), or the first writable project.
    static func resolveTarget(_ entity: ProjectEntity?) async throws -> PhrenCaptureTarget {
        let available = await targets()
        guard !available.isEmpty else {
            let descriptors = AppModel.storedDescriptors()
            if descriptors.isEmpty { throw PhrenCaptureError.notSetUp }
            throw descriptors.contains(where: \.canPush)
                ? PhrenCaptureError.nothingSynced
                : PhrenCaptureError.noWritableStore
        }
        if let entity {
            guard let match = available.first(where: {
                $0.storeId == entity.storeId && $0.project == entity.project
            }) else {
                throw PhrenCaptureError.unknownProject(entity.project)
            }
            return match
        }
        if let last = VoiceCaptureLastTarget.load(),
           let match = available.first(where: { $0.storeId == last.storeId && $0.project == last.project }) {
            return match
        }
        return available[0]
    }

    // MARK: - Execution

    /// Applies the op and queues it for the next flush. Never blocks on the
    /// network; never touches the Keychain.
    static func capture(_ op: PendingOp, to target: PhrenCaptureTarget) async throws {
        do {
            if let model = AppModel.current,
               model.storeContexts.contains(where: { $0.id == target.storeId }) {
                try await model.enqueue(op, in: target.storeId)
                // Same generation the UI and the widget snapshot settle on.
                await model.refresh()
            } else {
                try await captureOffline(op, to: target)
            }
        } catch let error as StoreWriteError {
            throw error
        } catch let error as PhrenCaptureError {
            throw error
        } catch {
            throw PhrenCaptureError.rejected(error.localizedDescription)
        }
        // Keep the in-app capture sheet defaulting to wherever the last
        // capture went, whichever surface made it.
        VoiceCaptureLastTarget.save(storeId: target.storeId, project: target.project)
    }

    private static func captureOffline(_ op: PendingOp, to target: PhrenCaptureTarget) async throws {
        guard let descriptor = AppModel.storedDescriptors().first(where: { $0.id == target.storeId }) else {
            throw PhrenCaptureError.notSetUp
        }
        guard descriptor.canPush else {
            throw StoreWriteError.readOnly(descriptor.displayName)
        }
        try await offlineEngine(for: descriptor).enqueue(op)
    }

    // MARK: - Offline store access

    private static var offlineStores: [String: LocalStore] = [:]
    private static var offlineEngines: [String: SyncEngine] = [:]

    /// One `LocalStore` per store per process. Two instances over the same
    /// directory would each hold their own copy of the manifest, and
    /// `LocalStore.write` rewrites the whole manifest from that copy — so the
    /// second one to write would drop the first one's blob SHAs.
    private static func openStore(_ descriptor: StoreDescriptor) throws -> LocalStore {
        if let cached = offlineStores[descriptor.id] { return cached }
        // Plain files under Application Support, so the default
        // NSFileProtectionCompleteUntilFirstUserAuthentication applies: a
        // locked phone can read and write them, a phone that hasn't been
        // unlocked since boot cannot.
        let store = try LocalStore(
            rootDirectory: LocalStore.defaultDirectory(owner: descriptor.owner, repo: descriptor.name),
            owner: descriptor.owner,
            repo: descriptor.name,
            branch: descriptor.branch
        )
        offlineStores[descriptor.id] = store
        return store
    }

    private static func offlineEngine(for descriptor: StoreDescriptor) throws -> SyncEngine {
        if let cached = offlineEngines[descriptor.id] { return cached }
        let engine = SyncEngine(
            client: OfflineGitHubAPI(),
            store: try openStore(descriptor),
            stateDirectory: LocalStore.defaultDirectory(owner: descriptor.owner, repo: descriptor.name)
        )
        offlineEngines[descriptor.id] = engine
        return engine
    }
}

/// A `GitHubAPI` that refuses every request, so a `SyncEngine` built on it can
/// apply and queue but never push.
///
/// The cold-launch capture path wants `SyncEngine.enqueue` — it is the only
/// code that writes `pending-ops.json` in the format the app reads back, and
/// re-implementing it would be a second source of truth for the queue file.
/// What it does not want is the flush `enqueue` schedules: a background launch
/// can be suspended the instant `perform()` returns, and a PUT that lands on
/// GitHub after this process forgets it is how an offline-first queue ends up
/// committing the same task twice. Failing the request outright is treated by
/// the flush as a transient network error — the op stays queued, in order, and
/// the next foreground sync sends it.
private struct OfflineGitHubAPI: GitHubAPI {
    /// Deliberately neither `GitHubError` nor `PhrenKitError`: the flush parks
    /// ops for both of those, and this op is not in trouble, just not sent yet.
    private struct NotNow: LocalizedError {
        var errorDescription: String? {
            "Captured offline — phren pushes this the next time you open the app."
        }
    }

    func headSha(owner: String, repo: String, branch: String) async throws -> String? { throw NotNow() }

    func tree(owner: String, repo: String, sha: String) async throws -> GitTree { throw NotNow() }

    func blob(owner: String, repo: String, sha: String) async throws -> Data { throw NotNow() }

    func putFile(owner: String, repo: String, path: String, branch: String,
                 content: Data, message: String, sha: String?) async throws -> ContentsPutResponse {
        throw NotNow()
    }

    func deleteFile(owner: String, repo: String, path: String, branch: String,
                    message: String, sha: String) async throws {
        throw NotNow()
    }
}
