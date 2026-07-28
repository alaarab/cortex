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

    private let client: any GitHubAPI
    private let store: LocalStore
    private let queueURL: URL
    private var queue: PendingOpsQueue
    private var status = Status()
    private var writeContext = WriteContext()
    private var liveTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
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

            var changed = false
            for (path, sha) in remote {
                let cached = await store.blobSha(for: path)
                guard cached != sha else { continue }
                let data = try await client.blob(owner: manifest.owner, repo: manifest.repo, sha: sha)
                let content = String(data: data, encoding: .utf8) ?? ""
                try await store.write(path, content: content, blobSha: sha)
                changed = true
            }
            for path in await store.allPaths() {
                guard remote[path] == nil, LocalStore.isSyncedPath(path) else { continue }
                // A nil blob sha means the file was created locally and never
                // synced (e.g. a new day's notes file from a queued op) —
                // deleting it here would drop the user's change before the
                // flush pushes it.
                guard await store.blobSha(for: path) != nil else { continue }
                try await store.delete(path)
                changed = true
            }

            try await store.updateManifest { m in
                m.headSha = headSha
                m.lastSyncedAt = Date()
            }
            setStatus { $0.lastSyncedAt = Date() }
            if changed { notify() }
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
        guard liveTask == nil else { return }
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
        // Local apply first — a domain error (empty text, secret, ambiguous
        // match) surfaces to the user immediately and nothing is queued.
        try await applyLocally(op)
        queue.pending.append(QueuedOp(op: op))
        queue.save(to: queueURL)
        setStatus { _ in }
        scheduleFlush()
    }

    public func retryFailed() {
        queue.pending.append(contentsOf: queue.failed)
        queue.failed.removeAll()
        queue.save(to: queueURL)
        setStatus { _ in }
        scheduleFlush()
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

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flush()
            await self?.clearFlushTask()
        }
    }

    private func clearFlushTask() {
        flushTask = nil
    }

    /// FIFO flush: push each op's file edits with sha optimistic concurrency.
    private func flush() async {
        while var queued = queue.pending.first {
            do {
                try await push(queued.op)
                queue.pending.removeFirst()
                queue.save(to: queueURL)
                setStatus { _ in }
            } catch let error as PhrenKitError {
                // Domain failure after a remote change — the op can never
                // succeed; park it for the user.
                queued.lastError = error.localizedDescription
                queue.pending.removeFirst()
                queue.failed.append(queued)
                queue.save(to: queueURL)
                setStatus { _ in }
            } catch {
                // Network/API failure — keep the op queued and stop; the next
                // sync trigger retries.
                queued.attempts += 1
                queued.lastError = error.localizedDescription
                queue.pending[0] = queued
                queue.save(to: queueURL)
                setStatus { $0.lastError = error.localizedDescription }
                return
            }
        }
    }

    // MARK: - Op application

    private struct FileEdit {
        let path: String
        /// nil content means delete the file.
        let content: String?
    }

    /// Applies the op to local cached content only (optimistic UI).
    private func applyLocally(_ op: PendingOp) async throws {
        for edit in try await computeEdits(op) {
            if let content = edit.content {
                try await store.write(edit.path, content: content, blobSha: nil)
            } else {
                try await store.delete(edit.path)
            }
        }
        notify()
    }

    /// Pushes the op: recompute the edits against current local content and
    /// PUT each file; on sha conflict, pull fresh content and re-apply the
    /// domain op (ops are fid/text-addressed so reapplication is natural).
    private func push(_ op: PendingOp) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let manifest = await store.currentManifest
                for edit in try await computeEdits(op) {
                    guard LocalStore.isWritablePath(edit.path) else {
                        throw PhrenKitError.validation("Refusing to write non-writable path \(edit.path).")
                    }
                    let sha = await store.blobSha(for: edit.path)
                    if let content = edit.content {
                        let response = try await client.putFile(
                            owner: manifest.owner, repo: manifest.repo, path: edit.path,
                            branch: manifest.branch, content: Data(content.utf8),
                            message: op.commitMessage, sha: sha
                        )
                        try await store.write(edit.path, content: content, blobSha: response.content?.sha)
                    } else if let sha {
                        try await client.deleteFile(
                            owner: manifest.owner, repo: manifest.repo, path: edit.path,
                            branch: manifest.branch, message: op.commitMessage, sha: sha
                        )
                        try await store.delete(edit.path)
                    }
                }
                return
            } catch let error as GitHubError {
                guard case .shaConflict = error, attempt < Self.maxWriteAttempts else { throw error }
                // Remote changed underneath us: refresh and re-apply.
                await pull(force: true)
            }
        }
    }

    /// Maps a domain op to concrete file edits against current local content.
    /// Each case mirrors the CLI handler documented on the file types.
    private func computeEdits(_ op: PendingOp) async throws -> [FileEdit] {
        let project = op.project
        switch op {
        case .addFinding(_, let text, let type):
            var file = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
            var provenance = FindingProvenance(source: "human", tool: "phren-ios")
            provenance.machine = writeContext.machine
            provenance.actor = writeContext.actor
            try file.add(project: project, text: text, options: .init(
                type: type.flatMap(FindingType.init(rawValue:)),
                provenance: provenance
            ))
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .editFinding(_, let match, let newText):
            var file = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
            try file.edit(project: project, oldText: match, newText: newText)
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .removeFinding(_, let match):
            var file = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
            try file.remove(project: project, match: match)
            return [FileEdit(path: "\(project)/FINDINGS.md", content: file.content)]

        case .approveQueue(_, let line):
            var file = ReviewFile(content: await store.read("\(project)/review.md") ?? "")
            try file.approve(lineText: line)
            return [FileEdit(path: "\(project)/review.md", content: file.content)]

        case .rejectQueue(_, let line):
            // access.ts:709 — remove the queue line AND the finding; a
            // missing finding is tolerated.
            var review = ReviewFile(content: await store.read("\(project)/review.md") ?? "")
            try review.reject(lineText: line)
            var edits = [FileEdit(path: "\(project)/review.md", content: review.content)]
            let needle = ReviewFile.findingsTextFor(lineText: line)
            if !needle.isEmpty {
                var findings = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
                if (try? findings.remove(project: project, match: needle)) != nil {
                    edits.append(FileEdit(path: "\(project)/FINDINGS.md", content: findings.content))
                }
            }
            return edits

        case .editQueue(_, let line, let newText):
            // access.ts:728 — rewrite the queue line, tolerantly edit the finding.
            var review = ReviewFile(content: await store.read("\(project)/review.md") ?? "")
            let oldNeedle = ReviewFile.findingsTextFor(lineText: line)
            let trimmed = try review.edit(lineText: line, newText: newText)
            var edits = [FileEdit(path: "\(project)/review.md", content: review.content)]
            if !oldNeedle.isEmpty {
                var findings = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
                if (try? findings.edit(project: project, oldText: oldNeedle, newText: trimmed)) != nil {
                    edits.append(FileEdit(path: "\(project)/FINDINGS.md", content: findings.content))
                }
            }
            return edits

        case .addNote(_, let date, let time, let text):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: await store.read(path))
            try file.add(text: text, time: time)
            return [FileEdit(path: path, content: file.render())]

        case .editNote(_, let date, let stableId, let text):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: await store.read(path))
            try file.edit(stableId: stableId, text: text)
            return [FileEdit(path: path, content: file.render())]

        case .removeNote(_, let date, let stableId):
            let path = "\(project)/notes/\(date).md"
            var file = NotesFile(project: project, date: date, content: await store.read(path))
            try file.remove(stableId: stableId)
            // render() returns nil when the last note was removed → delete file.
            return [FileEdit(path: path, content: file.render())]

        case .promoteNote(_, let date, let stableId, let findingType):
            // core/note.ts:13 — refuse if promoted; add finding; mark note.
            let notePath = "\(project)/notes/\(date).md"
            var notesFile = NotesFile(project: project, date: date, content: await store.read(notePath))
            guard let note = notesFile.notes.first(where: { $0.stableId == stableId }) else {
                throw PhrenKitError.notFound("No note matching \"nid:\(stableId)\" was found.")
            }
            guard !note.promoted else {
                throw PhrenKitError.validation("Note nid:\(stableId) has already been promoted.")
            }
            var findings = FindingsFile(content: await store.read("\(project)/FINDINGS.md") ?? "")
            var provenance = FindingProvenance(source: "human", tool: "phren-ios")
            provenance.machine = writeContext.machine
            provenance.actor = writeContext.actor
            try findings.add(project: project, text: note.text, options: .init(
                type: findingType.flatMap(FindingType.init(rawValue:)),
                provenance: provenance
            ))
            try notesFile.markPromoted(stableId: stableId)
            return [
                FileEdit(path: "\(project)/FINDINGS.md", content: findings.content),
                FileEdit(path: notePath, content: notesFile.render()),
            ]

        case .addTask(_, let text):
            var file = TasksFile(project: project, content: await store.read("\(project)/tasks.md"))
            try file.add(text)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .completeTask(_, let match):
            var file = TasksFile(project: project, content: await store.read("\(project)/tasks.md"))
            try file.complete(match)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .removeTask(_, let match):
            var file = TasksFile(project: project, content: await store.read("\(project)/tasks.md"))
            try file.remove(match)
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]

        case .updateTask(_, let match, let text, let priority, let section):
            var file = TasksFile(project: project, content: await store.read("\(project)/tasks.md"))
            try file.update(match, updates: .init(
                text: text,
                priority: priority.flatMap(PhrenTask.Priority.init(rawValue:)),
                section: section.flatMap(PhrenTask.Section.init(rawValue:))
            ))
            return [FileEdit(path: "\(project)/tasks.md", content: file.render())]
        }
    }
}
