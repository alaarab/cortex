import SwiftUI
import PhrenKit

/// One added store: its descriptor plus the live machinery and parsed state.
/// @Observable so views recomputing the merged accessors re-render when a
/// context's snapshot is replaced on refresh.
@Observable @MainActor
final class StoreContext: Identifiable {
    private(set) var descriptor: StoreDescriptor
    let store: LocalStore
    let engine: SyncEngine
    var snapshot: LocalStore.Snapshot = .empty
    var status = SyncEngine.Status()
    /// Per-project cold-tier summary (project → topics + bytes), refreshed
    /// with the snapshot. Read entirely from the catalogue the tree already
    /// paid for — no network, no hydration, safe to recompute every poll.
    var coldSummaries: [String: ColdSummary] = [:]

    // nonisolated: witnesses the nonisolated Identifiable requirement without
    // a MainActor hop. Captured once at init rather than derived from
    // `descriptor` — owner/name (and hence id) never change after a store is
    // added, only `canPush` does, so this stays safe without requiring
    // descriptor to be immutable.
    nonisolated let id: String

    init(descriptor: StoreDescriptor, store: LocalStore, engine: SyncEngine) {
        self.descriptor = descriptor
        self.store = store
        self.engine = engine
        self.id = descriptor.id
    }

    /// Best-effort refresh of push permission from a re-fetched repo — called
    /// from bootstrap/pullToRefresh. `canPush` is otherwise captured once at
    /// addStore time and never updated even if the token's access changes
    /// (StoreDescriptor.swift's doc comment promises this "correction").
    func updateCanPush(_ canPush: Bool) {
        descriptor.canPush = canPush
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

/// The app's tabs, in `MainTabView` display order. Exists as a binding
/// target (rather than the TabView's default no-selection mode) so a widget
/// deep link's `onOpenURL` handler can jump the user straight to a tab.
enum AppTab: Hashable {
    case projects, review, tasks, search, settings
}

/// Why a mutation couldn't be routed to a store. Surfaced as
/// `lastActionError` in the UI and spoken verbatim by Siri when an App Intent
/// hits the same condition (`CustomLocalizedStringResourceConvertible` is what
/// AppIntents reads an error's dialog from).
enum StoreWriteError: LocalizedError, CustomLocalizedStringResourceConvertible {
    case storeNotOpen(String)
    case readOnly(String)

    var errorDescription: String? {
        switch self {
        case .storeNotOpen(let id):
            return "Store \(id) is not open."
        case .readOnly(let name):
            return "\(name) is read-only — your GitHub token can't push to it."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeNotOpen:
            return "phren couldn't reach that store. Open the app and try again."
        case .readOnly(let name):
            return "\(name) is read-only — your GitHub token can't push to it."
        }
    }
}

/// Root observable state: auth, the store list, merged snapshots, and sync.
/// Views read the merged accessors and route mutations by store id.
@Observable @MainActor
final class AppModel {
    /// The live model, for code that runs outside the SwiftUI environment —
    /// App Intents execute in this process but have no view hierarchy to read
    /// `@Environment(AppModel.self)` from. Weak on purpose: a background
    /// launch that never connects a scene may not keep the App struct's
    /// `@State` alive, and a nil hook is exactly the signal the capture path
    /// needs to take its own offline route (see `PhrenCapture`).
    private(set) static weak var current: AppModel?

    init() {
        Self.current = self
    }

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
    private(set) var syncStatus = SyncEngine.Status()
    /// Global store filter (store id) applied by list screens when set.
    var storeFilter: String?
    var lastActionError: String?
    /// On-device data that couldn't be read (and was set aside) or couldn't be
    /// written. Newest last. Readable by the Settings health section; the
    /// newest one also lands in `lastActionError`, because a user whose
    /// unsynced work was quarantined must not have to go looking for that.
    private(set) var storageIssues: [StorageIssue] = []
    /// The issue already shown, so a ~7s refresh can't keep re-raising a
    /// banner the user dismissed.
    private var lastSurfacedIssueId: UUID?
    /// Bound to `MainTabView`'s `TabView` selection — set from a widget deep
    /// link (`phren://review`, `phren://tasks`) via `PhrenApp.onOpenURL`.
    var selectedTab: AppTab = .projects

    /// Parsed `stores.yaml`, read from the primary store's local cache (see
    /// `refreshStoresManifest`). Powers the claim-awareness badges in
    /// Projects and the health-section summary in Settings.
    private(set) var storesManifest = StoresManifest()
    /// Last raw content parsed into `storesManifest`, so a refresh only
    /// re-parses when the file actually changed — which, since `stores.yaml`
    /// is a synced root path (LocalStore.isSyncedPath), only happens when the
    /// store's ref sha moves. This is what keys the re-parse to the ref sha
    /// without fetching the file separately on every ~7s poll.
    private var lastStoresYAMLRaw: String?

    let client = GitHubClient()

    private static let storesDefaultsKey = "phren.stores"
    private static let legacyRepoDefaultsKey = "phren.selected-repo"
    /// The registry's on-disk shape. Version 1 is a bare `[StoreDescriptor]`
    /// array — what shipped builds wrote — which `VersionedList` still reads.
    private typealias StoreRegistry = VersionedList<StoreDescriptor>
    /// What the user calls this list when it goes wrong.
    private static let storeRegistryDocumentName = "store settings"

    var storeDescriptors: [StoreDescriptor] { storeContexts.map(\.descriptor) }
    var hasMultipleStores: Bool { storeContexts.count > 1 }

    func storeName(for id: String) -> String {
        storeContexts.first { $0.id == id }?.descriptor.displayName ?? id
    }

    func canPush(storeId: String) -> Bool {
        storeContexts.first { $0.id == storeId }?.descriptor.canPush ?? true
    }

    /// Whether this (store, project) pair can take a write at all. Two
    /// independent reasons it can't: the token has no push on the repo, or the
    /// project is one of phren's read-only tiers (`global` — the consolidate
    /// skill owns it). Every surface that offers an add/edit/delete affordance
    /// asks this, so a read-only project never presents a control that would
    /// fail at flush time against `LocalStore.isWritablePath`.
    func canWrite(storeId: String, project: String) -> Bool {
        canPush(storeId: storeId) && !LocalStore.isReadOnlyProject(project)
    }

    /// Every (store, project) pair a capture can actually land in.
    var writableProjects: [StoreProject] {
        mergedProjects.filter { canWrite(storeId: $0.storeId, project: $0.project.name) }
    }

    /// The store treated as "primary" for `stores.yaml` sourcing: the first
    /// one added. The app has no per-store equivalent of the registry's own
    /// `role: primary` (that's a property of entries *inside* stores.yaml,
    /// not of the app's GitHub-repo store list) — first-added is the closest
    /// stand-in, and matches how a single pre-existing store migrates in as
    /// the sole (and therefore first) entry.
    private var primaryStoreContext: StoreContext? { storeContexts.first }

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

    func summary(storeId: String, project: String) -> String? {
        snapshot(for: storeId).summaries[project]
    }

    var totalReviewCount: Int {
        storeContexts.reduce(0) { $0 + $1.snapshot.reviewQueue.count }
    }

    // MARK: - Cold tier (archived findings)

    /// What this project's archive weighs, without reading any of it.
    func coldSummary(storeId: String, project: String) -> ColdSummary? {
        storeContexts.first { $0.id == storeId }?.coldSummaries[project]
    }

    /// The archive's table of contents — catalogue only, still no fetch.
    func coldTopics(storeId: String, project: String) async -> [ColdDocRef] {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else { return [] }
        return await context.engine.coldStore.topics(for: project)
    }

    /// Reads one archived topic, fetching its blob only if the cache doesn't
    /// hold it at the tree's current sha. The only cold fetch in the app, and
    /// it only ever happens because someone opened this topic.
    func coldDocument(storeId: String, path: String) async throws -> TopicDocument {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else {
            throw StoreWriteError.storeNotOpen(storeId)
        }
        let document = try await context.engine.coldDocument(at: path)
        // Hydrating changes what the archive row can honestly claim (it can
        // now count this topic's findings), so let the summaries catch up.
        context.coldSummaries = await context.engine.coldStore.projectSummaries()
        return document
    }

    // MARK: - stores.yaml claim awareness

    /// The claiming store's display name, if `stores.yaml` says this project
    /// belongs elsewhere — surfaced as a warning chip on its Projects row.
    func claimingStoreName(for item: StoreProject) -> String? {
        let physicalName = storeContexts.first { $0.id == item.storeId }?.descriptor.displayName
        return storesManifest.claimingEntry(for: item.project.name, physicalStoreName: physicalName)?.name
    }

    /// Per-claimant counts of this store's projects that `stores.yaml` says
    /// belong to a different store — one row per claimant in the Settings
    /// health card ("3 projects in this store are claimed by 'work-shared'").
    func claimedElsewhere(storeId: String) -> [(name: String, count: Int)] {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else { return [] }
        var counts: [String: Int] = [:]
        for project in context.snapshot.projects {
            if let entry = storesManifest.claimingEntry(for: project.name, physicalStoreName: context.descriptor.displayName) {
                counts[entry.name, default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { (name: $0.key, count: $0.value) }
    }

    /// Groups of distinct project names (across every attached store) that
    /// normalize to the same canonical key — a subtle nudge for
    /// `max4liveplugins` vs `max4live-plugins`-style near-duplicates that
    /// nobody notices because nothing ever puts them side by side.
    var duplicateProjectGroups: [[String]] {
        let names = Set(storeContexts.flatMap { $0.snapshot.projects.map(\.name) })
        var byKey: [String: [String]] = [:]
        for name in names {
            byKey[Self.canonicalProjectKey(name), default: []].append(name)
        }
        return byKey.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }

    private static func canonicalProjectKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    /// Re-parses `stores.yaml` from the primary store's local cache when its
    /// content has changed since the last refresh. `LocalStore` already
    /// mirrors `stores.yaml` as part of the normal recursive-tree sync
    /// (`LocalStore.isSyncedPath`), so this is a local file read, not a
    /// network call — the file's content (and hence the raw-content equality
    /// check below) only changes when the store's ref sha moves, which is
    /// exactly the "once per sync generation, keyed on the ref sha" the file
    /// needs to respect the live ~7s poll.
    private func refreshStoresManifest() async {
        guard let primary = primaryStoreContext else {
            storesManifest = .empty
            lastStoresYAMLRaw = nil
            return
        }
        let raw = await primary.store.read("stores.yaml")
        guard raw != lastStoresYAMLRaw else { return }
        lastStoresYAMLRaw = raw
        storesManifest = raw.map(StoresManifest.parse) ?? .empty
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard phase == .loading else { return }
        guard let stored = KeychainStore.load() else {
            phase = .signedOut
            return
        }
        await client.setToken(stored.token)
        do {
            user = try await client.currentUser()
        } catch {
            KeychainStore.delete()
            phase = .signedOut
            return
        }

        let descriptors = loadDescriptors()
        guard !descriptors.isEmpty else {
            phase = .pickingRepo
            return
        }
        for descriptor in descriptors {
            await openContext(descriptor)
        }
        // openContext can fail (LocalStore init) for every descriptor — never
        // strand the user in an empty tab view with no way back. Mirrors the
        // same guard in addStore().
        phase = storeContexts.isEmpty ? .pickingRepo : .ready
        // Render the cached copy instantly; the pull refreshes it right after.
        await refresh()
        await refreshStorePermissions()
        await pullAllAndGoLive()
    }

    private func loadDescriptors() -> [StoreDescriptor] { Self.storedDescriptors() }

    private func persistDescriptors(_ descriptors: [StoreDescriptor]) { Self.persist(descriptors) }

    /// The attached-store registry, readable without a bootstrapped model —
    /// an App Intent cold-launched in the background has no `storeContexts`
    /// yet but still needs to know which stores exist and which are writable.
    static func storedDescriptors() -> [StoreDescriptor] {
        let defaults = UserDefaults.standard
        // A registry that can't be decoded is set aside rather than replaced,
        // so a user thrown back to the repo picker at least hears why.
        if let list = PersistedState.load(StoreRegistry.self, fromDefaults: defaults,
                                          key: storesDefaultsKey,
                                          document: storeRegistryDocumentName).value {
            return list.items
        }
        // Migrate the legacy single-store key: same owner/name/branch JSON
        // shape; canPush defaults true via StoreDescriptor's decoder.
        if let legacy = PersistedState.load(StoreDescriptor.self, fromDefaults: defaults,
                                            key: legacyRepoDefaultsKey,
                                            document: storeRegistryDocumentName).value {
            persist([legacy])
            defaults.removeObject(forKey: legacyRepoDefaultsKey)
            return [legacy]
        }
        return []
    }

    private static func persist(_ descriptors: [StoreDescriptor]) {
        PersistedState.save(StoreRegistry(items: descriptors), toDefaults: .standard,
                            key: storesDefaultsKey, document: storeRegistryDocumentName)
    }

    func enterForeground() async {
        guard phase == .ready else { return }
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
        for context in storeContexts {
            await context.engine.stopLive()
            try? await context.store.wipe()
        }
        KeychainStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.storesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyRepoDefaultsKey)
        await client.setToken(nil)
        user = nil
        storeContexts = []
        storeFilter = nil
        searchIndex = SearchIndex()
        syncStatus = SyncEngine.Status()
        // Sign-out deleted the local copies, quarantined ones included, so
        // stop promising the user they're still recoverable on the device.
        StorageIssueLog.shared.removeAll()
        storageIssues = []
        lastSurfacedIssueId = nil
        phase = .signedOut
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
        for context in storeContexts {
            context.snapshot = await context.store.snapshot()
            context.status = await context.engine.currentStatus()
            context.coldSummaries = await context.engine.coldStore.projectSummaries()
        }
        // Key by store id (owner/name) — display names alone collide when two
        // owners have same-named repos. The UI translates via storeName(for:).
        searchIndex = SearchIndex(snapshots: storeContexts.map {
            (store: $0.id, snapshot: $0.snapshot)
        })
        syncStatus = aggregateStatus()
        collectStorageIssues()
        await refreshStoresManifest()
        // Store health (syncStatus) and the review/task data the widget
        // needs both settle right here — the same generation, every ~7s
        // live-poll cycle. WidgetBridge itself gates the widget-visible
        // reload on content actually changing.
        WidgetBridge.publish(from: self)
        // Likewise for the project names Siri can resolve by voice — gated
        // on the project set changing, not on every poll.
        PhrenAppShortcuts.donateProjects(from: self)
    }

    /// Drains the process-wide persistence log into the model.
    ///
    /// One source, not a union of the per-store arrays: the capture surfaces
    /// write from App Intents that can run with no model at all, so
    /// `StorageIssueLog` is the only place that sees everything — and it
    /// already holds what `LocalStore` and `SyncEngine` recorded too.
    private func collectStorageIssues() {
        let issues = StorageIssueLog.shared.issues
        guard let latest = issues.last, latest.id != lastSurfacedIssueId else { return }
        storageIssues = issues
        lastSurfacedIssueId = latest.id
        lastActionError = latest.userMessage
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
        await pullAll()
        await refreshStorePermissions()
        await refresh()
    }

    /// Re-fetches each store's repo to pick up push-permission changes (e.g.
    /// the user broadened a fine-grained token's access after adding a store
    /// read-only). Best-effort: a failed fetch just leaves canPush as-is.
    private func refreshStorePermissions() async {
        var changed = false
        for context in storeContexts {
            guard let repo = try? await client.repo(owner: context.descriptor.owner, name: context.descriptor.name) else {
                continue
            }
            let canPush = repo.permissions?.push ?? true
            if canPush != context.descriptor.canPush {
                context.updateCanPush(canPush)
                changed = true
            }
        }
        if changed {
            persistDescriptors(storeDescriptors)
        }
    }

    // MARK: - Mutations

    func perform(_ op: PendingOp, in storeId: String) async {
        do {
            try await enqueue(op, in: storeId)
            lastActionError = nil
        } catch let routing as StoreWriteError {
            // Nothing was applied, so there is nothing to re-read.
            lastActionError = routing.errorDescription
            return
        } catch {
            lastActionError = error.localizedDescription
        }
        await refresh()
    }

    /// Throwing core of `perform`, shared with the App Intents capture path —
    /// Siri needs the failure itself (to speak it), not a string parked in
    /// `lastActionError` for a view that isn't on screen.
    func enqueue(_ op: PendingOp, in storeId: String) async throws {
        guard let context = storeContexts.first(where: { $0.id == storeId }) else {
            throw StoreWriteError.storeNotOpen(storeId)
        }
        guard context.descriptor.canPush else {
            throw StoreWriteError.readOnly(context.descriptor.displayName)
        }
        try await context.engine.enqueue(op)
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

    /// Every op still waiting to be pushed, store-qualified. Backs the capture
    /// log's per-row "synced / waiting to sync" indicator — a capture is still
    /// on the device exactly as long as its op is in one of these queues.
    func pendingOps() async -> [(storeId: String, op: PendingOp)] {
        var result: [(storeId: String, op: PendingOp)] = []
        for context in storeContexts {
            for queued in await context.engine.pendingOps() {
                result.append((storeId: context.id, op: queued.op))
            }
        }
        return result
    }

    /// Current time formatted as the note heading time (HH:MM:SS UTC —
    /// matching `now.toISOString().slice(11,19)` in notes.ts:181). Static so
    /// the App Intents capture path, which may have no model at all, stamps
    /// notes exactly the way the capture sheet does.
    static func nowNoteTimestamp() -> (date: String, time: String) {
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
