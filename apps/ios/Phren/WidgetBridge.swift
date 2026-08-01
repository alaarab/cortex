import Foundation
import WidgetKit
import PhrenKit

/// The JSON contract between the app and the `PhrenWidgets` extension.
///
/// Mirrors `WidgetSnapshot` in `PhrenWidgets/WidgetSnapshot.swift`
/// field-for-field — the widget target can't link PhrenKit or this app
/// target, so a hand-kept duplicate struct plus the JSON file written to the
/// shared App Group container is the entire contract. If you add a field
/// here, add it there too.
struct WidgetSnapshot: Codable, Equatable {
    struct StoreCount: Codable, Equatable {
        var storeName: String
        var count: Int
    }

    struct TopTask: Codable, Equatable {
        var text: String
        var project: String
    }

    var totalReviewCount: Int
    var storeBreakdown: [StoreCount]
    var topTask: TopTask?
    var lastSyncedAt: Date?

    /// The subset that matters for deciding whether the widget's on-screen
    /// content actually needs to change. `lastSyncedAt` ticks forward on
    /// almost every live poll — `SyncEngine.setStatus` calls `notify()` (and
    /// hence `AppModel.refresh()`) on every status mutation, not just
    /// content changes, so it moves roughly every ~7s while the app is
    /// foregrounded. Comparing full snapshot bytes including it would make
    /// change-detection a no-op and spam `WidgetCenter.reloadAllTimelines()`
    /// well past its daily budget.
    struct Content: Codable, Equatable {
        var totalReviewCount: Int
        var storeBreakdown: [StoreCount]
        var topTask: TopTask?
    }

    var content: Content {
        Content(totalReviewCount: totalReviewCount, storeBreakdown: storeBreakdown, topTask: topTask)
    }
}

/// Writes `WidgetSnapshot` to the `group.com.phren.ios` shared container so
/// the WidgetKit extension — which reads only this JSON file, never GitHub
/// or PhrenKit directly — can render review count / top task without the
/// app being open.
///
/// Called from `AppModel.refresh()`, the same place the store-health data
/// (`syncStatus`, per-store `status`) settles each cycle: live-mode polling
/// re-runs `refresh()` roughly every ~7s per store while foregrounded, so
/// the snapshot file is always written with this cycle's freshest counts.
/// The disk write is unconditional (cheap, local); the widget-visible
/// `reloadAllTimelines()` call is gated on `Content` actually changing so a
/// quiet poll (nothing approved, nothing new) never touches the widget
/// refresh budget.
@MainActor
enum WidgetBridge {
    static let appGroupID = "group.com.phren.ios"
    private static let snapshotFilename = "widget-snapshot.json"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Encoded `Content` bytes from the last publish that changed the
    /// widget-visible picture — `nil` at launch, so the first refresh of
    /// every cold start always reloads once (cheap, and it's exactly the
    /// case the "app-side reload keeps it fresher" story is for).
    private static var lastPublishedContent: Data?

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func publish(from model: AppModel) {
        guard let url = containerURL?.appendingPathComponent(snapshotFilename) else { return }
        let snapshot = buildSnapshot(from: model)

        guard let fullData = try? encoder.encode(snapshot) else { return }
        try? fullData.write(to: url, options: .atomic)

        guard let contentData = try? encoder.encode(snapshot.content), contentData != lastPublishedContent else {
            return
        }
        lastPublishedContent = contentData
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func buildSnapshot(from model: AppModel) -> WidgetSnapshot {
        let breakdown = model.storeContexts
            .map { WidgetSnapshot.StoreCount(storeName: $0.descriptor.displayName, count: $0.snapshot.reviewQueue.count) }
            .sorted { $0.storeName < $1.storeName }
        return WidgetSnapshot(
            totalReviewCount: model.totalReviewCount,
            storeBreakdown: breakdown,
            topTask: topActiveTask(model: model),
            lastSyncedAt: model.syncStatus.lastSyncedAt
        )
    }

    /// Mirrors `TaskListView`'s active-section ordering (pinned first, then
    /// rank — tasks.ts display order) across every store/project, so "top
    /// task" here means the same thing it does in the Tasks tab.
    private static func topActiveTask(model: AppModel) -> WidgetSnapshot.TopTask? {
        var best: (task: PhrenTask, project: String)?
        for (_, _, doc) in model.mergedTaskDocs {
            for task in doc.active {
                guard let current = best else {
                    best = (task, doc.project)
                    continue
                }
                if isHigherPriority(task, doc.project, than: current.task, current.project) {
                    best = (task, doc.project)
                }
            }
        }
        guard let best else { return nil }
        return WidgetSnapshot.TopTask(text: best.task.line, project: best.project)
    }

    private static func isHigherPriority(_ a: PhrenTask, _ aProject: String, than b: PhrenTask, _ bProject: String) -> Bool {
        let aPinned = a.pinned ?? false
        let bPinned = b.pinned ?? false
        if aPinned != bPinned { return aPinned }
        let aRank = a.rank ?? Int.max
        let bRank = b.rank ?? Int.max
        if aRank != bRank { return aRank < bRank }
        return aProject < bProject
    }
}
