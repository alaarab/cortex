import Foundation

/// Orchestrates GitHub ⇄ LocalStore sync.
///
/// Reads: cheap ref poll (ETag'd, 304s are rate-limit-free) → recursive tree →
/// changed blobs only. Writes: offline-first — every mutation applies to the
/// local cache immediately, queues a domain op, and flushes FIFO; a sha
/// conflict triggers refetch → re-apply → retry (bounded), then surfaces.
///
/// Live mode: while the app is foregrounded the engine polls continuously so
/// findings/tasks pushed by an agent on another machine appear within seconds.
public actor SyncEngine {
    public struct Status: Sendable, Equatable {
        public var isSyncing: Bool = false
        public var isLive: Bool = false
        public var lastSyncedAt: Date?
        public var pendingCount: Int = 0
        public var failedCount: Int = 0
        public var lastError: String?

        public init() {}
    }

    /// Identity stamped into `<!-- source: -->` comments on findings written
    /// from this device.
    public struct WriteContext: Sendable {
        public var actor: String?
        public var machine: String?

        public init(actor: String? = nil, machine: String? = nil) {
            self.actor = actor
            self.machine = machine
        }
    }

    public static let livePollInterval: TimeInterval = 7
    private static let maxWriteAttempts = 3
    /// Transport failures retry with backoff up to this many times before the
    /// op is parked. `attempts` used to be incremented and never read, so a
    /// permanently failing op retried forever at the poll cadence.
    private static let maxTransportAttempts = 8

    private let client: any GitHubAPI
    private let store: LocalStore
    private let queueURL: URL
    private var queue: PendingOpsQueue
    private var status = Status()
    private var writeContext = WriteContext()
    private var liveTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false
    private var autoFlush = true
    /// Offline engines (local stores with no repo behind them) apply ops to
    /// the cache and stop: no pulls, no polling, no flushes, no sync errors.
    private var isOffline = false
    private var pullTask: Task<Void, Never>?
    private var pullGeneration = 0

    /// Fires after any content change (remote pull or local apply) and on
    /// status transitions — the app re-reads the snapshot and re-renders.
    private var onUpdate: (@Sendable () -> Void)?

    public init(client: any GitHubAPI, store: LocalStore, stateDirectory: URL) {
        self.client = client
        self.store = store
        self.queueURL = stateDirectory.appendingPathComponent("pending-ops.json")
        self.queue = PendingOpsQueue.load(from: queueURL)
        self.status.pendingCount = queue.pending.count
        self.status.failedCount = queue.failed.count
    }

    public func setOnUpdate(_ callback: @escaping @Sendable () -> Void) {
        onUpdate = callback
    }

    public func setWriteContext(_ context: WriteContext) {
        writeContext = context
    }

    public func currentStatus() -> Status { status }

    private func notify() {
        onUpdate?()
    }

    private func setStatus(_ mutate: (inout Status) -> Void) {
        mutate(&status)
        status.pendingCount = queue.pending.count
        status.failedCount = queue.failed.count
        notify()
    }

    // MARK: - Pull

    /// One sync pass. `force` skips the ETag shortcut (used for pull-to-refresh
    /// and sha-conflict recovery). Concurrent callers serialize: a caller that
    /// finds a pull in flight awaits it, and a forced caller then runs its own
    /// pass — the conflict-recovery path must never no-op on a stale sha.
    public func pull(force: Bool = false) async {
        guard !isOffline else { return }
        if let inFlight = pullTask {
            await inFlight.value
            if !force { return }
        }
        pullGeneration += 1
        let generation = pullGeneration
        let task = Task { await self.performPull(force: force) }
        pullTask = task
        await task.value
        if pullGeneration == generation {
            pullTask = nil
        }
    }

    private func performPull(force: Bool) async {
        setStatus { $0.isSyncing = true; $0.lastError = nil }
        defer { setStatus { $0.isSyncing = false } }

        do {
            let manifest = await store.currentManifest
            let headSha: String?
            if force {
                // A forced pull must not be short-circuited by a stale ETag.
                headSha = try await client.headSha(owner: manifest.owner, repo: manifest.repo, branch: manifest.branch)
                    ?? manifest.headSha
            } else {
                headSha = try await client.headSha(owner: manifest.owner, repo: manifest.repo, branch: manifest.branch)
            }
            guard let headSha else {
                // 304 — nothing changed; the poll was free.
                setStatus { $0.lastSyncedAt = Date() }
                return
            }
            if !force, headSha == manifest.headSha {
                setStatus { $0.lastSyncedAt = Date() }
                return
            }

            let tree = try await client.tree(owner: manifest.owner, repo: manifest.repo, sha: headSha)
            let remote = Dictionary(
                tree.tree
                    .filter { $0.type == "blob" && LocalStore.isSyncedPath($0.path) }
                    .compactMap { entry in entry.sha.map { (entry.path, $0) } },
                uniquingKeysWith: { first, _ in first }
            )

            var changedPaths = Set<String>()
            for (path, sha) in remote {
                let cached = await store.blobSha(for: path)
                guard cached != sha else { continue }
                let data = try await client.blob(owner: manifest.owner, repo: manifest.repo, sha: sha)
                let content = String(data: data, encoding: .utf8) ?? ""
                try await store.write(path, content: content, blobSha: sha)
                changedPaths.insert(path)
            }
            for path in await store.allPaths() {
                guard remote[path] == nil, LocalStore.isSyncedPath(path) else { continue }
                // A nil blob sha means the file was created locally and never
                // synced (e.g. a new day's notes file from a queued op) —
                // deleting it here would drop the user's change before the
                // flush pushes it.
                guard await store.blobSha(for: path) != nil else { continue }
                guard await !store.isDeletedLocally(path) else { continue }
                try await store.deleteSynced(path)
                changedPaths.insert(path)
            }

            try await store.updateManifest { m in
                m.headSha = headSha
                m.lastSyncedAt = Date()
            }
            setStatus { $0.lastSyncedAt = Date() }
            // The remote moved under any pending op touching these paths, so
            // re-derive those ops against the content that just arrived. This
            // is the only place edits are recomputed.
            await rebasePendingOps(changedPaths: changedPaths)
            if !changedPaths.isEmpty { notify() }
        } catch {
            setStatus { $0.lastError = error.localizedDescription }
        }

        if !queue.pending.isEmpty {
            scheduleFlush()
        }
    }

    // MARK: - Live polling

    /// Start continuous foreground polling. Conditional ref checks answered
    /// 304 don't count against the rate limit, so a tight interval is fine.
    public func startLive() {
        guard !isOffline, liveTask == nil else { return }
        setStatus { $0.isLive = true }
        liveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pull()
                try? await Task.sleep(nanoseconds: UInt64(Self.livePollInterval * 1_000_000_000))
            }
        }
    }

    public func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        setStatus { $0.isLive = false }
    }

    // MARK: - Mutations

    /// Applies the op locally (instant UI), persists it, and schedules a flush.
    public func enqueue(_ op: PendingOp) async throws {
        let queued = QueuedOp(op: op)
        // Local apply first — a domain error (empty text, secret, ambiguous
        // match) surfaces to the user immediately and nothing is queued.
        try await applyLocally(queued)
        // Offline stores keep their state in the files themselves (dirty
        // paths); queueing ops would only grow a queue nothing ever drains.
        guard !isOffline else {
            setStatus { _ in }
            return
        }
        queue.pending.append(queued)
        queue.save(to: queueURL)
        setStatus { _ in }
        scheduleFlush()
    }

    /// Re-applies parked ops rather than just re-queueing them: under the
    /// upload-only push, an op whose paths are clean would push nothing and
    /// vanish silently.
    public func retryFailed() async {
        let parked = queue.failed
        queue.failed.removeAll()
        for var queued in parked {
            queued.attempts = 0
            queued.nextAttemptAt = nil
            queued.lastError = nil
            switch await replay(queued) {
            case .applied:
                queue.pending.append(queued)
            case .alreadySatisfied:
                continue
            case .unsatisfiable(let error):
                var failed = queued
                failed.lastError = error.localizedDescription
                queue.failed.append(failed)
            }
        }
        queue.save(to: queueURL)
        setStatus { _ in }
        notify()
        scheduleFlush()
    }

    /// Drops queued ops without pushing them, keeping their local effect.
    /// Used by demo mode, which has no credentials to flush with.
    public func discardPending() {
        queue.pending.removeAll()
        queue.save(to: queueURL)
        setStatus { $0.lastError = nil }
    }

    public func discardFailed(id: UUID) {
        queue.failed.removeAll { $0.id == id }
        queue.save(to: queueURL)
        setStatus { _ in }
    }

    public func failedOps() -> [QueuedOp] { queue.failed }

    /// Test seam: awaits any flush already scheduled on a detached task, then
    /// runs one to completion. Tests need a deterministic point at which the
    /// queue can be observed; production callers only ever schedule.
    func flushForTesting() async {
        if let task = flushTask { await task.value }
        await flush()
    }

    /// Test seam: the live pending queue, for asserting drain and ordering.
    func pendingOps() -> [QueuedOp] { queue.pending }

    /// Puts the engine in offline mode — used for on-device stores that have
    /// no GitHub repo yet. Everything still applies to the local cache and the
    /// dirty-path bookkeeping keeps working, so a later "connect to GitHub"
    /// can upload the accumulated state.
    public func setOffline(_ offline: Bool) {
        isOffline = offline
        if offline { queue.pending.removeAll(); queue.save(to: queueURL) }
        setStatus { $0.lastError = nil }
    }

    /// Test seam: stop `enqueue` from spawning a detached flush, so a test can
    /// set up state between queueing an op and pushing it.
    func setAutoFlush(_ enabled: Bool) { autoFlush = enabled }

    /// Test seam: drop retry deadlines so a backoff can be observed without
    /// waiting one out. Only the delay is skipped — the backoff itself is
    /// asserted directly in the durability tests.
    func clearBackoffForTesting() {
        for index in queue.pending.indices { queue.pending[index].nextAttemptAt = nil }
    }

    /// A flush requested while one is draining must not be dropped. Checking
    /// `flushTask == nil` alone left a window between the loop finishing and the
    /// task being cleared in which an enqueue scheduled nothing — and with the
    /// app backgrounded there is no next poll to recover it.
    private func scheduleFlush() {
        guard !isOffline else { return }
        flushRequested = true
        guard autoFlush else { return }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.runFlushLoop()
        }
    }

    private func runFlushLoop() async {
        defer { flushTask = nil }
        while flushRequested {
            flushRequested = false
            let madeProgress = await flush()
            // A blocked lane means everything left is waiting on the network or
            // a backoff deadline; spinning here would burn the battery.
            if !madeProgress { break }
        }
    }

    /// Pushes ready ops, newest lane-blocking failure aside. Returns whether
    /// anything drained, so the loop can stop instead of spinning on a lane
    /// that is waiting for the network.
    @discardableResult
    private func flush() async -> Bool {
        let now = Date()
        var blockedLanes = Set<String>()
        var drained = false

        while true {
            let next = queue.pending.first { candidate in
                guard let lane = candidate.op.affectedPaths.first else { return false }
                if blockedLanes.contains(lane) { return false }
                if let retryAt = candidate.nextAttemptAt, retryAt > now { return false }
                return true
            }
            guard let queued = next else { return drained }
            let lane = queued.op.affectedPaths.first ?? queued.op.project

            do {
                try await push(queued)
                queue.pending.removeAll { $0.id == queued.id }
                queue.save(to: queueURL)
                setStatus { _ in }
                drained = true
            } catch let error as PhrenKitError {
                // Domain failure the op can never recover from — park it.
                park(queued, reason: error.localizedDescription)
                drained = true
            } catch {
                // Transport failure. Back the op off and block only its own
                // lane: one repo-permission failure used to stall every other
                // project's queue behind it.
                var updated = queued
                updated.attempts += 1
                updated.lastError = error.localizedDescription

                if case GitHubError.rateLimited(let resetAt) = error {
                    updated.nextAttemptAt = resetAt ?? now.addingTimeInterval(60)
                } else if updated.attempts >= Self.maxTransportAttempts {
                    park(updated, reason: "Gave up after \(updated.attempts) attempts: \(error.localizedDescription)")
                    blockedLanes.insert(lane)
                    setStatus { $0.lastError = error.localizedDescription }
                    continue
                } else {
                    // Exponential, capped — 2s, 4s, 8s … 300s.
                    let delay = min(pow(2, Double(updated.attempts - 1)) * 2, 300)
                    updated.nextAttemptAt = now.addingTimeInterval(delay)
                }

                if let index = queue.pending.firstIndex(where: { $0.id == queued.id }) {
                    queue.pending[index] = updated
                }
                blockedLanes.insert(lane)
                queue.save(to: queueURL)
                setStatus { $0.lastError = error.localizedDescription }
            }
        }
    }

    private func park(_ queued: QueuedOp, reason: String) {
        var failed = queued
        failed.lastError = reason
        queue.pending.removeAll { $0.id == queued.id }
        queue.failed.append(failed)
        queue.save(to: queueURL)
        setStatus { _ in }
    }

    // MARK: - Op application

    private struct FileEdit {
        let path: String
        /// nil content means delete the file.
        let content: String?
    }

    /// Applies the op to local cached content only (optimistic UI).
    private func applyLocally(_ queued: QueuedOp) async throws {
        for edit in try await computeEdits(queued) {
            if let content = edit.content {
                try await store.write(edit.path, content: content, blobSha: nil)
            } else {
                try await store.delete(edit.path)
            }
        }
        notify()
    }

    /// Uploads the bytes this op already produced locally.
    ///
    /// Deliberately does *not* re-derive the edits. The op was applied exactly
    /// once, at enqueue; re-deriving here read content that already contained
    /// the change, which made adds duplicate and every other kind park. Ops are
    /// re-derived in exactly one place — `rebasePendingOps`, after a pull moves
    /// the base out from under them.
    private func push(_ queued: QueuedOp) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let manifest = await store.currentManifest
                for path in queued.op.affectedPaths {
                    // Clean means another op already pushed these bytes, or this
                    // op's tolerant second file was never touched.
                    guard await store.isDirty(path) else { continue }
                    guard LocalStore.isWritablePath(path) else {
                        throw PhrenKitError.validation("Refusing to write non-writable path \(path).")
                    }
                    let sha = await store.blobSha(for: path)

                    if let content = try await store.read(path) {
                        guard !(content.isEmpty && sha != nil) else {
                            throw PhrenKitError.validation("Refusing to overwrite \(path) with empty content.")
                        }
                        let response = try await client.putFile(
                            owner: manifest.owner, repo: manifest.repo, path: path,
                            branch: manifest.branch, content: Data(content.utf8),
                            message: queued.op.commitMessage, sha: sha
                        )
                        try await store.confirmPush(path, pushedContent: content,
                                                    blobSha: response.content?.sha)
                    } else if let sha, await store.isDeletedLocally(path) {
                        // Only a deliberate local delete may delete remotely. A
                        // file that merely went missing is a local fault, and
                        // destroying the remote copy over it is unrecoverable.
                        try await client.deleteFile(
                            owner: manifest.owner, repo: manifest.repo, path: path,
                            branch: manifest.branch, message: queued.op.commitMessage, sha: sha
                        )
                        try await store.confirmDelete(path)
                    }
                }
                return
            } catch let error as GitHubError {
                guard case .shaConflict = error, attempt < Self.maxWriteAttempts else { throw error }
                // Remote moved underneath us. A forced pull refetches and, via
                // rebasePendingOps, re-applies this op onto the new base — the
                // recompute that *is* wanted.
                await pull(force: true)
                // The rebase may have resolved or parked it in the meantime.
                guard queue.pending.contains(where: { $0.id == queued.id }) else { return }
            }
        }
    }

    // MARK: - Rebase

    private enum ApplyOutcome {
        case applied
        case alreadySatisfied
        case unsatisfiable(PhrenKitError)
    }

    /// Re-applies pending ops onto content a pull just replaced.
    ///
    /// Every affected path is first restored to last-synced remote content, so
    /// the replay starts from a clean base rather than from content that already
    /// carries some of these ops.
    private func rebasePendingOps(changedPaths: Set<String>) async {
        guard !queue.pending.isEmpty, !changedPaths.isEmpty else { return }
        let touched = queue.pending.filter { $0.op.affectedPaths.contains(where: changedPaths.contains) }
        guard !touched.isEmpty else { return }

        // A multi-file op must be replayed whole: restore the siblings we did
        // not refetch, or the untouched half receives the op a second time.
        let scope = Set(touched.flatMap { $0.op.affectedPaths })
        do {
            try await restoreBase(scope.subtracting(changedPaths))
        } catch {
            setStatus { $0.lastError = error.localizedDescription }
            return
        }

        var survivors: [QueuedOp] = []
        var parked = false
        for queued in queue.pending {
            guard queued.op.affectedPaths.contains(where: scope.contains) else {
                survivors.append(queued)
                continue
            }
            switch await replay(queued) {
            case .applied:
                survivors.append(queued)
            case .alreadySatisfied:
                continue
            case .unsatisfiable(let error):
                var failed = queued
                failed.lastError = error.localizedDescription
                queue.failed.append(failed)
                parked = true
            }
        }
        queue.pending = survivors
        queue.save(to: queueURL)
        setStatus { _ in }
        if parked { notify() }
    }

    /// Restores paths to their last-synced remote content by refetching the
    /// blob the manifest already points at. A path with no sha never existed
    /// remotely, so its base is "absent".
    private func restoreBase(_ paths: Set<String>) async throws {
        guard !paths.isEmpty else { return }
        let manifest = await store.currentManifest
        for path in paths.sorted() {
            if let sha = manifest.blobShas[path] {
                let data = try await client.blob(owner: manifest.owner, repo: manifest.repo, sha: sha)
                try await store.write(path, content: String(decoding: data, as: UTF8.self), blobSha: sha)
            } else {
                try await store.deleteSynced(path)
            }
        }
    }

    /// Re-applies an op, classifying domain failures instead of rethrowing.
    ///
    /// A failure is downgraded to `alreadySatisfied` only when the op's
    /// postcondition provably holds — that is the honest boundary: an error can
    /// be swallowed only when the outcome it was meant to produce is verifiably
    /// already there. Text-addressed ops stay fail-visible.
    private func replay(_ queued: QueuedOp) async -> ApplyOutcome {
        do {
            try await applyLocally(queued)
            return .applied
        } catch let error as PhrenKitError {
            if await postconditionHolds(queued) { return .alreadySatisfied }
            return .unsatisfiable(error)
        } catch {
            return .unsatisfiable(.validation(error.localizedDescription))
        }
    }

    /// Whether the op's intended outcome is already present in local content.
    /// Only id-addressed ops can answer this; everything else returns false and
    /// is surfaced to the user.
    private func postconditionHolds(_ queued: QueuedOp) async -> Bool {
        let project = queued.op.project
        let findingsPath = "\(project)/FINDINGS.md"
        let findings = await store.readIfAvailable(findingsPath) ?? ""

        switch queued.op {
        case .addFinding:
            return findings.contains("<!-- fid:\(queued.primaryId) -->")
        case .removeFinding(_, let match):
            guard Self.isGeneratedId(match) else { return false }
            return !findings.contains("<!-- fid:\(match) -->")
        case .addTask:
            let tasks = await store.readIfAvailable("\(project)/tasks.md") ?? ""
            return tasks.contains("bid:\(queued.primaryId)")
        case .removeTask(_, let match):
            guard Self.isGeneratedId(match) else { return false }
            let tasks = await store.readIfAvailable("\(project)/tasks.md") ?? ""
            return !tasks.contains("bid:\(match)")
        case .addNote(_, let date, _, _):
            let notes = await store.readIfAvailable("\(project)/notes/\(date).md") ?? ""
            return notes.contains("<!-- nid:\(queued.primaryId) -->")
        case .removeNote(_, let date, let stableId):
            let notes = await store.readIfAvailable("\(project)/notes/\(date).md") ?? ""
            return !notes.contains("<!-- nid:\(stableId) -->")
        case .promoteNote(_, let date, let stableId, _):
            let notes = await store.readIfAvailable("\(project)/notes/\(date).md") ?? ""
            guard let note = NotesFile(project: project, date: date, content: notes)
                .notes.first(where: { $0.stableId == stableId }) else { return false }
            return note.promoted && findings.contains("<!-- fid:\(queued.primaryId) -->")
        default:
            return false
        }
    }

    static func isGeneratedId(_ value: String) -> Bool {
        JSRegex(#"^[a-f0-9]{8}$"#).test(value)
    }

    /// Maps a domain op to concrete file edits against current local content.
    /// Each case mirrors the CLI handler documented on the file types.
    private func computeEdits(_ queued: QueuedOp) async throws -> [FileEdit] {
        let op = queued.op
        let project = op.project
        switch op {
        case .addFinding(_, let text, let type):
            var file = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
            var provenance = FindingProvenance(source: "human", tool: "phren-ios")
            provenance.machine = writeContext.machine
            provenance.actor = writeContext.actor
            try file.add(project: project, text: text, options: .init(
                type: type.flatMap(FindingType.init(rawValue:)),
                provenance: provenance,
                now: queued.clock,
                id: queued.primaryId
            ))
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .editFinding(_, let match, let newText):
            var file = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
            try file.edit(project: project, oldText: match, newText: newText)
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .removeFinding(_, let match):
            var file = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
            try file.remove(project: project, match: match)
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .approveQueue(_, let line):
            var file = ReviewFile(content: try await store.read("\(project)/review.md") ?? "")
            try file.approve(lineText: line)
            return [FileEdit(path: "\(project)/review.md", content: file.content)]

        case .rejectQueue(_, let line):
            // access.ts:709 — remove the queue line AND the finding; a
            // missing finding is tolerated.
            var review = ReviewFile(content: try await store.read("\(project)/review.md") ?? "")
            try review.reject(lineText: line)
            var edits = [FileEdit(path: "\(project)/review.md", content: review.content)]
            let needle = ReviewFile.findingsTextFor(lineText: line)
            if !needle.isEmpty {
                var findings = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
                if (try? findings.remove(project: project, match: needle)) != nil {
                    edits.append(FileEdit(path: "\(project)/FINDINGS.md", content: findings.content))
                }
            }
            return edits

        case .editQueue(_, let line, let newText):
            // access.ts:728 — rewrite the queue line, tolerantly edit the finding.
            var review = ReviewFile(content: try await store.read("\(project)/review.md") ?? "")
            let oldNeedle = ReviewFile.findingsTextFor(lineText: line)
            let trimmed = try review.edit(lineText: line, newText: newText)
            var edits = [FileEdit(path: "\(project)/review.md", content: review.content)]
            if !oldNeedle.isEmpty {
                var findings = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
                if (try? findings.edit(project: project, oldText: oldNeedle, newText: trimmed)) != nil {
                    edits.append(FileEdit(path: "\(project)/FINDINGS.md", content: findings.content))
                }
            }
            return edits

        case .addNote(_, let date, let time, let text):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: try await store.read(path))
            try file.add(text: text, time: time, id: queued.primaryId)
            return [FileEdit(path: path, content: file.render())]

        case .editNote(_, let date, let stableId, let text):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: try await store.read(path))
            try file.edit(stableId: stableId, text: text)
            return [FileEdit(path: path, content: file.render())]

        case .removeNote(_, let date, let stableId):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: try await store.read(path))
            try file.remove(stableId: stableId)
            // render() returns nil when the last note was removed → delete file.
            return [FileEdit(path: path, content: file.render())]

        case .promoteNote(_, let date, let stableId, let findingType):
            // core/note.ts:13 — refuse if promoted; add finding; mark note.
            let notePath = "\(project)/notes/\(date).md"
            var notesFile = NotesFile(project: project, date: date, content: try await store.read(notePath))
            guard let note = notesFile.notes.first(where: { $0.stableId == stableId }) else {
                throw PhrenKitError.notFound("No note matching \"nid:\(stableId)\" was found.")
            }
            guard !note.promoted else {
                throw PhrenKitError.validation("Note nid:\(stableId) has already been promoted.")
            }
            var findings = FindingsFile(content: try await store.read("\(project)/FINDINGS.md") ?? "")
            var provenance = FindingProvenance(source: "human", tool: "phren-ios")
            provenance.machine = writeContext.machine
            provenance.actor = writeContext.actor
            try findings.add(project: project, text: note.text, options: .init(
                type: findingType.flatMap(FindingType.init(rawValue:)),
                provenance: provenance,
                now: queued.clock,
                id: queued.primaryId
            ))
            try notesFile.markPromoted(stableId: stableId)
            return [
                FileEdit(path: "\(project)/FINDINGS.md", content: findings.content),
                FileEdit(path: notePath, content: notesFile.render()),
            ]

        case .addTask(_, let text):
            var file = TasksFile(project: project, content: try await store.read("\(project)/tasks.md"))
            try file.add(text, id: queued.primaryId)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .completeTask(_, let match):
            var file = TasksFile(project: project, content: try await store.read("\(project)/tasks.md"))
            try file.complete(match)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .removeTask(_, let match):
            var file = TasksFile(project: project, content: try await store.read("\(project)/tasks.md"))
            try file.remove(match)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .updateTask(_, let match, let text, let priority, let section):
            var file = TasksFile(project: project, content: try await store.read("\(project)/tasks.md"))
            try file.update(match, updates: .init(
                text: text,
                priority: priority.flatMap(PhrenTask.Priority.init(rawValue:)),
                section: section.flatMap(PhrenTask.Section.init(rawValue:))
            ))
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]
        }
    }
}
