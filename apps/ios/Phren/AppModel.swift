import SwiftUI
import PhrenKit

/// One added store: its descriptor plus the live machinery and parsed state.
/// @Observable so views recomputing the merged accessors re-render when a
/// context's snapshot is replaced on refresh.
@Observable @MainActor
final class StoreContext: Identifiable {
    let descriptor: StoreDescriptor
    let store: LocalStore
    let engine: SyncEngine
    var snapshot: LocalStore.Snapshot = .empty
    var status = SyncEngine.Status()
    /// LocalStore.dataVersion the current snapshot was parsed from — the gate
    /// that keeps status-only updates from re-parsing an unchanged store.
    var snapshotVersion: UInt64?

    // nonisolated: witnesses the nonisolated Identifiable requirement without
    // a MainActor hop (descriptor is an immutable Sendable let).
    nonisolated var id: String { descriptor.id }

    init(descriptor: StoreDescriptor, store: LocalStore, engine: SyncEngine) {
        self.descriptor = descriptor
        self.store = store
        self.engine = engine
    }
}

/// A (store, project) pair — the app's addressing unit. Unlike the CLI's
/// name-keyed primary-wins merge (which silently shadows a project that exists
/// in two stores), the app shows both, disambiguated by store.
struct StoreProject: Identifiable, Hashable {
    let storeId: String
    let storeName: String
    let project: Project

    var id: String { "\(storeId)/\(project.name)" }

    static func == (lhs: StoreProject, rhs: StoreProject) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct StoreQueueEntry: Identifiable {
    let storeId: String
    let storeName: String
    let entry: ProjectQueueItem

    var id: String { "\(storeId)/\(entry.id)" }
}

struct FailedOpEntry: Identifiable {
    let storeId: String
    let storeName: String
    let op: QueuedOp

    var id: UUID { op.id }
}

/// Root observable state: auth, the store list, merged snapshots, and sync.
/// Views read the merged accessors and route mutations by store id.
@Observable @MainActor
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case pickingRepo
        case initialSync
        case ready
    }

    private(set) var phase: Phase = .loading
    private(set) var user: GitHubUser?
    private(set) var storeContexts: [StoreContext] = []
    private(set) var searchIndex = SearchIndex()
    /// Bumped whenever searchIndex is actually rebuilt. Search results cache
    /// against this, so they refresh exactly when the index changes.
    private(set) var indexGeneration = 0
    private(set) var syncStatus = SyncEngine.Status()
    /// Global store filter (store id) applied by list screens when set.
    var storeFilter: String?
    var lastActionError: String?

    let client = GitHubClient()

    private static let storesDefaultsKey = "phren.stores"
    private static let legacyRepoDefaultsKey = "phren.selected-repo"

    var storeDescriptors: [StoreDescriptor] { storeContexts.map(\.descriptor) }
    var hasMultipleStores: Bool { storeContexts.count > 1 }
    /// True when every open store lives only on this device — the status bar
    /// says "saved on this device" instead of implying a sync is owed.
    var allStoresLocal: Bool {
        !storeContexts.isEmpty && storeContexts.allSatisfy(\.descriptor.isLocal)
    }

    func storeName(for id: String) -> String {
        storeContexts.first { $0.id == id }?.descriptor.displayName ?? id
    }

    func canPush(storeId: String) -> Bool {
        storeContexts.first { $0.id == storeId }?.descriptor.canPush ?? true
    }

    // MARK: - Merged accessors

    private var filteredContexts: [StoreContext] {
        guard let storeFilter else { return storeContexts }
        return storeContexts.filter { $0.id == storeFilter }
    }

    var mergedProjects: [StoreProject] {
        filteredContexts.flatMap { context in
            context.snapshot.projects.map {
                StoreProject(storeId: context.id, storeName: context.descriptor.displayName, project: $0)
            }
        }
        .sorted { ($0.project.name, $0.storeName) < ($1.project.name, $1.storeName) }
    }

    var mergedReviewQueue: [StoreQueueEntry] {
        var entries: [(StoreContext, ProjectQueueItem)] = []
        for context in filteredContexts {
            for item in context.snapshot.reviewQueue {
                entries.append((context, item))
            }
        }
        return entries
            .sorted { LocalStore.reviewQueueOrder($0.1, $1.1) }
            .map { StoreQueueEntry(storeId: $0.0.id, storeName: $0.0.descriptor.displayName, entry: $0.1) }
    }

    var mergedTaskDocs: [(storeId: String, storeName: String, doc: TaskDoc)] {
        filteredContexts.flatMap { context in
            context.snapshot.tasks
                .sorted { $0.key < $1.key }
                .map { (context.id, context.descriptor.displayName, $0.value) }
        }
    }

    func snapshot(for storeId: String) -> LocalStore.Snapshot {
        storeContexts.first { $0.id == storeId }?.snapshot ?? .empty
    }

    func findings(storeId: String, project: String) -> [Finding] {
        snapshot(for: storeId).findings[project] ?? []
    }

    func notes(storeId: String, project: String) -> [Note] {
        snapshot(for: storeId).notes[project] ?? []
    }

    func truths(storeId: String, project: String) -> String? {
        snapshot(for: storeId).truths[project]
    }

    func claudeDoc(storeId: String, project: String) -> String? {
        snapshot(for: storeId).claudeDocs[project]
    }

    func summary(storeId: String, project: String) -> String? {
        snapshot(for: storeId).summaries[project]
    }

    var totalReviewCount: Int {
        storeContexts.reduce(0) { $0 + $1.snapshot.reviewQueue.count }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard phase == .loading else { return }
        // `-phren-demo` launches straight into seeded demo data. Used for UI
        // screenshots and for exploring the app without a GitHub token.
        if ProcessInfo.processInfo.arguments.contains("-phren-demo") {
            await enterDemoMode()
            return
        }
        // `-phren-create-local <store> <project>` scripts the local-store flow
        // for screenshot automation, same family as -phren-tab/-phren-route.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-phren-create-local"), i + 2 < args.count {
            await createLocalStore(name: args[i + 1], firstProject: args[i + 2])
            return
        }
        guard let stored = KeychainStore.load() else {
            // No token, but a registry of local-only stores still opens — a
            // local store needs no GitHub at all.
            let descriptors = loadDescriptors()
            if !descriptors.isEmpty, descriptors.allSatisfy(\.isLocal) {
                phase = .ready
                for descriptor in descriptors {
                    await openContext(descriptor)
                }
                await refresh()
                return
            }
            phase = .signedOut
            return
        }
        await client.setToken(stored.token)
        do {
            user = try await client.currentUser()
        } catch {
            // Only a rejected token means signed out. Deleting the keychain
            // entry on *any* failure — no signal, DNS, a 500, a rate limit —
            // signed the user out of a cache-first app and put all their local
            // data behind the welcome screen. Anything else: carry on with the
            // cached identity and let the sync status surface the problem.
            if case GitHubError.http(let status, _) = error, status == 401 {
                KeychainStore.delete()
                phase = .signedOut
                return
            }
            // The account name stays blank until a later call succeeds; the
            // store contents below are what the user actually came for.
            lastActionError = "Couldn't reach GitHub — showing your last synced copy."
        }

        let descriptors = loadDescriptors()
        guard !descriptors.isEmpty else {
            phase = .pickingRepo
            return
        }
        phase = .ready
        for descriptor in descriptors {
            await openContext(descriptor)
        }
        // Render the cached copy instantly; the pull refreshes it right after.
        await refresh()
        await pullAllAndGoLive()
    }

    private func loadDescriptors() -> [StoreDescriptor] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.storesDefaultsKey),
           let list = try? JSONDecoder().decode([StoreDescriptor].self, from: data) {
            return list
        }
        // Migrate the legacy single-store key: same owner/name/branch JSON
        // shape; canPush defaults true via StoreDescriptor's decoder.
        if let data = defaults.data(forKey: Self.legacyRepoDefaultsKey),
           let legacy = try? JSONDecoder().decode(StoreDescriptor.self, from: data) {
            persistDescriptors([legacy])
            defaults.removeObject(forKey: Self.legacyRepoDefaultsKey)
            return [legacy]
        }
        return []
    }

    private func persistDescriptors(_ descriptors: [StoreDescriptor]) {
        if let data = try? JSONEncoder().encode(descriptors) {
            UserDefaults.standard.set(data, forKey: Self.storesDefaultsKey)
        }
    }

    // MARK: - Demo mode

    /// True while running on seeded local fixtures instead of a real store.
    /// Suppresses live polling and sync, which would otherwise 401 with no token.
    private(set) var isDemo = false

    /// Seeds two local stores from `DemoMode` fixtures and jumps straight to
    /// `.ready`. No network, no auth, no writes to a real store's cache.
    func enterDemoMode() async {
        isDemo = true
        // GitHubUser's memberwise init isn't public — decode the same shape the
        // API would return rather than widening PhrenKit's surface for a demo.
        user = try? JSONDecoder().decode(
            GitHubUser.self,
            from: Data(#"{"login":"demo","name":"Demo Mode"}"#.utf8)
        )

        for seed in DemoMode.seeds {
            do {
                let directory = DemoMode.directory(for: seed.descriptor)
                let store = try LocalStore(rootDirectory: directory,
                                           owner: seed.descriptor.owner,
                                           repo: seed.descriptor.name,
                                           branch: seed.descriptor.branch)
                // Re-seed every launch so edits made while exploring reset cleanly.
                try? await store.wipe()
                for (path, content) in seed.files {
                    try await store.write(path, content: content, blobSha: nil)
                }
                let engine = SyncEngine(client: client, store: store, stateDirectory: directory)
                storeContexts.append(StoreContext(descriptor: seed.descriptor,
                                                  store: store, engine: engine))
            } catch {
                lastActionError = error.localizedDescription
            }
        }

        await refresh()
        phase = .ready
    }

    func enterForeground() async {
        guard phase == .ready, !isDemo else { return }
        await startLiveAll()
    }

    func enterBackground() async {
        for context in storeContexts {
            await context.engine.stopLive()
        }
    }

    private func startLiveAll() async {
        // Stagger starts so N stores don't wake the radio simultaneously.
        for (i, context) in storeContexts.enumerated() {
            if i > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await context.engine.startLive()
        }
    }

    private func pullAllAndGoLive() async {
        await pullAll()
        await refresh()
        await startLiveAll()
    }

    /// Parallel forced pull across stores. Captures the (Sendable) engines,
    /// not the @MainActor StoreContext, in the child tasks.
    private func pullAll() async {
        let engines = storeContexts.map(\.engine)
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask { await engine.pull(force: true) }
            }
        }
    }

    // MARK: - Auth

    func signIn(token: String, kind: KeychainStore.TokenKind) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        await client.setToken(trimmed)
        let user = try await client.currentUser()
        try KeychainStore.save(.init(token: trimmed, kind: kind))
        self.user = user
        phase = .pickingRepo
    }

    func signOut() async {
        // GitHub-backed stores are caches of the remote: wiping them is safe.
        // Local stores are the ONLY copy of their data and don't depend on
        // auth, so they survive sign-out untouched.
        for context in storeContexts where !context.descriptor.isLocal {
            await context.engine.stopLive()
            try? await context.store.wipe()
        }
        KeychainStore.delete()
        await client.setToken(nil)
        user = nil
        storeContexts.removeAll { !$0.descriptor.isLocal }
        if storeContexts.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.storesDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyRepoDefaultsKey)
            storeFilter = nil
            searchIndex = SearchIndex()
            syncStatus = SyncEngine.Status()
            phase = .signedOut
            return
        }
        persistDescriptors(storeDescriptors)
        if let filter = storeFilter, !storeContexts.contains(where: { $0.id == filter }) {
            storeFilter = nil
        }
        await refresh()
    }

    // MARK: - Local stores

    /// Creates an on-device store with a first project so it's immediately
    /// usable — the app's capture flows are all per-project, so an empty
    /// store would be a dead end.
    func createLocalStore(name: String, firstProject: String) async {
        let storeName = Self.slugify(name)
        let project = Self.slugify(firstProject)
        guard !storeName.isEmpty, !project.isEmpty else {
            lastActionError = "Store and project names need at least one letter or number."
            return
        }
        let descriptor = StoreDescriptor.local(name: storeName)
        guard !storeContexts.contains(where: { $0.id == descriptor.id }) else {
            lastActionError = "A store named \(storeName) already exists."
            return
        }
        await openContext(descriptor)
        persistDescriptors(storeDescriptors)
        await scaffoldProject(project, storeId: descriptor.id)
        phase = .ready
        await refresh()
    }

    /// Adds an empty project to a local store by writing its FINDINGS.md —
    /// a project is just a directory with content, so this is all it takes.
    func createProject(named rawName: String, storeId: String) async {
        let name = Self.slugify(rawName)
        guard !name.isEmpty else {
            lastActionError = "Project names need at least one letter or number."
            return
        }
        guard let context = storeContexts.first(where: { $0.id == storeId }),
              context.descriptor.isLocal else {
            lastActionError = "New projects can only be created in on-device stores. GitHub stores get projects from the CLI."
            return
        }
        guard context.snapshot.findings[name] == nil,
              !context.snapshot.projects.contains(where: { $0.name == name }) else {
            lastActionError = "Project \(name) already exists."
            return
        }
        await scaffoldProject(name, storeId: storeId)
        await refresh()
    }

    private func scaffoldProject(_ name: String, storeId: String) async {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else { return }
        do {
            try await context.store.write("\(name)/FINDINGS.md",
                                          content: "# \(name) Findings\n", blobSha: nil)
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    /// Upgrades a local store to a GitHub-backed one: uploads every file to
    /// the given (already created, empty) repo, then reopens the store as a
    /// normal synced one. Requires being signed in.
    func connectLocalStore(storeId: String, owner: String, repo: String) async -> Bool {
        guard user != nil else {
            lastActionError = "Sign in with GitHub first — Settings > Account."
            return false
        }
        guard let context = storeContexts.first(where: { $0.id == storeId }),
              context.descriptor.isLocal else { return false }

        let ghRepo: GitHubRepo
        do {
            ghRepo = try await client.repo(owner: owner, name: repo)
        } catch {
            lastActionError = "Couldn't open \(owner)/\(repo): \(error.localizedDescription)"
            return false
        }
        guard ghRepo.permissions?.push ?? false else {
            lastActionError = "Your token can't push to \(owner)/\(repo)."
            return false
        }

        // Upload every local file. sha nil creates; an existing path means the
        // repo wasn't empty and the write conflicts, which we surface.
        let paths = await context.store.allPaths()
        for path in paths.sorted() {
            guard let content = await context.store.readIfAvailable(path) else { continue }
            do {
                _ = try await client.putFile(
                    owner: ghRepo.owner.login, repo: ghRepo.name, path: path,
                    branch: ghRepo.defaultBranch, content: Data(content.utf8),
                    message: "phren: import \(context.descriptor.name) from ios", sha: nil
                )
            } catch {
                lastActionError = "Upload stopped at \(path): \(error.localizedDescription). The repo should be empty."
                return false
            }
        }

        // Swap: retire the local context, adopt the repo as a normal store.
        await context.engine.stopLive()
        try? await context.store.wipe()
        storeContexts.removeAll { $0.id == storeId }
        await addStore(repo: ghRepo)
        return true
    }

    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber ? ch : "-"
        }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    // MARK: - Store management

    /// Adds a store from a picked repo. The first store also completes onboarding.
    func addStore(repo: GitHubRepo) async {
        let descriptor = StoreDescriptor(
            owner: repo.owner.login,
            name: repo.name,
            branch: repo.defaultBranch,
            canPush: repo.permissions?.push ?? true
        )
        guard !storeContexts.contains(where: { $0.id == descriptor.id }) else { return }

        let firstStore = storeContexts.isEmpty
        if firstStore { phase = .initialSync }

        await openContext(descriptor)
        persistDescriptors(storeDescriptors)

        if let context = storeContexts.first(where: { $0.id == descriptor.id }) {
            await context.engine.pull(force: true)
            await refresh()
            await context.engine.startLive()
        }
        if firstStore {
            // openContext can fail (LocalStore init) — never strand the user
            // in the tab view with zero stores.
            phase = storeContexts.isEmpty ? .pickingRepo : .ready
        }
    }

    /// Removes the store's local copy and registry entry. Never touches GitHub.
    func removeStore(id: String) async {
        guard let index = storeContexts.firstIndex(where: { $0.id == id }) else { return }
        let context = storeContexts[index]
        await context.engine.stopLive()
        try? await context.store.wipe()
        storeContexts.remove(at: index)
        if storeFilter == id { storeFilter = nil }
        persistDescriptors(storeDescriptors)
        // Membership changed with no store's dataVersion moving — the gated
        // refresh would keep the removed store's docs in the index. Rebuild
        // unconditionally.
        searchIndex = SearchIndex(snapshots: storeContexts.map {
            (store: $0.id, snapshot: $0.snapshot)
        })
        indexGeneration += 1
        await refresh()
        if storeContexts.isEmpty {
            phase = .pickingRepo
        }
    }

    private func openContext(_ descriptor: StoreDescriptor) async {
        do {
            let directory = LocalStore.defaultDirectory(owner: descriptor.owner, repo: descriptor.name)
            let store = try LocalStore(rootDirectory: directory, owner: descriptor.owner,
                                       repo: descriptor.name, branch: descriptor.branch)
            let engine = SyncEngine(client: client, store: store, stateDirectory: directory)
            let context = StoreContext(descriptor: descriptor, store: store, engine: engine)
            storeContexts.append(context)

            if descriptor.isLocal {
                // No repo behind this store: apply-and-cache only, no sync.
                await engine.setOffline(true)
            }
            await engine.setWriteContext(.init(actor: user?.login, machine: deviceName()))
            await engine.setOnUpdate { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    private func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    // MARK: - Data refresh

    func refresh() async {
        // Sync status updates fire on every poll tick (twice per 7s per store,
        // even on 304s); content changes are far rarer. Re-parse and re-index
        // only stores whose dataVersion actually moved — status is always
        // cheap to copy.
        var contentChanged = false
        for context in storeContexts {
            context.status = await context.engine.currentStatus()
            let version = await context.store.dataVersion
            if context.snapshotVersion != version {
                context.snapshot = await context.store.snapshot()
                context.snapshotVersion = version
                contentChanged = true
            }
        }
        if contentChanged {
            // Key by store id (owner/name) — display names alone collide when
            // two owners have same-named repos. The UI translates via
            // storeName(for:).
            searchIndex = SearchIndex(snapshots: storeContexts.map {
                (store: $0.id, snapshot: $0.snapshot)
            })
            indexGeneration += 1
        }
        syncStatus = aggregateStatus()
    }

    private func aggregateStatus() -> SyncEngine.Status {
        var aggregate = SyncEngine.Status()
        guard !storeContexts.isEmpty else { return aggregate }
        let statuses = storeContexts.map(\.status)
        aggregate.isLive = statuses.allSatisfy(\.isLive)
        aggregate.isSyncing = statuses.contains { $0.isSyncing }
        // Oldest last-synced across stores — "everything is at least this fresh".
        let timestamps = statuses.compactMap(\.lastSyncedAt)
        aggregate.lastSyncedAt = timestamps.count == statuses.count ? timestamps.min() : nil
        aggregate.pendingCount = statuses.reduce(0) { $0 + $1.pendingCount }
        aggregate.failedCount = statuses.reduce(0) { $0 + $1.failedCount }
        aggregate.lastError = statuses.compactMap(\.lastError).first
        return aggregate
    }

    func pullToRefresh() async {
        // Demo mode has no remote to pull from — just re-parse the seeded files.
        guard !isDemo else {
            await refresh()
            return
        }
        await pullAll()
        await refresh()
    }

    // MARK: - Mutations

    func perform(_ op: PendingOp, in storeId: String) async {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else {
            lastActionError = "Store \(storeId) is not open."
            return
        }
        guard context.descriptor.canPush else {
            lastActionError = "\(context.descriptor.displayName) is read-only — your GitHub token can't push to it."
            return
        }
        do {
            try await context.engine.enqueue(op)
            lastActionError = nil
            // Demo mode runs a real engine against an unauthenticated client, so
            // letting a flush start would park the op and leave a permanent
            // "Not signed in to GitHub" error on screen. Apply locally, drop the
            // queue: the demo is meant to be explored, including its edits.
            if isDemo { await context.engine.discardPending() }
        } catch {
            lastActionError = error.localizedDescription
        }
        await refresh()
    }

    func retryFailedOps() async {
        for context in storeContexts {
            await context.engine.retryFailed()
        }
        await refresh()
    }

    func discardFailedOp(storeId: String, id: UUID) async {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else { return }
        await context.engine.discardFailed(id: id)
        await refresh()
    }

    func failedOps() async -> [FailedOpEntry] {
        var result: [FailedOpEntry] = []
        for context in storeContexts {
            for op in await context.engine.failedOps() {
                result.append(FailedOpEntry(storeId: context.id, storeName: context.descriptor.displayName, op: op))
            }
        }
        return result
    }

    /// Current time formatted as the note heading time (HH:MM:SS UTC —
    /// matching `now.toISOString().slice(11,19)` in notes.ts:181).
    func nowNoteTimestamp() -> (date: String, time: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let iso = formatter.string(from: Date())
        return (String(iso.prefix(10)), String(iso.suffix(8)))
    }
}

#if canImport(UIKit)
import UIKit
#endif
