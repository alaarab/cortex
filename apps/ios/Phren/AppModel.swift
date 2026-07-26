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

    var id: String { descriptor.id }

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
    private(set) var syncStatus = SyncEngine.Status()
    /// Global store filter (store id) applied by list screens when set.
    var storeFilter: String?
    var lastActionError: String?

    let client = GitHubClient()

    private static let storesDefaultsKey = "phren.stores"
    private static let legacyRepoDefaultsKey = "phren.selected-repo"

    var storeDescriptors: [StoreDescriptor] { storeContexts.map(\.descriptor) }
    var hasMultipleStores: Bool { storeContexts.count > 1 }

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

    func summary(storeId: String, project: String) -> String? {
        snapshot(for: storeId).summaries[project]
    }

    var totalReviewCount: Int {
        storeContexts.reduce(0) { $0 + $1.snapshot.reviewQueue.count }
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
        if firstStore { phase = .ready }
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
        }
        searchIndex = SearchIndex(snapshots: storeContexts.map {
            (store: $0.descriptor.displayName, snapshot: $0.snapshot)
        })
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

    func failedOps() async -> [(storeId: String, storeName: String, op: QueuedOp)] {
        var result: [(String, String, QueuedOp)] = []
        for context in storeContexts {
            for op in await context.engine.failedOps() {
                result.append((context.id, context.descriptor.displayName, op))
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
