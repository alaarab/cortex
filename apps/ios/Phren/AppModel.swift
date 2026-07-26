import SwiftUI
import PhrenKit

/// Root observable state: auth, store selection, the parsed snapshot, and the
/// sync engine. Views read `snapshot` and call the mutation helpers; every
/// content change (local or remote) refreshes the snapshot in place.
@Observable @MainActor
final class AppModel {
    enum Phase {
        case loading
        case signedOut
        case pickingRepo
        case initialSync
        case ready
    }

    struct SelectedRepo: Codable, Equatable {
        var owner: String
        var name: String
        var branch: String
    }

    private(set) var phase: Phase = .loading
    private(set) var user: GitHubUser?
    private(set) var selectedRepo: SelectedRepo?
    private(set) var snapshot: LocalStore.Snapshot = .empty
    private(set) var searchIndex = SearchIndex()
    private(set) var syncStatus = SyncEngine.Status()
    var lastActionError: String?

    let client = GitHubClient()
    private var store: LocalStore?
    private var engine: SyncEngine?

    private static let repoDefaultsKey = "phren.selected-repo"

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
            // Token revoked/expired — back to sign-in.
            KeychainStore.delete()
            phase = .signedOut
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.repoDefaultsKey),
           let repo = try? JSONDecoder().decode(SelectedRepo.self, from: data) {
            await openStore(repo, freshClone: false)
        } else {
            phase = .pickingRepo
        }
    }

    func enterForeground() async {
        guard phase == .ready, let engine else { return }
        await engine.startLive()
    }

    func enterBackground() async {
        guard let engine else { return }
        await engine.stopLive()
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
        await engine?.stopLive()
        try? await store?.wipe()
        KeychainStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.repoDefaultsKey)
        await client.setToken(nil)
        user = nil
        selectedRepo = nil
        store = nil
        engine = nil
        snapshot = .empty
        searchIndex = SearchIndex()
        phase = .signedOut
    }

    // MARK: - Store selection

    func selectRepo(owner: String, name: String, branch: String) async {
        let repo = SelectedRepo(owner: owner, name: name, branch: branch)
        if let data = try? JSONEncoder().encode(repo) {
            UserDefaults.standard.set(data, forKey: Self.repoDefaultsKey)
        }
        await openStore(repo, freshClone: true)
    }

    private func openStore(_ repo: SelectedRepo, freshClone: Bool) async {
        do {
            let directory = LocalStore.defaultDirectory(owner: repo.owner, repo: repo.name)
            let store = try LocalStore(rootDirectory: directory, owner: repo.owner,
                                       repo: repo.name, branch: repo.branch)
            let engine = SyncEngine(client: client, store: store, stateDirectory: directory)
            self.store = store
            self.engine = engine
            self.selectedRepo = repo

            await engine.setWriteContext(.init(
                actor: user?.login,
                machine: deviceName()
            ))
            await engine.setOnUpdate { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }

            phase = freshClone ? .initialSync : .ready
            await engine.pull(force: true)
            await refresh()
            phase = .ready
            await engine.startLive()
        } catch {
            lastActionError = error.localizedDescription
            phase = .pickingRepo
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
        guard let store, let engine else { return }
        snapshot = await store.snapshot()
        searchIndex = SearchIndex(snapshot: snapshot)
        syncStatus = await engine.currentStatus()
    }

    func pullToRefresh() async {
        await engine?.pull(force: true)
        await refresh()
    }

    // MARK: - Mutations (thin wrappers over the pending-ops queue)

    func perform(_ op: PendingOp) async {
        guard let engine else { return }
        do {
            try await engine.enqueue(op)
            lastActionError = nil
        } catch {
            lastActionError = error.localizedDescription
        }
        await refresh()
    }

    func retryFailedOps() async {
        await engine?.retryFailed()
        await refresh()
    }

    func discardFailedOp(id: UUID) async {
        await engine?.discardFailed(id: id)
        await refresh()
    }

    func failedOps() async -> [QueuedOp] {
        await engine?.failedOps() ?? []
    }

    /// Current local time formatted as the note heading time (HH:MM:SS UTC —
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
